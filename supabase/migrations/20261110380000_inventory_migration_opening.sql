-- Milestone 9: Inventory source migration without duplicating opening GL value.
-- Opening lots reuse the existing one-time opening-balance journal instead of
-- posting the asset value again. Requires exactly matching inventory asset value.
create table public.inventory_opening_batches(
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null references public.organizations(id) on delete restrict,
 opening_journal_id uuid not null,
 effective_date date not null,
 total_quantity numeric(20,3) not null check(total_quantity>0),
 total_cost numeric(20,2) not null check(total_cost>0),
 payload_digest char(32) not null,
 idempotency_key uuid not null,
 created_by uuid not null references auth.users(id),
 created_at timestamptz not null default now(),
 unique(organization_id,id),unique(organization_id,idempotency_key),
 unique(organization_id),
 foreign key(organization_id,opening_journal_id) references public.journal_entries(organization_id,id)
);
alter table public.inventory_receipts alter column bill_line_id drop not null;
alter table public.inventory_receipts add column opening_batch_id uuid,
 add constraint inventory_receipt_source_exclusive
 check((bill_line_id is not null and opening_batch_id is null)
   or (bill_line_id is null and opening_batch_id is not null)),
 add constraint inventory_receipt_opening_batch_fk foreign key(organization_id,opening_batch_id)
 references public.inventory_opening_batches(organization_id,id);
alter table public.inventory_opening_batches enable row level security;
create policy inventory_opening_batches_read on public.inventory_opening_batches for select to authenticated
 using(public.has_org_access(organization_id));
revoke all on public.inventory_opening_batches from public,anon,authenticated;
grant select on public.inventory_opening_batches to authenticated;

create function public.register_inventory_opening_lots(
 p_org uuid,p_date date,p_lots jsonb,p_key uuid
) returns uuid language plpgsql security definer set search_path=''
as $$
declare v_role text;v_opening public.opening_balance_imports%rowtype;
 v_batch public.inventory_opening_batches%rowtype;v_id uuid;
 v_asset uuid;v_gl_value numeric;v_total_cost numeric(20,2):=0;
 v_total_quantity numeric(20,3):=0;v_item jsonb;
 v_product uuid;v_qty numeric(12,3);v_cost numeric(20,2);
 v_index int:=0;v_digest text;
begin
 select role into v_role from public.organization_members
 where organization_id=p_org and user_id=auth.uid();
 if v_role is null or v_role not in ('owner','administrator','accountant')
 then raise exception 'Opening inventory registration requires accountant/admin';end if;
 if p_key is null or p_date is null or jsonb_typeof(p_lots) is distinct from 'array'
 or jsonb_array_length(p_lots) not between 1 and 500
 then raise exception 'Opening inventory requires date and 1 to 500 lots';end if;
 v_digest:=md5(p_date::text||'|'||p_lots::text);
 perform 1 from public.organizations where id=p_org for update;
 select * into v_batch from public.inventory_opening_batches
 where organization_id=p_org and idempotency_key=p_key;
 if found then
  if v_batch.payload_digest<>v_digest then raise exception 'Opening stock key reused with different lots';end if;
  return v_batch.id;
 end if;
 if exists(select 1 from public.inventory_opening_batches where organization_id=p_org)
 or exists(select 1 from public.inventory_receipts where organization_id=p_org)
 or exists(select 1 from public.inventory_issues where organization_id=p_org)
 then raise exception 'Opening inventory can be registered only before inventory movements';end if;
 select * into v_opening from public.opening_balance_imports
 where organization_id=p_org and opening_date=p_date;
 if not found then raise exception 'Import opening balance journal before quantity lots';end if;
 select id into v_asset from public.accounts where organization_id=p_org and code='1400'
 and account_type='asset' and is_active;
 if v_asset is null then raise exception 'Inventory asset account unavailable';end if;
 select coalesce(sum(l.debit-l.credit),0) into v_gl_value from public.journal_lines l
 where l.organization_id=p_org and l.journal_entry_id=v_opening.journal_entry_id
 and l.account_id=v_asset;
 if v_gl_value<=0 then raise exception 'Opening journal must debit inventory asset 1400';end if;
 for v_item in select value from jsonb_array_elements(p_lots) loop
  v_index:=v_index+1;
  v_product:=nullif(v_item->>'product_id','')::uuid;
  v_qty:=(v_item->>'quantity')::numeric;
  v_cost:=(v_item->>'total_cost')::numeric;
  if v_qty is null or v_qty<=0 or scale(v_qty)>3 or v_cost is null or
   v_cost<=0 or scale(v_cost)>2 or
   not exists(select 1 from public.inventory_products where organization_id=p_org
    and id=v_product and active)
  then raise exception 'Invalid opening inventory lot number %',v_index;end if;
  v_total_cost:=v_total_cost+v_cost;v_total_quantity:=v_total_quantity+v_qty;
 end loop;
 if v_total_cost<>v_gl_value then
  raise exception 'Opening inventory lot valuation % must match previously posted inventory asset %',
   v_total_cost,v_gl_value;end if;
 insert into public.inventory_opening_batches(organization_id,opening_journal_id,effective_date,
 total_quantity,total_cost,payload_digest,idempotency_key,created_by)
 values(p_org,v_opening.journal_entry_id,p_date,v_total_quantity,v_total_cost,v_digest,p_key,auth.uid())
 returning id into v_id;
 v_index:=0;
 for v_item in select value from jsonb_array_elements(p_lots) loop
  v_index:=v_index+1;
  v_product:=(v_item->>'product_id')::uuid;
  v_qty:=(v_item->>'quantity')::numeric;
  v_cost:=(v_item->>'total_cost')::numeric;
  insert into public.inventory_receipts(organization_id,product_id,opening_batch_id,
   quantity,initial_cost,remaining_quantity,remaining_cost,received_on,
   journal_entry_id,idempotency_key,created_by)
  values(p_org,v_product,v_id,v_qty,v_cost,v_qty,v_cost,p_date,
    v_opening.journal_entry_id,md5(p_key::text||'-'||v_index)::uuid,auth.uid());
 end loop;
 perform private.write_audit(p_org,'inventory.opening_registered','inventory_opening_batch',v_id,
  jsonb_build_object('total_quantity',v_total_quantity,'total_value',v_total_cost));
 return v_id;
end $$;

create function public.import_qbo_inventory_products(p_org uuid,p_batch uuid,p_limit integer default 100)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_row public.migration_records%rowtype;v_product uuid;
 v_sku text;v_name text;v_count integer:=0;
begin
 if not exists(select 1 from public.organization_members where organization_id=p_org
 and user_id=auth.uid() and role in ('owner','accountant'))
 then raise exception 'Only owner/accountant may map QBO inventory';end if;
 if p_limit is null or p_limit not between 1 and 250 then raise exception 'Invalid import batch limit';end if;
 perform 1 from public.organizations where id=p_org for update;
 if not exists(select 1 from public.migration_batches where organization_id=p_org
  and id=p_batch and approved_at is not null and state in ('in_progress','completed'))
 then raise exception 'Source migration must be approved';end if;
 for v_row in select * from public.migration_records where organization_id=p_org
   and batch_id=p_batch and record_kind='inventory_item' and status='staged'
   and payload->'raw'->>'Type'='Inventory'
   order by created_at,id limit p_limit loop
  v_sku:=nullif(trim(coalesce(v_row.payload->'raw'->>'Sku','')),'');
  if v_sku is null or v_sku !~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$' then
   v_sku:='QBO-'||left(regexp_replace(v_row.source_id,'[^A-Za-z0-9]','','g'),60);
  end if;
  v_name:=left(trim(coalesce(v_row.payload->'raw'->>'Name','')),180);
  if length(v_name)<2 then raise exception 'Source inventory product name is invalid';end if;
  if exists(select 1 from public.inventory_products where organization_id=p_org and sku=upper(v_sku))
  then raise exception 'Review duplicate inventory SKU % before importing',v_sku;end if;
  v_product:=public.create_inventory_product(p_org,v_sku,v_name);
  update public.migration_records set status='imported',target_id=v_product
   where organization_id=p_org and id=v_row.id;
  v_count:=v_count+1;
 end loop;
 perform private.write_audit(p_org,'migration.inventory_products_created','migration',p_batch,
  jsonb_build_object('imported',v_count,'inventory_asset_double_posted',false));
 return jsonb_build_object('mapped_products',v_count,'opening_stock_posted',false);
end $$;

-- The source opening journal must also be protected from manual reversal.
create or replace function public.reverse_manual_journal(
 p_organization_id uuid,p_journal_id uuid,p_reversal_date date,p_reason text
) returns uuid language plpgsql security definer set search_path=''
as $$
begin
 if not public.has_org_write(p_organization_id) then raise exception 'Not authorized';end if;
 perform 1 from public.organizations where id=p_organization_id for update;
 if exists(select 1 from public.opening_balance_imports where organization_id=p_organization_id and journal_entry_id=p_journal_id)
 or exists(select 1 from public.year_end_closures where organization_id=p_organization_id and closing_journal_id=p_journal_id)
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
 then raise exception 'Source accounting journal cannot be manually reversed';end if;
 return public.reverse_manual_journal_legacy(p_organization_id,p_journal_id,p_reversal_date,p_reason);
end $$;

revoke all on function public.register_inventory_opening_lots(uuid,date,jsonb,uuid),
 public.import_qbo_inventory_products(uuid,uuid,integer) from public,anon;
grant execute on function public.register_inventory_opening_lots(uuid,date,jsonb,uuid),
 public.import_qbo_inventory_products(uuid,uuid,integer) to authenticated;
