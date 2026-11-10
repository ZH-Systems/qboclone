-- Milestone 2 development regression script.
-- Run only against a disposable Supabase test database AFTER migrations 1-3.
-- Execute using a privileged migration/test connection. All fixtures are rolled back.
begin;
insert into auth.users(id,email,role,aud,created_at,updated_at) values
('11111111-1111-4111-8111-111111111111','ledger-qa-user-a@example.invalid','authenticated','authenticated',now(),now()),
('22222222-2222-4222-8222-222222222222','ledger-qa-user-b@example.invalid','authenticated','authenticated',now(),now());
set local role authenticated;
do $test$
declare
  a uuid; b uuid; customer uuid; vendor uuid; inv uuid; bill uuid; credit_doc uuid;
  inv_journal uuid; payment1 uuid; payment2 uuid; ar uuid; rev uuid; cash uuid;
  expense uuid; sales_tax uuid; ap uuid; payment_total numeric; outstanding numeric;
  manual_journal uuid; reversing_journal uuid; v_locked uuid;
  t_debit numeric; t_credit numeric; v_error boolean;
  posting_lines jsonb; v_period_start date:=date_trunc('year',current_date)::date;
  user_a uuid:='11111111-1111-4111-8111-111111111111';
  user_b uuid:='22222222-2222-4222-8222-222222222222';
begin
  perform set_config('request.jwt.claim.sub',user_a::text,true);
  a:=public.create_organization('QA Company A');
  customer:=public.create_contact(a,'customer','QA Client A',null);
  vendor:=public.create_contact(a,'vendor','QA Supplier A',null);
  select id into ar from public.accounts where organization_id=a and code='1100';
  select id into rev from public.accounts where organization_id=a and code='4000';
  select id into cash from public.accounts where organization_id=a and code='1000';
  select id into ap from public.accounts where organization_id=a and code='2000';
  select id into expense from public.accounts where organization_id=a and code='5000';
  select id into sales_tax from public.accounts where organization_id=a and code='2100';

  -- Source invoice, $100 net + $13 manual-rate tax.
  inv:=public.create_financial_document(
    a,customer,'invoice',current_date,current_date,'QA invoice',null,
    jsonb_build_array(jsonb_build_object(
      'description','QA Service','quantity',1,'unit_price',100,'tax_rate_bps',1300)));
  select total into outstanding from public.financial_documents where id=inv;
  if outstanding<>113 then raise exception 'FAIL: document total'; end if;
  inv_journal:=public.post_financial_document(a,inv);
  if public.post_financial_document(a,inv)<>inv_journal then
    raise exception 'FAIL: duplicate invoice posting was not idempotent';
  end if;
  select count(*) into payment_total from public.journal_lines where journal_entry_id=inv_journal;
  if payment_total<>3 then raise exception 'FAIL: invoice posting must have three journal lines'; end if;
  select coalesce(sum(debit),0),coalesce(sum(credit),0) into t_debit,t_credit
    from public.journal_lines where journal_entry_id=inv_journal;
  if t_debit<>113 or t_credit<>113 then raise exception 'FAIL: invoice journal not balanced'; end if;

  -- Partial payment + duplicate attempt. Then source-linked credit and remainder payment.
  payment1:=public.record_document_payment(
    a,inv,30,current_date,'qa-partial','33333333-3333-4333-8333-333333333333');
  if payment1<>public.record_document_payment(
    a,inv,30,current_date,'qa-partial','33333333-3333-4333-8333-333333333333')
    then raise exception 'FAIL: payment idempotency'; end if;
  credit_doc:=public.create_financial_document(
    a,customer,'credit_note',current_date,current_date,'QA credit',inv,
    jsonb_build_array(jsonb_build_object(
      'description','QA Return','quantity',1,'unit_price',20,'tax_rate_bps',0)));
  perform public.post_financial_document(a,credit_doc);
  outstanding:=public.document_outstanding(a,inv);
  if outstanding<>63 then raise exception 'FAIL: credit/payment outstanding expected 63, got %',outstanding; end if;
  payment2:=public.record_document_payment(
    a,inv,63,current_date,'qa-final','44444444-4444-4444-8444-444444444444');
  if public.document_outstanding(a,inv)<>0 then raise exception 'FAIL: invoice not settled'; end if;
  v_error:=false;
  begin
    perform public.record_document_payment(
      a,inv,1,current_date,'overpayment','55555555-5555-4555-8555-555555555555');
  exception when others then v_error:=true; end;
  if not v_error then raise exception 'FAIL: overpayment accepted'; end if;

  -- Vendor bill posting and payment.
  bill:=public.create_financial_document(
    a,vendor,'bill',current_date,current_date,'QA bill',null,
    jsonb_build_array(jsonb_build_object(
      'description','QA Vendor','quantity',1,'unit_price',40,'tax_rate_bps',0)));
  perform public.post_financial_document(a,bill);
  perform public.record_document_payment(
    a,bill,40,current_date,'vendor-paid','66666666-6666-4666-8666-666666666666');
  if public.document_outstanding(a,bill)<>0 then raise exception 'FAIL: bill not paid'; end if;

  -- Manual reversal must be idempotent and not affect source documents.
  posting_lines:=jsonb_build_array(
    jsonb_build_object('account_id',cash,'debit',10,'credit',0),
    jsonb_build_object('account_id',rev,'debit',0,'credit',10));
  manual_journal:=public.post_journal(
    a,current_date,'QA manual','QA-MAN','77777777-7777-4777-8777-777777777777',posting_lines);
  reversing_journal:=public.reverse_manual_journal(a,manual_journal,current_date,'QA correction');
  if public.reverse_manual_journal(a,manual_journal,current_date,'QA correction')<>reversing_journal then
    raise exception 'FAIL: reversal not idempotent'; end if;
  v_error:=false;
  begin
    perform public.reverse_manual_journal(a,inv_journal,current_date,'Invalid reverse');
  exception when others then v_error:=true; end;
  if not v_error then raise exception 'FAIL: source document journal was reversed directly'; end if;

  -- Reports include all postings and balance.
  select coalesce(sum(total_debits),0),coalesce(sum(total_credits),0)
    into t_debit,t_credit from public.ledger_trial_balance(a,current_date);
  if t_debit<>t_credit then raise exception 'FAIL: trial balance does not balance'; end if;

  -- Lock the fiscal period and ensure posting fails, then reopen.
  select id into v_locked from public.fiscal_periods where organization_id=a and current_date between start_date and end_date;
  perform public.set_fiscal_period_lock(a,v_locked,true);
  v_error:=false;
  begin
    perform public.post_journal(
      a,current_date,'Should fail','CLOSED','88888888-8888-4888-8888-888888888888',posting_lines);
  exception when others then v_error:=true; end;
  if not v_error then raise exception 'FAIL: closed accounting period allowed posting'; end if;
  perform public.set_fiscal_period_lock(a,v_locked,false);

  -- A second authenticated identity must not read or operate on A's data.
  perform set_config('request.jwt.claim.sub',user_b::text,true);
  b:=public.create_organization('QA Company B');
  if exists(select 1 from public.contacts where organization_id=a)
    then raise exception 'FAIL: cross-tenant contact leak'; end if;
  if exists(select 1 from public.journal_entries where organization_id=a)
    then raise exception 'FAIL: cross-tenant journal leak'; end if;
  v_error:=false;
  begin
    perform public.post_financial_document(a,inv);
  exception when others then v_error:=true; end;
  if not v_error then raise exception 'FAIL: unauthorized posting allowed'; end if;
  raise notice 'MILESTONE 2 QA ASSERTIONS PASSED (changes rollback below)';
end $test$;
reset role;
rollback;
