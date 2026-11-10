-- Milestone 3 PostgreSQL/Supabase regression fixtures.
-- Run ONLY in disposable development database after all migrations through 70000.
-- This test uses synthetic auth identities, a single transaction, and rolls back.
begin;
insert into auth.users(id,email,role,aud,created_at,updated_at) values
('aaa00000-0000-4000-8000-000000000003','milestone3-a@example.invalid','authenticated','authenticated',now(),now()),
('bbb00000-0000-4000-8000-000000000003','milestone3-b@example.invalid','authenticated','authenticated',now(),now());
set local role authenticated;
do $test$
declare
  org_a uuid;org_b uuid;customer uuid;vendor uuid;
  bank uuid;receivable uuid;income uuid;expense uuid;tax_sale uuid;tax_purchase uuid;
  invoice uuid;bill uuid;edit_doc uuid;payment_id uuid;payment_journal uuid;
  invoice_journal uuid;bill_journal uuid;stmt uuid;tx_id uuid;
  sum_debit numeric;sum_credit numeric;v_amount numeric;v_count integer;
  failed boolean;v_date date:=current_date;
  a uuid:='aaa00000-0000-4000-8000-000000000003';
  b uuid:='bbb00000-0000-4000-8000-000000000003';
begin
 perform set_config('request.jwt.claim.sub',a::text,true);
 org_a:=public.create_organization('Milestone 3 QA Business A');
 customer:=public.create_contact(org_a,'customer','QA Buyer',null);
 vendor:=public.create_contact(org_a,'vendor','QA Supplier',null);
 select id into bank from public.accounts where organization_id=org_a and code='1000';
 select id into receivable from public.accounts where organization_id=org_a and code='1100';
 income:=public.create_account(org_a,'4015','Service Income','revenue');
 expense:=public.create_account(org_a,'5015','Office Expense','expense');
 tax_sale:=public.create_tax_code_with_dates(org_a,'HSTTEST','QA HST Sale','sale','taxable',1300,0,v_date,v_date);
 tax_purchase:=public.create_tax_code_with_dates(org_a,'HSTPUR','QA HST Purchase','purchase','taxable',1300,5000,v_date,v_date);

 -- Post customer invoice: $113 gross, $100 configured revenue, $13 tax.
 invoice:=public.create_financial_document(org_a,customer,'invoice',v_date,v_date,
 'QA taxable sale',null,jsonb_build_array(jsonb_build_object(
 'description','Consulting','quantity',1,'unit_price',100,
 'tax_code_id',tax_sale,'account_id',income)));
 invoice_journal:=public.post_financial_document(org_a,invoice);
 select coalesce(sum(debit),0),coalesce(sum(credit),0) into sum_debit,sum_credit
 from public.journal_lines where organization_id=org_a and journal_entry_id=invoice_journal;
 if sum_debit<>113 or sum_credit<>113 then raise exception 'FAIL invoice balance'; end if;
 select coalesce(sum(credit-debit),0) into v_amount from public.journal_lines
 where organization_id=org_a and journal_entry_id=invoice_journal and account_id=income;
 if v_amount<>100 then raise exception 'FAIL custom revenue mapping'; end if;

 -- Supplier bill: $100 net, $13 tax, $6.50 recoverable, $6.50 nonrecoverable.
 bill:=public.create_financial_document(org_a,vendor,'bill',v_date,v_date,
 'QA taxable purchase',null,jsonb_build_array(jsonb_build_object(
 'description','Supplies','quantity',1,'unit_price',100,
 'tax_code_id',tax_purchase,'account_id',expense)));
 bill_journal:=public.post_financial_document(org_a,bill);
 select coalesce(sum(debit-credit),0) into v_amount from public.journal_lines
 where organization_id=org_a and journal_entry_id=bill_journal and account_id=expense;
 if v_amount<>106.50 then raise exception 'FAIL nonrecoverable tax not expensed'; end if;
 select coalesce(sum(debit-credit),0) into v_amount from public.journal_lines l
 join public.accounts a on a.id=l.account_id and a.organization_id=l.organization_id
 where l.organization_id=org_a and l.journal_entry_id=bill_journal and a.code='1300';
 if v_amount<>6.50 then raise exception 'FAIL recoverable tax calculation'; end if;

 -- Draft replacement and void should not create journal postings.
 edit_doc:=public.create_financial_document(org_a,customer,'invoice',v_date,v_date,
 'Replace me',null,jsonb_build_array(jsonb_build_object(
 'description','Original','quantity',1,'unit_price',10,'tax_rate_bps',0)));
 perform public.replace_financial_draft(org_a,edit_doc,jsonb_build_array(jsonb_build_object(
 'description','Replacement','quantity',1,'unit_price',20,'tax_rate_bps',0)),
 'Edited',v_date);
 select total into v_amount from public.financial_documents where id=edit_doc;
 if v_amount<>20 then raise exception 'FAIL draft edit'; end if;
 perform public.void_financial_draft(org_a,edit_doc,'QA draft void');
 failed:=false;
 begin perform public.post_financial_document(org_a,edit_doc);
 exception when others then failed:=true;end;
 if not failed then raise exception 'FAIL void document posted'; end if;

 -- Tax code effective-date trigger prevents use outside validity.
 failed:=false;
 begin
  perform public.create_financial_document(org_a,customer,'invoice',v_date-1,v_date,
  'Outdated tax',null,jsonb_build_array(jsonb_build_object(
  'description','Invalid tax date','quantity',1,'unit_price',10,
  'tax_code_id',tax_sale,'account_id',income)));
 exception when others then failed:=true;end;
 if not failed then raise exception 'FAIL tax effective date';end if;

 -- Bank matching and reconciliation are tied to existing posted journal movement.
 payment_id:=public.record_document_payment(org_a,invoice,113,v_date,'QA payment',
 'aaaa1111-1111-4111-8111-111111111111');
 select journal_entry_id into payment_journal from public.document_payments where id=payment_id;
 failed:=false;
 begin
  perform public.record_document_payment(org_a,invoice,112,v_date,'QA payment',
   'aaaa1111-1111-4111-8111-111111111111');
 exception when others then failed:=true;end;
 if not failed then raise exception 'FAIL conflicting payment idempotency replay';end if;
 perform public.post_journal(org_a,v_date,'QA reclassification','QA-CLASS',
  'aaaa3333-3333-4333-8333-333333333333',jsonb_build_array(
  jsonb_build_object('account_id',expense,'debit',5,'credit',0),
  jsonb_build_object('account_id',income,'debit',0,'credit',5)));
 failed:=false;
 begin
  perform public.post_journal(org_a,v_date,'Changed reclassification','QA-CLASS',
  'aaaa3333-3333-4333-8333-333333333333',jsonb_build_array(
  jsonb_build_object('account_id',expense,'debit',5,'credit',0),
  jsonb_build_object('account_id',income,'debit',0,'credit',5)));
 exception when others then failed:=true;end;
 if not failed then raise exception 'FAIL conflicting journal idempotency replay';end if;
 stmt:=public.create_bank_statement(org_a,bank,v_date,v_date,0,113);
 if public.import_bank_statement_rows(org_a,stmt,jsonb_build_array(
  jsonb_build_object('line_number',1,'date',v_date,'amount',113,
  'description','QA receipt','reference','QA-1')))<>1
 then raise exception 'FAIL bank import';end if;
 if public.import_bank_statement_rows(org_a,stmt,jsonb_build_array(
  jsonb_build_object('line_number',1,'date',v_date,'amount',113,
  'description','QA receipt','reference','QA-1')))<>0
 then raise exception 'FAIL bank import duplicate';end if;
 select id into tx_id from public.bank_transactions where organization_id=org_a and statement_id=stmt;
 perform public.match_bank_transaction(org_a,tx_id,payment_journal);
 perform public.reconcile_bank_statement(org_a,stmt);
 if not exists(select 1 from public.bank_statements where id=stmt and status='reconciled')
 then raise exception 'FAIL reconciliation status';end if;
 failed:=false;
 begin
  perform public.post_journal(org_a,v_date,'Backdated bank transfer','INVALID',
   'aaaa2222-2222-4222-8222-222222222222',jsonb_build_array(
    jsonb_build_object('account_id',bank,'debit',1,'credit',0),
    jsonb_build_object('account_id',income,'debit',0,'credit',1)));
 exception when others then failed:=true;end;
 if not failed then raise exception 'FAIL backdated reconciled bank posting';end if;
 failed:=false;
 begin perform public.unmatch_bank_transaction(org_a,tx_id);
 exception when others then failed:=true;end;
 if not failed then raise exception 'FAIL reconciled bank unmatch';end if;
 failed:=false;
 begin perform public.reset_open_bank_statement(org_a,stmt);
 exception when others then failed:=true;end;
 if not failed then raise exception 'FAIL reset of closed bank statement';end if;

 -- Whole-ledger trial balance after all test postings.
 select sum(total_debits),sum(total_credits) into sum_debit,sum_credit
 from public.ledger_trial_balance(org_a,v_date);
 if sum_debit<>sum_credit then raise exception 'FAIL trial balance';end if;

 -- Cross-tenant access isolation.
 perform set_config('request.jwt.claim.sub',b::text,true);
 org_b:=public.create_organization('Milestone 3 QA Business B');
 if exists(select 1 from public.bank_transactions where organization_id=org_a)
 then raise exception 'FAIL cross-tenant bank leak';end if;
 if exists(select 1 from public.tax_codes where organization_id=org_a)
 then raise exception 'FAIL cross-tenant tax code leak';end if;
 failed:=false;
 begin perform public.create_bank_statement(org_a,bank,v_date+1,v_date+2,113,113);
 exception when others then failed:=true;end;
 if not failed then raise exception 'FAIL unauthorized bank statement creation';end if;
 raise notice 'Milestone 3 database regression PASS (test transaction rolls back)';
end $test$;
reset role;
rollback;
