begin;
insert into auth.users(id,email,email_confirmed_at,role,aud,created_at,updated_at)
values('99999999-9999-4999-8999-999999999941','inventory-cutover@example.invalid',now(),'authenticated','authenticated',now(),now());
set local role authenticated;
do $qa$
declare v_org uuid;v_batch uuid;v_product uuid;v_asset uuid;
 v_date date:=date_trunc('year',current_date)::date;v_result jsonb;
begin
 perform set_config('request.jwt.claim.sub','99999999-9999-4999-8999-999999999941',true);
 v_org:=public.create_organization('Milestone Nine Inventory Cutover Guard');
 v_batch:=public.create_migration_batch(v_org,'quickbooks_online','inventory-cutover-realm',current_date);
 perform public.stage_migration_records(v_org,v_batch,'inventory_item',
 jsonb_build_array(jsonb_build_object('source_id','sku-5','item_type','Inventory',
  'name','Imported stock item','sku','IMPORTED-5','quantity_on_hand',5,'unit_cost',12,
  'raw',jsonb_build_object('Id','sku-5','Type','Inventory','QtyOnHand',5,'PurchaseCost',12))));
 perform public.approve_migration_batch(v_org,v_batch);
 perform public.apply_reviewed_migration(v_org,v_batch);
 v_result:=public.inventory_migration_readiness(v_org,v_batch);
 if (v_result->>'ready')::boolean then
  raise exception 'Unmapped QBO inventory was marked ready for cutover';end if;
 perform public.import_qbo_inventory_products(v_org,v_batch,100);
 v_result:=public.inventory_migration_readiness(v_org,v_batch);
 if (v_result->>'ready')::boolean or
 (v_result->>'opening_quantity_mismatches')::integer<>1
 then raise exception 'Missing valued opening FIFO lot was accepted';end if;
 select id into v_product from public.inventory_products where organization_id=v_org and sku='IMPORTED-5';
 select id into v_asset from public.accounts where organization_id=v_org and code='1400';
 perform public.import_opening_balances(v_org,v_date,
  jsonb_build_array(jsonb_build_object('account_id',v_asset,'debit',60,'credit',0)));
 perform public.register_inventory_opening_lots(v_org,v_date,
  jsonb_build_array(jsonb_build_object('product_id',v_product,'quantity',5,'total_cost',60)),
  '99990000-0000-4000-8000-000000000041');
 v_result:=public.inventory_migration_readiness(v_org,v_batch);
 if not (v_result->>'ready')::boolean then
  raise exception 'Valued opening stock should satisfy source quantity reconciliation';end if;
 raise notice 'MILESTONE 9 INVENTORY CUTOVER GATE REGRESSION PASSED';
end $qa$;
rollback;