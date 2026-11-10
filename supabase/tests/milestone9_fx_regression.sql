begin;
insert into auth.users(id,email,email_confirmed_at,role,aud,created_at,updated_at)
values('99999999-9999-4999-8999-999999999971','fx-owner@example.invalid',now(),'authenticated','authenticated',now(),now()),
('99999999-9999-4999-8999-999999999972','fx-outsider@example.invalid',now(),'authenticated','authenticated',now(),now());
set local role authenticated;
do $fx$
declare v_org uuid;v_customer uuid;v_vendor uuid;v_invoice uuid;v_bill uuid;
v_pay uuid;v_loss numeric;v_gain numeric;v_balance numeric;v_failed boolean;
begin
 perform set_config('request.jwt.claim.sub','99999999-9999-4999-8999-999999999971',true);
 v_org:=public.create_organization('Milestone Nine FX QA');
 v_customer:=public.create_contact(v_org,'customer','Foreign Buyer');
 v_vendor:=public.create_contact(v_org,'vendor','Foreign Vendor');
 v_invoice:=public.create_financial_document(v_org,v_customer,'invoice',current_date,current_date+14,
 'USD accounting invoice',null,jsonb_build_array(jsonb_build_object(
  'description','USD service translated CAD','quantity',1,'unit_price',140,'tax_rate_bps',0)));
 perform public.denominate_draft_in_foreign_currency(v_org,v_invoice,'USD',100,1.4);
 perform public.post_financial_document(v_org,v_invoice);
 v_failed:=false;
 begin perform public.record_document_payment(v_org,v_invoice,140,current_date,
  'Invalid generic FX payment','99990000-0000-4000-8000-000000000021');
 exception when others then v_failed:=true;end;
 if not v_failed then raise exception 'Standard payment accepted foreign document';end if;
 v_pay:=public.record_foreign_currency_payment(v_org,v_invoice,100,140,146,current_date,
  'Bank exchanged USD','99990000-0000-4000-8000-000000000022');
 if v_pay<>public.record_foreign_currency_payment(v_org,v_invoice,100,140,146,current_date,
  'Bank exchanged USD','99990000-0000-4000-8000-000000000022')
 then raise exception 'FX payment replay not idempotent';end if;
 if public.document_outstanding(v_org,v_invoice)<>0 then
  raise exception 'Foreign invoice outstanding CAD not settled';end if;
 select realized_fx_gain,realized_fx_loss into v_gain,v_loss from public.foreign_document_payments
 where organization_id=v_org and payment_id=v_pay;
 if v_gain<>6 or v_loss<>0 then raise exception 'Expected CAD 6 realized FX gain';end if;
 v_failed:=false;
 begin perform public.refund_document_payment(v_org,v_pay,20,current_date,
  'FX refund needs accountant','99990000-0000-4000-8000-000000000023');
 exception when others then v_failed:=true;end;
 if not v_failed then raise exception 'Unbalanced generic refund of FX settlement was allowed';end if;
 v_bill:=public.create_financial_document(v_org,v_vendor,'bill',current_date,current_date+14,
 'USD supplier invoice',null,jsonb_build_array(jsonb_build_object(
  'description','USD purchase translated CAD','quantity',1,'unit_price',70,'tax_rate_bps',0)));
 perform public.denominate_draft_in_foreign_currency(v_org,v_bill,'USD',50,1.4);
 perform public.post_financial_document(v_org,v_bill);
 v_pay:=public.record_foreign_currency_payment(v_org,v_bill,50,70,74,current_date,
  'Vendor bank transfer','99990000-0000-4000-8000-000000000024');
 select realized_fx_gain,realized_fx_loss into v_gain,v_loss from public.foreign_document_payments
 where organization_id=v_org and payment_id=v_pay;
 if v_loss<>4 or v_gain<>0 then raise exception 'Expected CAD 4 FX loss';end if;
 if public.document_outstanding(v_org,v_bill)<>0 then raise exception 'Foreign bill not settled';end if;
 select coalesce(sum(total_debits-total_credits),0) into v_balance
 from public.ledger_trial_balance(v_org,current_date);
 if v_balance<>0 then raise exception 'FX settlement journals unbalanced';end if;
 perform set_config('request.jwt.claim.sub','99999999-9999-4999-8999-999999999972',true);
 if exists(select 1 from public.foreign_document_payments where organization_id=v_org)
 then raise exception 'FX payment record leaked across tenants';end if;
 raise notice 'MILESTONE 9 FX REALIZED GAIN/LOSS REGRESSION PASSED';
end $fx$;
rollback;