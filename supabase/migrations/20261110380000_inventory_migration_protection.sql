-- Milestone 9: QBO inventory product crosswalk, safe catalog import only.
-- Source quantities and costs are NEVER automatically posted to stock without
-- inventory valuation, cutoff and reconciliation evidence.
create table public.migration_inventory_items(
 organization_id uuid not null,
 batch_id uuid not null,
 source_item_id text not null,
 product_id uuid not null,
 source_quantity numeric(20,3),
 source_unit_cost numeric(20,2),
 created_at timestamptz not null default now(),
 primary key(organization_id,batch_id,source_item_id),
 unique(organization_id,batch_id,product_id),
 foreign key(organization_id,batch_id) references public.migration_batches(organization_id,id),
 foreign key(organization_id,product_id) references public.inventory_products(organization_id,id)
);
alter table public.migration_inventory_items enable row level security;
create policy migration_inventory_items_read on public.migration_inventory_items
 for select to authenticated using(public.has_org_access(organization_id));
revoke all on public.migration_inventory_items from public,anon,authenticated;
grant select on public.migration_inventory_items to authenticated;

create function public.import_qbo_inventory_catalog(p_org uuid,p_batch uuid,p_limit integer default 100)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_row public.migration_records%rowtype;v_name text;v_sku text;v_product uuid;v_count integer:=0;
begin
 if not exists(select 1 from public.organization_members where organization_id=p_org
  and user_id=auth.uid() and role in ('owner','accountant')) then
  raise exception 'Accountant approval required';end if;
 if p_limit is null or p_limit not between 1 and 100 then raise exception 'Invalid batch limit';end if;
 perform 1 from public.organizations where id=p_org for update;
 if not exists(select 1 from public.migration_batches where organization_id=p_org
  and id=p_batch and approved_at is not null and state in ('in_progress','completed'))
 then raise exception 'Migration batch must be approved and base entities imported';end if;
 for v_row in select * from public.migration_records
  where organization_id=p_org and batch_id=p_batch and record_kind='inventory_item'
  and status='staged' order by created_at,id limit p_limit loop
  if v_row.payload->>'item_type'<>'Inventory' then
   -- Unsupported non-stock or service items remain in preserved source staging.
   continue;
  end if;
  v_name:=trim(coalesce(v_row.payload->>'name',''));
  v_sku:=upper(trim(coalesce(v_row.payload->>'sku','')));
  if v_sku !~ '^[A-Z0-9][A-Z0-9._-]{0,79}$' or
   length(v_name) not between 2 and 180 then
   raise exception 'Inventory item % has invalid SKU or name',v_row.source_id;end if;
  select id into v_product from public.inventory_products where
   organization_id=p_org and sku=v_sku;
  if v_product is null then
   v_product:=public.create_inventory_product(p_org,v_sku,v_name);
  end if;
  insert into public.migration_inventory_items(organization_id,batch_id,source_item_id,
   product_id,source_quantity,source_unit_cost)
  values(p_org,p_batch,v_row.source_id,v_product,
   nullif(v_row.payload->>'quantity_on_hand','')::numeric,
   nullif(v_row.payload->>'unit_cost','')::numeric);
  update public.migration_records set status='imported',target_id=v_product
   where organization_id=p_org and id=v_row.id;
  v_count:=v_count+1;
 end loop;
 perform private.write_audit(p_org,'migration.inventory_catalog_imported','migration',p_batch,
  jsonb_build_object('items',v_count,'quantity_posted',false));
 return jsonb_build_object('products_imported',v_count,
  'stock_quantity_posted',false,'valuation_review_required',true);
end $$;
revoke all on function public.import_qbo_inventory_catalog(uuid,uuid,integer) from public,anon;
grant execute on function public.import_qbo_inventory_catalog(uuid,uuid,integer) to authenticated;

-- Reject manual reversal of inventory-linked journals, which otherwise would
-- corrupt inventory quantities while changing the ledger.
create or replace function public.reverse_manual_journal(
 p_organization_id uuid,p_journal_id uuid,p_reversal_date date,p_reason text
) returns uuid language plpgsql security definer set search_path=''
as $$
begin
 if not public.has_org_write(p_organization_id) then raise exception 'Not authorized';end if;
 perform 1 from public.organizations where id=p_organization_id for update;
 if exists(select 1 from public.year_end_closures where organization_id=p_organization_id and closing_journal_id=p_journal_id)
 or exists(select 1 from public.payment_refunds where organization_id=p_organization_id and journal_entry_id=p_journal_id)
 or exists(select 1 from public.document_writeoffs where organization_id=p_organization_id and journal_entry_id=p_journal_id)
 or exists(select 1 from public.customer_deposits where organization_id=p_organization_id and journal_entry_id=p_journal_id)
 or exists(select 1 from public.deposit_applications where organization_id=p_organization_id and journal_entry_id=p_journal_id)
 or exists(select 1 from public.deposit_refunds where organization_id=p_organization_id and journal_entry_id=p_journal_id)
 or exists(select 1 from public.vendor_advances where organization_id=p_organization_id and journal_entry_id=p_journal_id)
 or exists(select 1 from public.vendor_advance_applications where organization_id=p_organization_id and journal_entry_id=p_journal_id)
 or exists(select 1 from public.vendor_advance_refunds where organization_id=p_organization_id and journal_entry_id=p_journal_id)
 or exists(select 1 from public.inventory_receipts where organization_id=p_organization_id and journal_entry_id=p_journal_id)
 or exists(select 1 from public.inventory_issues where organization_id=p_organization_id and journal_entry_id=p_journal_id)
 or exists(select 1 from public.foreign_document_payments fx
   join public.document_payments p on p.organization_id=fx.organization_id and p.id=fx.payment_id
   where fx.organization_id=p_organization_id and p.journal_entry_id=p_journal_id)
 or exists(select 1 from public.inventory_receipts where organization_id=p_organization_id and journal_entry_id=p_journal_id)
 or exists(select 1 from public.inventory_issues where organization_id=p_organization_id and journal_entry_id=p_journal_id)
 then raise exception 'Source accounting journal cannot be manually reversed';end if;
 return public.reverse_manual_journal_legacy(p_organization_id,p_journal_id,p_reversal_date,p_reason);
end $$;
