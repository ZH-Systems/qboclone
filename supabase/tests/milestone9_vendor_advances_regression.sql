begin;
insert into auth.users(id,email,email_confirmed_at,role,aud,created_at,updated_at)
values('99999999-9999-4999-8999-999999999981','advance-owner@example.invalid',now(),'authenticated','authenticated',now(),now()),
('99999999-9999-4999-8999-999999999982','advance-outsider@example.invalid',now(),'authenticated','authenticated',now(),now());
set local role authenticated;
do $qa$
declare v_org uuid;v_vendor uuid;v_bill uuid;v_advance uuid;v_application uuid;v_refund uuid;
v_balance numeric;v_failed boolean:=false;v_as_of date:=current_date;
begin
 perform set_config('request.jwt.claim.sub','99999999-9999-4999-8999-999999999981',true);
 v_org:=public.create_organization('Milestone Nine Vendor Credit QA');
 v_vendor:=public.create_contact(v_org,'vendor','Advance Supplier','test@example.invalid');
 v_bill:=public.create_financial_document(v_org,v_vendor,'bill',v_as_of,v_as_of+14,
 'Partial supplier prepayment',null,jsonb_build_array(jsonb_build_object(
  'description','Professional services','quantity',1,'unit_price',100,'tax_rate_bps',0)));
 perform public.post_financial_document(v_org,v_bill);
 v_advance:=public.pay_vendor_advance(v_org,v_vendor,80,v_as_of,'Prepayment',
 '99990000-0000-4000-8000-000000000011');
 if v_advance<>public.pay_vendor_advance(v_org,v_vendor,80,v_as_of,'Prepayment',
 '99990000-0000-4000-8000-000000000011') then raise exception 'Advance replay failed';end if;
 v_application:=public.apply_vendor_advance(v_org,v_advance,v_bill,60,v_as_of,
 '99990000-0000-4000-8000-000000000012');
 if public.document_outstanding(v_org,v_bill)<>40 or
 public.vendor_advance_available(v_org,v_advance)<>20
 then raise exception 'Supplier advance did not reduce AP or remaining advance';end if;
 v_refund:=public.refund_vendor_advance(v_org,v_advance,20,v_as_of,
  'Supplier returned balance','99990000-0000-4000-8000-000000000013');
 if public.vendor_advance_available(v_org,v_advance)<>0 then
  raise exception 'Supplier refund failed to close advance';end if;
 if not exists(select 1 from public.aged_open_documents(v_org,v_as_of,'bill')
  where document_id=v_bill and outstanding=40) then raise exception 'AP aging omitted supplier advance';end if;
 v_failed:=false;
 begin perform public.apply_vendor_advance(v_org,v_advance,v_bill,1,v_as_of,
  '99990000-0000-4000-8000-000000000014');
 exception when others then v_failed:=true;end;
 if not v_failed then raise exception 'Excess vendor allocation accepted';end if;
 select coalesce(sum(total_debits-total_credits),0) into v_balance
 from public.ledger_trial_balance(v_org,v_as_of);
 if v_balance<>0 then raise exception 'Vendor advance entries are not balanced';end if;
 perform set_config('request.jwt.claim.sub','99999999-9999-4999-8999-999999999982',true);
 if exists(select 1 from public.vendor_advances where organization_id=v_org)
 then raise exception 'Vendor advance RLS leaked another tenant';end if;
 raise notice 'MILESTONE 9 VENDOR ADVANCE REGRESSION PASSED';
end $qa$;
rollback;