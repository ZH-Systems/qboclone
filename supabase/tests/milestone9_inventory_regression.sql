-- Milestone 9 FIFO inventory regression, synthetic tenant auth, rollback-only.
begin;
insert into auth.users(id,email,email_confirmed_at,role,aud,created_at,updated_at)
values('99999999-9999-4999-8999-999999999991','inventory-owner@example.invalid',now(),'authenticated','authenticated',now(),now()),
('99999999-9999-4999-8999-999999999992','inventory-outsider@example.invalid',now(),'authenticated','authenticated',now(),now());
set local role authenticated;
do $inventory$
declare
 v_org uuid;v_product uuid;v_vendor uuid;v_customer uuid;v_bill uuid;v_bill2 uuid;
 v_bill_line uuid;v_bill_line2 uuid;v_invoice uuid;v_invoice_line uuid;
 v_rcv1 uuid;v_rcv2 uuid;v_issue uuid;v_on_hand numeric;v_value numeric;
 v_cogs numeric;v_balance numeric;v_failed boolean:=false;
begin
 perform set_config('request.jwt.claim.sub','99999999-9999-4999-8999-999999999991',true);
 v_org:=public.create_organization('Milestone Nine FIFO Demo');
 v_product:=public.create_inventory_product(v_org,'WIDGET-001','Widget Inventory');
 v_vendor:=public.create_contact(v_org,'vendor','Supplier Example','vendor@example.invalid');
 v_customer:=public.create_contact(v_org,'customer','Buyer Example','buyer@example.invalid');
 v_bill:=public.create_financial_document(v_org,v_vendor,'bill',current_date,current_date+14,
  'First stock receipt',null,jsonb_build_array(jsonb_build_object('description','Stock at three dollars',
   'quantity',10,'unit_price',3,'tax_rate_bps',0)));
 perform public.post_financial_document(v_org,v_bill);
 select id into v_bill_line from public.financial_document_lines
  where organization_id=v_org and document_id=v_bill and position=1;
 v_rcv1:=public.receive_inventory_bill_line(v_org,v_product,v_bill_line,current_date,
  '99990000-0000-4000-8000-000000000001');
 if v_rcv1<>public.receive_inventory_bill_line(v_org,v_product,v_bill_line,current_date,
  '99990000-0000-4000-8000-000000000001') then raise exception 'Receipt replay not idempotent';end if;
 v_bill2:=public.create_financial_document(v_org,v_vendor,'bill',current_date,current_date+14,
  'Second stock receipt',null,jsonb_build_array(jsonb_build_object('description','Stock at five dollars',
   'quantity',10,'unit_price',5,'tax_rate_bps',0)));
 perform public.post_financial_document(v_org,v_bill2);
 select id into v_bill_line2 from public.financial_document_lines
  where organization_id=v_org and document_id=v_bill2 and position=1;
 v_rcv2:=public.receive_inventory_bill_line(v_org,v_product,v_bill_line2,current_date,
  '99990000-0000-4000-8000-000000000002');
 v_invoice:=public.create_financial_document(v_org,v_customer,'invoice',current_date,current_date+14,
  'Sell twelve widgets',null,jsonb_build_array(jsonb_build_object('description','Widgets',
   'quantity',12,'unit_price',9,'tax_rate_bps',0)));
 perform public.post_financial_document(v_org,v_invoice);
 select id into v_invoice_line from public.financial_document_lines
  where organization_id=v_org and document_id=v_invoice and position=1;
 v_issue:=public.issue_inventory_invoice_line(v_org,v_product,v_invoice_line,current_date,
  '99990000-0000-4000-8000-000000000003');
 if v_issue<>public.issue_inventory_invoice_line(v_org,v_product,v_invoice_line,current_date,
  '99990000-0000-4000-8000-000000000003') then raise exception 'Issue replay not idempotent';end if;
 select quantity,cost into v_on_hand,v_value from public.inventory_stock_summary(v_org)
 where product_id=v_product;
 select total_cost into v_cogs from public.inventory_issues where id=v_issue;
 if v_on_hand<>8 or v_value<>40 or v_cogs<>40 then
  raise exception 'FIFO expected 8 units $40 left and $40 COGS, got %/%/%',
    v_on_hand,v_value,v_cogs;end if;
 if not exists(select 1 from public.inventory_issue_lots where issue_id=v_issue
  and receipt_id=v_rcv1 and quantity=10 and cost=30) or
  not exists(select 1 from public.inventory_issue_lots where issue_id=v_issue
  and receipt_id=v_rcv2 and quantity=2 and cost=10)
 then raise exception 'FIFO lot allocations incorrect';end if;
 v_failed:=false;
 begin perform public.issue_inventory_invoice_line(v_org,v_product,v_invoice_line,current_date,
 '99990000-0000-4000-8000-000000000004');
 exception when others then v_failed:=true;end;
 if not v_failed then raise exception 'Double issuing one invoice line allowed';end if;
 select coalesce(sum(total_debits-total_credits),0) into v_balance
 from public.ledger_trial_balance(v_org,current_date);
 if v_balance<>0 then raise exception 'Inventory journals unbalanced';end if;
 perform set_config('request.jwt.claim.sub','99999999-9999-4999-8999-999999999992',true);
 if exists(select 1 from public.inventory_products where organization_id=v_org)
 then raise exception 'Inventory cross-tenant product leak';end if;
 v_failed:=false;
 begin perform public.issue_inventory_invoice_line(v_org,v_product,v_invoice_line,current_date,
 '99990000-0000-4000-8000-000000000005');
 exception when others then v_failed:=true;end;
 if not v_failed then raise exception 'Cross-tenant inventory issue authorized';end if;
 raise notice 'MILESTONE 9 FIFO INVENTORY REGRESSION PASSED';
end $inventory$;
rollback;
