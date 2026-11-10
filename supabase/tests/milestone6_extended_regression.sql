-- Extended Milestone 6 test: opening balances, customer deposits and write-offs.
-- All data remains inside the test transaction.
begin;
insert into auth.users(id,email,email_confirmed_at,role,aud,created_at,updated_at) values
 ('66666666-6666-4666-8666-666666666671','m6extended@example.invalid',now(),'authenticated','authenticated',now(),now()),
 ('66666666-6666-4666-8666-666666666672','m6outsider2@example.invalid',now(),'authenticated','authenticated',now(),now());
set local role authenticated;
do $test$
declare
 v_owner uuid;v_org uuid;v_bank uuid;v_ap uuid;v_opening uuid;v_balance numeric;v_failed boolean;
 v_org2 uuid;v_customer uuid;v_invoice uuid;v_deposit uuid;v_alloc uuid;v_refund uuid;v_writeoff uuid;
 v_amount numeric;v_journal uuid;v_payment uuid;v_date date:=current_date;
 v_scale_org uuid;v_scale_period uuid;v_scale_bank uuid;v_scale_account uuid;
 v_scale_close jsonb;v_i integer;
begin
 perform set_config('request.jwt.claim.sub','66666666-6666-4666-8666-666666666671',true);
 v_owner:=auth.uid();
 v_org:=public.create_organization('Opening Balance QA Business');
 select id into v_bank from public.accounts where organization_id=v_org and code='1000';
 select id into v_ap from public.accounts where organization_id=v_org and code='2000';
 v_opening:=public.import_opening_balances(v_org,date_trunc('year',current_date)::date,
   jsonb_build_array(
    jsonb_build_object('account_id',v_bank,'debit',100,'credit',0),
    jsonb_build_object('account_id',v_ap,'debit',0,'credit',40)));
 select coalesce(sum(l.credit-l.debit),0) into v_balance
 from public.journal_lines l join public.accounts a on a.id=l.account_id and a.organization_id=l.organization_id
 where l.organization_id=v_org and l.journal_entry_id=v_opening and a.code='3000';
 if v_balance<>60 then raise exception 'Opening equity offset must be 60';end if;
 v_failed:=false;
 begin
 perform public.import_opening_balances(v_org,date_trunc('year',current_date)::date,
   jsonb_build_array(jsonb_build_object('account_id',v_bank,'debit',1,'credit',0)));
 exception when others then v_failed:=true;end;
 if not v_failed then raise exception 'Duplicate opening balance import was accepted';end if;

 v_org2:=public.create_organization('Deposits and Writeoffs QA Business');
 v_customer:=public.create_contact(v_org2,'customer','Depositor Example',null);
 v_invoice:=public.create_financial_document(v_org2,v_customer,'invoice',v_date,v_date,
  'Deposit application test',null,jsonb_build_array(
   jsonb_build_object('description','Sale','quantity',1,'unit_price',100,'tax_rate_bps',0)));
 perform public.post_financial_document(v_org2,v_invoice);
 v_deposit:=public.receive_customer_deposit(v_org2,v_customer,v_date,70,'Prepayment',
   '66667777-7777-4777-8777-777777777777');
 if public.customer_deposit_available(v_org2,v_deposit)<>70 then
  raise exception 'Deposit receipt did not create available liability';end if;
 v_alloc:=public.apply_customer_deposit(v_org2,v_deposit,v_invoice,50,v_date,
   '66668888-8888-4888-8888-888888888888');
 if public.customer_deposit_available(v_org2,v_deposit)<>20 or
  public.document_outstanding(v_org2,v_invoice)<>50 then
  raise exception 'Deposit allocation did not decrease receivable and liability';end if;
 if v_alloc<>public.apply_customer_deposit(v_org2,v_deposit,v_invoice,50,v_date,
   '66668888-8888-4888-8888-888888888888') then
   raise exception 'Deposit allocation must be idempotent';end if;
 v_refund:=public.refund_customer_deposit(v_org2,v_deposit,20,v_date,
   'Return unused deposit','66669999-9999-4999-8999-999999999999');
 if public.customer_deposit_available(v_org2,v_deposit)<>0 then
  raise exception 'Remaining customer deposit should be zero';end if;
 v_failed:=false;
 begin perform public.apply_customer_deposit(v_org2,v_deposit,v_invoice,1,v_date,
   '66660000-0000-4000-8000-000000000006');
 exception when others then v_failed:=true;end;
 if not v_failed then raise exception 'Over-allocation was allowed';end if;

 v_writeoff:=public.writeoff_unpaid_invoice(v_org2,v_invoice,20,v_date,
   'Uncollectible customer portion','66660111-1111-4111-8111-111111111116');
 if public.document_outstanding(v_org2,v_invoice)<>30 then
  raise exception 'Bad debt writeoff did not reduce receivable';end if;
 if not exists(select 1 from public.aged_open_documents(v_org2,v_date,'invoice')
  where document_id=v_invoice and outstanding=30) then
  raise exception 'Historical invoice aging ignored writeoff or deposits';end if;
 v_payment:=public.record_document_payment(v_org2,v_invoice,30,v_date,'Final payment',
   '66660222-2222-4222-8222-222222222226');
 if public.document_outstanding(v_org2,v_invoice)<>0 then
  raise exception 'Payments, deposit and bad debt should settle invoice';end if;
 v_failed:=false;
 begin perform public.reverse_manual_journal(v_org2,
  (select journal_entry_id from public.document_writeoffs where id=v_writeoff),
  v_date,'Attempt to bypass source controls');
 exception when others then v_failed:=true;end;
 if not v_failed then raise exception 'Manual reversal allowed writeoff journal';end if;
 select coalesce(sum(total_debits-total_credits),0) into v_balance
 from public.ledger_trial_balance(v_org2,v_date);
 if v_balance<>0 then raise exception 'Deposits and writeoffs caused trial imbalance';end if;
 -- A financial year with >100 income accounts must close as a system journal.
 v_scale_org:=public.create_organization('Large Chart of Accounts QA');
 v_scale_period:=public.create_fiscal_period(v_scale_org,'2025-01-01','2025-12-31');
 select id into v_scale_bank from public.accounts
  where organization_id=v_scale_org and code='1000';
 for v_i in 1..110 loop
  v_scale_account:=public.create_account(v_scale_org,'6'||lpad(v_i::text,4,'0'),
   'Revenue Stream '||v_i,'revenue');
  perform public.post_journal(v_scale_org,'2025-12-31',
   'Revenue stream posting '||v_i,'SCALE',gen_random_uuid(),
   jsonb_build_array(
    jsonb_build_object('account_id',v_scale_bank,'debit',1,'credit',0),
    jsonb_build_object('account_id',v_scale_account,'debit',0,'credit',1)));
 end loop;
 v_scale_close:=public.close_financial_year(v_scale_org,v_scale_period);
 if (v_scale_close->>'net_income')::numeric<>110 then
  raise exception 'Large year-end closing failed to consolidate 110 revenue accounts';end if;
 select count(*) into v_amount from public.journal_lines
  where organization_id=v_scale_org and
  journal_entry_id=(v_scale_close->>'journal_id')::uuid;
 if v_amount<>111 then raise exception 'Large year-end missing closing journal lines';end if;
  perform set_config('request.jwt.claim.sub','66666666-6666-4666-8666-666666666672',true);
 v_failed:=false;
 begin perform public.apply_customer_deposit(v_org2,v_deposit,v_invoice,1,v_date,
  '66660333-3333-4333-8333-333333333336');
 exception when others then v_failed:=true;end;
 if not v_failed then raise exception 'Tenant isolation failed on customer deposit allocation';end if;
 if exists(select 1 from public.customer_deposits where organization_id=v_org2)
 then raise exception 'Customer deposit RLS exposed another tenant';end if;
 raise notice 'MILESTONE 6 EXTENDED ACCOUNTING ASSERTIONS PASSED';
end $test$;
rollback;
