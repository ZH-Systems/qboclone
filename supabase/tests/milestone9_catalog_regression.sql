-- Milestone 9 QBO inventory catalog and reversal safety, rollback only.
begin;
insert into auth.users(id,email,email_confirmed_at,role,aud,created_at,updated_at)
values('99999999-9999-4999-8999-999999999981','catalog-owner@example.invalid',now(),'authenticated','authenticated',now(),now());
set local role authenticated;
do $catalog$
declare v_org uuid;v_batch uuid;v_record uuid;v_result jsonb;v_count integer;
 v_product uuid;v_failed boolean:=false;
begin
 perform set_config('request.jwt.claim.sub','99999999-9999-4999-8999-999999999981',true);
 v_org:=public.create_organization('M9 Inventory Catalog QA');
 v_batch:=public.create_migration_batch(v_org,'quickbooks_online','m9-test-company',current_date);
 perform public.stage_migration_records(v_org,v_batch,'inventory_item',
  jsonb_build_array(jsonb_build_object('source_id','item-a','sku','TEST-A','name','Widget from QBO',
  'item_type','Inventory','quantity_on_hand',100,'unit_cost',12.50),
  jsonb_build_object('source_id','service-a','sku','SERVICE-A','name','Non-stock Consulting',
  'item_type','Service','quantity_on_hand',0,'unit_cost',0)));
 perform public.approve_migration_batch(v_org,v_batch);
 perform public.apply_reviewed_migration(v_org,v_batch);
 v_result:=public.import_qbo_inventory_catalog(v_org,v_batch,100);
 if (v_result->>'products_imported')::integer<>1 or
  (v_result->>'stock_quantity_posted')::boolean then raise exception 'Catalog source import state wrong';end if;
 select target_id into v_product from public.migration_records
 where organization_id=v_org and batch_id=v_batch and record_kind='inventory_item'
 and source_id='item-a';
 if v_product is null then raise exception 'QBO stock item not mapped to product';end if;
 if not exists(select 1 from public.inventory_products where id=v_product and sku='TEST-A')
 then raise exception 'Source SKU missing';end if;
 if (select quantity from public.inventory_stock_summary(v_org) where product_id=v_product)<>0
 then raise exception 'Imported QBO source stock without valuation review';end if;
 select count(*) into v_count from public.migration_records
 where organization_id=v_org and batch_id=v_batch and source_id='service-a' and status='staged';
 if v_count<>1 then raise exception 'Service item source record should remain staged';end if;
 v_result:=public.import_qbo_inventory_catalog(v_org,v_batch,100);
 if (v_result->>'products_imported')::integer<>0 then raise exception 'Replayed inventory catalog import';end if;
 raise notice 'MILESTONE 9 QBO INVENTORY CATALOG REGRESSION PASSED';
end $catalog$;
rollback;
