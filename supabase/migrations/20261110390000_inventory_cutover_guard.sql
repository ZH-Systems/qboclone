-- Inventory source cutover gate prevents signing off QBO companies with
-- unconverted positive stock quantities and missing opening inventory valuation.
create function public.inventory_migration_readiness(p_org uuid,p_batch uuid)
returns jsonb language plpgsql stable security definer set search_path=''
as $ready$
declare v_unmapped integer;v_mismatched integer;v_count integer;
begin
 if not public.has_org_access(p_org) then raise exception 'Not authorized';end if;
 if not exists(select 1 from public.migration_batches
  where organization_id=p_org and id=p_batch) then raise exception 'Migration batch not found';end if;
 select count(*) into v_count from public.migration_records r
 where r.organization_id=p_org and r.batch_id=p_batch and r.record_kind='inventory_item'
 and coalesce(r.payload->>'item_type',r.payload->'raw'->>'Type')='Inventory';
 select count(*) into v_unmapped from public.migration_records r
 where r.organization_id=p_org and r.batch_id=p_batch and r.record_kind='inventory_item'
 and coalesce(r.payload->>'item_type',r.payload->'raw'->>'Type')='Inventory'
 and (r.status<>'imported' or r.target_id is null);
 select count(*) into v_mismatched
 from public.migration_inventory_items i
 where i.organization_id=p_org and i.batch_id=p_batch and coalesce(i.source_quantity,0)>0
 and abs(i.source_quantity-coalesce((
  select sum(r.quantity) from public.inventory_receipts r
  where r.organization_id=p_org and r.product_id=i.product_id
   and r.opening_batch_id is not null),0))>0.001;
 return jsonb_build_object('ready',v_unmapped=0 and v_mismatched=0,
  'inventory_items',v_count,'unmapped',v_unmapped,'opening_quantity_mismatches',v_mismatched);
end $ready$;
revoke all on function public.inventory_migration_readiness(uuid,uuid) from public,anon;
grant execute on function public.inventory_migration_readiness(uuid,uuid) to authenticated;

create or replace function public.accept_migration_financial_cutover(p_org uuid,p_batch uuid)
returns void language plpgsql security definer set search_path=''
as $$
declare v_count integer;v_pending integer;v_inventory jsonb;
begin
 if not exists(select 1 from public.organization_members
  where organization_id=p_org and user_id=auth.uid() and role in ('owner','accountant'))
 then raise exception 'Owner or accountant signoff required';end if;
 perform 1 from public.organizations where id=p_org for update;
 select count(*) into v_count from public.migration_reconciliation_signoffs
  where organization_id=p_org and batch_id=p_batch and abs(difference)<=0.01
   and source_report_id is not null;
 select count(*) into v_pending from public.migration_records
  where organization_id=p_org and batch_id=p_batch and (record_kind in ('invoice','bill','payment','bill_payment','credit_note','vendor_credit')
   or (record_kind='journal' and coalesce((payload->>'post_as_standalone')::boolean,false)))
  and not financial_posted;
 v_inventory:=public.inventory_migration_readiness(p_org,p_batch);
 if coalesce((v_inventory->>'ready')::boolean,false)=false then
  raise exception 'Financial cutover blocked: inventory source SKU/quantity valuation is unreconciled';
 end if;
  if v_count<>6 or v_pending<>0 then
  raise exception 'Financial cutover blocked: six evidenced reconciliations and posted open items required';end if;
 if not exists(select 1 from public.migration_batches where organization_id=p_org
  and id=p_batch and state='completed' and approved_at is not null)
 then raise exception 'Migration draft import is not complete';end if;
 update public.migration_batches set financial_cutover_approved_at=now(),
  financial_cutover_approved_by=auth.uid()
 where id=p_batch and organization_id=p_org and financial_cutover_approved_at is null;
 if not found then raise exception 'Migration cutover already approved';end if;
 perform private.write_audit(p_org,'migration.financial_cutover_accepted','migration',p_batch,
  jsonb_build_object('controls_passed',6));
end $$;
revoke all on function public.accept_migration_financial_cutover(uuid,uuid) from public,anon;
grant execute on function public.accept_migration_financial_cutover(uuid,uuid) to authenticated;
