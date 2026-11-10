begin;
insert into auth.users(id,email,email_confirmed_at,role,aud,created_at,updated_at)
values('99999999-9999-4999-8999-999999999951','opening-owner@example.invalid',now(),'authenticated','authenticated',now(),now());
set local role authenticated;
do $qa$
declare v_org uuid;v_product uuid;v_inventory uuid;v_begin date;
 v_import uuid;v_batch uuid;v_stock_batch uuid;v_qty numeric;v_cost numeric;v_gl numeric;
 v_invoice uuid;v_line uuid;v_customer uuid;v_failed boolean;
begin
 perform set_config('request.jwt.claim.sub','99999999-9999-4999-8999-999999999951',true);
 v_org:=public.create_organization('Milestone Nine Opening Inventory QA');
 v_begin:=date_trunc('year',current_date)::date;
 select id into v_inventory from public.accounts where organization_id=v_org and code='1400';
 if v_inventory is null then raise exception 'Inventory account was not seeded';end if;
 v_product:=public.create_inventory_product(v_org,'OPEN-001','Opening stock inventory');
 v_import:=public.import_opening_balances(v_org,v_begin,
  jsonb_build_array(jsonb_build_object('account_id',v_inventory,'debit',100,'credit',0)));
 v_stock_batch:=public.register_inventory_opening_lots(v_org,v_begin,
 jsonb_build_array(jsonb_build_object('product_id',v_product,'quantity',10,'total_cost',100)),
 '99990000-0000-4000-8000-000000000031');
 if v_stock_batch<>public.register_inventory_opening_lots(v_org,v_begin,
 jsonb_build_array(jsonb_build_object('product_id',v_product,'quantity',10,'total_cost',100)),
 '99990000-0000-4000-8000-000000000031')
 then raise exception 'Opening inventory idempotency failed';end if;
 select quantity,cost into v_qty,v_cost from public.inventory_stock_summary(v_org)
 where product_id=v_product;
 if v_qty<>10 or v_cost<>100 then raise exception 'Opening lot valuation incorrect';end if;
 select coalesce(sum(l.debit-l.credit),0) into v_gl from public.journal_lines l
 where l.organization_id=v_org and l.journal_entry_id=v_import and l.account_id=v_inventory;
 if v_gl<>100 then raise exception 'Opening inventory doubled its GL balance';end if;
 v_failed:=false;
 begin perform public.register_inventory_opening_lots(v_org,v_begin,
 jsonb_build_array(jsonb_build_object('product_id',v_product,'quantity',10,'total_cost',101)),
 '99990000-0000-4000-8000-000000000032');
 exception when others then v_failed:=true;end;
 if not v_failed then raise exception 'Duplicate/inconsistent opening inventory permitted';end if;
 v_customer:=public.create_contact(v_org,'customer','Opening Buyer');
 v_invoice:=public.create_financial_document(v_org,v_customer,'invoice',current_date,current_date+14,
  'Sell two opening widgets',null,jsonb_build_array(jsonb_build_object(
  'description','Opening stock widgets','quantity',2,'unit_price',20,'tax_rate_bps',0)));
 perform public.post_financial_document(v_org,v_invoice);
 select id into v_line from public.financial_document_lines
 where organization_id=v_org and document_id=v_invoice and position=1;
 perform public.issue_inventory_invoice_line(v_org,v_product,v_line,current_date,
  '99990000-0000-4000-8000-000000000033');
 select quantity,cost into v_qty,v_cost from public.inventory_stock_summary(v_org)
 where product_id=v_product;
 if v_qty<>8 or v_cost<>80 then raise exception 'FIFO issue against opening lots failed';end if;
 v_batch:=public.create_migration_batch(v_org,'quickbooks_online','opening-test',current_date);
 perform public.stage_migration_records(v_org,v_batch,'inventory_item',jsonb_build_array(
  jsonb_build_object('source_id','qbo-88','raw',jsonb_build_object(
   'Id','88','Type','Inventory','Name','Imported Widget','Sku','QBO-WIDGET-2'))));
 perform public.approve_migration_batch(v_org,v_batch);
 perform public.apply_reviewed_migration(v_org,v_batch);
 perform public.import_qbo_inventory_products(v_org,v_batch,100);
 if not exists(select 1 from public.inventory_products where organization_id=v_org
  and sku='QBO-WIDGET-2') then raise exception 'QuickBooks SKU mapping missing';end if;
 if not exists(select 1 from public.migration_records where organization_id=v_org and
  batch_id=v_batch and source_id='qbo-88' and status='imported' and target_id is not null)
 then raise exception 'QBO inventory source ID crosswalk incomplete';end if;
 raise notice 'MILESTONE 9 OPENING INVENTORY AND QBO SKU REGRESSION PASSED';
end $qa$;
rollback;