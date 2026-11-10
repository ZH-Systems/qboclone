-- Milestone 6 integration: fiscal closing, refunds, tax classification and reports.
-- Disposable PostgreSQL with synthetic auth only. All inserts rolled back.
begin;
insert into auth.users(id,email,email_confirmed_at,role,aud,created_at,updated_at) values
 ('66666666-6666-4666-8666-666666666661','m6owner@example.invalid',now(),'authenticated','authenticated',now(),now()),
 ('66666666-6666-4666-8666-666666666662','m6outsider@example.invalid',now(),'authenticated','authenticated',now(),now());
set local role authenticated;
do $test$
declare
 v_org uuid;v_other uuid;v_older uuid;v_period_id uuid;v_customer uuid;v_vendor uuid;
 v_invoice uuid;v_bill uuid;v_current_invoice uuid;v_payment uuid;v_refund uuid;v_credit uuid;
 v_close jsonb;v_journal uuid;v_balance numeric;v_amt numeric;
 v_sum_revenue numeric;v_sum_expense numeric;v_net numeric;v_failed boolean;
 v_bank uuid;v_expense uuid;v_sales uuid;v_tax_code uuid;v_adjust uuid;v_count integer;
begin
 perform set_config('request.jwt.claim.sub','66666666-6666-4666-8666-666666666661',true);
 v_org:=public.create_organization('M6 Financial Controls');
 v_customer:=public.create_contact(v_org,'customer','Year End Client',null);
 v_vendor:=public.create_contact(v_org,'vendor','Year End Vendor',null);
 select id into v_bank from public.accounts where organization_id=v_org and code='1000';
 select id into v_expense from public.accounts where organization_id=v_org and code='5000';
 select id into v_sales from public.accounts where organization_id=v_org and code='4000';

 if public.canadian_gst_hst_rate('ON','2026-11-10','taxable')<>1300
  or public.canadian_gst_hst_rate('NS','2025-03-31','taxable')<>1500
  or public.canadian_gst_hst_rate('NS','2025-04-01','taxable')<>1400
  or public.canadian_gst_hst_rate('BC','2026-11-10','taxable')<>500
  or public.canadian_gst_hst_rate('QC','2026-11-10','zero_rated')<>0
 then raise exception 'Canadian GST/HST rate regression';end if;
 v_tax_code:=public.create_canadian_tax_code(v_org,'ON2026','Ontario GST/HST','sale','ON','taxable','2026-11-10',0);
 select rate_bps into v_amt from public.tax_codes where id=v_tax_code;
 if v_amt<>1300 then raise exception 'Unexpected configured HST rate';end if;

 -- Backdate a closed historical year without changing the current fiscal year.
 v_period_id:=public.create_fiscal_period(v_org,'2025-01-01','2025-12-31');
 v_invoice:=public.create_financial_document(v_org,v_customer,'invoice',
   '2025-12-01','2025-12-20','Historical sale',null,
   jsonb_build_array(jsonb_build_object('description','Consulting','quantity',1,
     'unit_price',100,'tax_rate_bps',0)));
 perform public.post_financial_document(v_org,v_invoice);
 v_bill:=public.create_financial_document(v_org,v_vendor,'bill',
  '2025-12-01','2025-12-20','Historical expense',null,
  jsonb_build_array(jsonb_build_object('description','Office','quantity',1,
   'unit_price',40,'tax_rate_bps',0)));
 perform public.post_financial_document(v_org,v_bill);

 select coalesce(sum(case when account_type='revenue' then amount else 0 end),0),
   coalesce(sum(case when account_type='expense' then amount else 0 end),0)
 into v_sum_revenue,v_sum_expense from public.ledger_profit_loss(v_org,'2025-01-01','2025-12-31');
 if v_sum_revenue<>100 or v_sum_expense<>40 then raise exception 'Preclose P&L incorrect';end if;
 v_close:=public.close_financial_year(v_org,v_period_id);
 if (v_close->>'net_income')::numeric<>60 then raise exception 'Year-end income should be 60';end if;
 if not (select is_locked from public.fiscal_periods where id=v_period_id) then
  raise exception 'Financial year was not locked';end if;
 if not (public.close_financial_year(v_org,v_period_id)->>'already_closed')::boolean then
  raise exception 'Closing a second time was not idempotent';end if;
 select coalesce(sum(l.credit-l.debit),0) into v_balance
 from public.journal_lines l join public.accounts a on a.id=l.account_id
 where l.organization_id=v_org and a.code='3100';
 if v_balance<>60 then raise exception 'Retained earnings not credited by 60';end if;
 select coalesce(sum(amount),0) into v_balance
 from public.ledger_profit_loss(v_org,'2025-01-01','2025-12-31');
 if v_balance<>140 then raise exception 'Closing journal contaminated historical P&L';end if;
 v_failed:=false;
 begin perform public.set_fiscal_period_lock(v_org,v_period_id,false);
 exception when others then v_failed:=true;end;
 if not v_failed then raise exception 'Closed period was reopened';end if;
 v_failed:=false;
 begin perform public.reverse_manual_journal(v_org,(v_close->>'journal_id')::uuid,
  '2026-11-10','Attempt to reverse closing journal');
 exception when others then v_failed:=true;end;
 if not v_failed then raise exception 'Closing journal reversal allowed';end if;

 -- Current-year paid invoice, refunded $30 then credit note $30.
 v_current_invoice:=public.create_financial_document(v_org,v_customer,'invoice',
  '2026-11-10','2026-11-10','Current sale',null,
  jsonb_build_array(jsonb_build_object('description','Work','quantity',1,
   'unit_price',100,'tax_rate_bps',0)));
 perform public.post_financial_document(v_org,v_current_invoice);
 v_payment:=public.record_document_payment(v_org,v_current_invoice,100,'2026-11-10',
  'Full receipt','66661111-1111-4111-8111-111111111111');
 v_refund:=public.refund_document_payment(v_org,v_payment,30,'2026-11-10',
  'Duplicate charge refund','66662222-2222-4222-8222-222222222222');
 if v_refund<>public.refund_document_payment(v_org,v_payment,30,'2026-11-10',
  'Duplicate charge refund','66662222-2222-4222-8222-222222222222') then
  raise exception 'Refund replay not idempotent';end if;
 if public.document_outstanding(v_org,v_current_invoice)<>30 then
  raise exception 'Refund did not restore outstanding AR';end if;
 v_failed:=false;
 begin perform public.refund_document_payment(v_org,v_payment,80,'2026-11-10',
  'Over refund request','66663333-3333-4333-8333-333333333333');
 exception when others then v_failed:=true;end;
 if not v_failed then raise exception 'Over-refund was not rejected';end if;
 v_credit:=public.create_financial_document(v_org,v_customer,'credit_note',
  '2026-11-10','2026-11-10','Refunded work',v_current_invoice,
  jsonb_build_array(jsonb_build_object('description','Credit','quantity',1,
   'unit_price',30,'tax_rate_bps',0)));
 perform public.post_financial_document(v_org,v_credit);
 if public.document_outstanding(v_org,v_current_invoice)<>0 then
  raise exception 'Refund plus credit failed to settle invoice';end if;

 v_adjust:=public.post_adjusting_journal(v_org,'2026-11-10','accrual',
  'Adjustment for documented office expense','66664444-4444-4444-8444-444444444444',
  jsonb_build_array(jsonb_build_object('account_id',v_expense,'debit',5,'credit',0),
   jsonb_build_object('account_id',v_bank,'debit',0,'credit',5)));
 if not exists(select 1 from public.accounting_adjustments where organization_id=v_org
   and journal_entry_id=v_adjust) then raise exception 'Adjustment not recorded';end if;

 select count(*) into v_count from public.aged_open_documents(v_org,'2025-12-31','invoice')
 where document_id=v_invoice and outstanding=100;
 if v_count<>1 then raise exception 'Historical invoice aging incorrect';end if;
 select count(*) into v_count from public.aged_open_documents(v_org,'2026-11-10','invoice')
 where document_id=v_current_invoice;
 if v_count<>0 then raise exception 'Fully offset current invoice appears in aging';end if;
 select coalesce(sum(total_debits-total_credits),0) into v_balance
 from public.ledger_trial_balance(v_org,'2026-11-10');
 if v_balance<>0 then raise exception 'Trial balance no longer balances';end if;
 if not exists(select 1 from public.gst_hst_tax_summary(v_org,'2026-11-01','2026-11-30')
  where transaction_kind='sale') then raise exception 'Tax summary empty';end if;
 if not exists(select 1 from public.ledger_balance_sheet(v_org,'2026-11-10')
  where account_code='3100' and amount=60) then raise exception 'Balance sheet retained earnings missing';end if;

 -- Tenant denial for privileged year-end functions.
 perform set_config('request.jwt.claim.sub','66666666-6666-4666-8666-666666666662',true);
 v_other:=public.create_organization('M6 Outsider');
 v_failed:=false;
 begin perform public.close_financial_year(v_org,v_period_id);
 exception when others then v_failed:=true;end;
 if not v_failed then raise exception 'Cross-tenant year-end closure allowed';end if;
 if exists(select 1 from public.payment_refunds where organization_id=v_org)
 then raise exception 'Cross-tenant refund data leaked';end if;
 raise notice 'MILESTONE 6 ACCOUNTING ASSERTIONS PASSED';
end $test$;
rollback;
