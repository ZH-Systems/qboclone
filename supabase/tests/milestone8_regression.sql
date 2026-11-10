-- Milestone 8 integration: authorized bank feed staging and reviewed QBO migration.
-- Executed in PostgreSQL CI with synthetic Supabase Auth, entirely rolled back.
begin;
insert into auth.users(id,email,email_confirmed_at,role,aud,created_at,updated_at)
values('88888888-8888-4888-8888-888888888881','m8-owner@example.invalid',now(),'authenticated','authenticated',now(),now()),
('88888888-8888-4888-8888-888888888882','m8-outsider@example.invalid',now(),'authenticated','authenticated',now(),now());
set local role authenticated;
do $test$
declare v_org uuid;v_batch uuid;v_bank uuid;v_invoice uuid;v_result jsonb;
v_checks jsonb;v_payment uuid;v_total numeric;v_failed boolean;
 v_trial uuid;v_balance uuid;v_profit uuid;v_ar uuid;v_ap uuid;
begin
 perform set_config('request.jwt.claim.sub','88888888-8888-4888-8888-888888888881',true);
 v_org:=public.create_organization('M8 Migration Acceptance');
 perform set_config('qa.m8_org',v_org::text,false);
 v_batch:=public.create_migration_batch(v_org,'quickbooks_online','sandbox-123',current_date);
 perform set_config('qa.m8_batch',v_batch::text,false);
 perform public.stage_migration_records(v_org,v_batch,'account',jsonb_build_array(
  jsonb_build_object('source_id','qbo-revenue','code','4000','name','Revenue','type','revenue')));
 perform public.stage_migration_records(v_org,v_batch,'customer',jsonb_build_array(
  jsonb_build_object('source_id','qbo-customer','name','QBO Example Client','email','test@example.invalid')));
 perform public.stage_migration_records(v_org,v_batch,'vendor',jsonb_build_array(
  jsonb_build_object('source_id','qbo-vendor','name','QBO Example Vendor','email','vendor@example.invalid')));
 perform public.stage_migration_records(v_org,v_batch,'invoice',jsonb_build_array(
  jsonb_build_object('source_id','invoice-42','contact_source_id','qbo-customer',
   'issue_date',current_date,'due_date',current_date+14,'total',100,'memo','Source invoice',
   'lines',jsonb_build_array(jsonb_build_object('description','Consulting',
    'quantity',1,'unit_price',100,'tax_rate_bps',0,'account_source_id','qbo-revenue')))));
 perform public.stage_migration_records(v_org,v_batch,'payment',jsonb_build_array(
  jsonb_build_object('source_id','payment-99','payment_date',current_date,
   'allocations',jsonb_build_array(jsonb_build_object(
    'source_document_id','invoice-42','amount',25)))));
 perform public.stage_migration_records(v_org,v_batch,'journal',jsonb_build_array(
  jsonb_build_object('source_id','qbo-journal-5','date',current_date,
   'raw','{"Id":"5","Line":[]}'::jsonb,
   'post_as_standalone',false,'lines','[]'::jsonb)));
 perform public.stage_migration_records(v_org,v_batch,'attachment',jsonb_build_array(
  jsonb_build_object('source_id','qbo-attachment-13','raw','{"Id":"13"}'::jsonb)));
 v_checks:=public.review_migration_batch(v_org,v_batch);
 if (v_checks->>'total_records')::int<>7 or
  (v_checks->>'unmapped_historical_journals')::int<>1
 then raise exception 'Migration review did not identify all retained source records';end if;
 perform public.approve_migration_batch(v_org,v_batch);
 v_result:=public.apply_reviewed_migration(v_org,v_batch);
 if (v_result->>'imported_this_batch')::int<>4 then raise exception 'Safe import records incorrect';end if;
 select target_id into v_invoice from public.migration_records where
  organization_id=v_org and batch_id=v_batch and record_kind='invoice';
 if not exists(select 1 from public.financial_documents where id=v_invoice and status='draft')
 then raise exception 'Migration drafts were automatically posted';end if;
 v_result:=public.post_approved_migration_financials(v_org,v_batch);
 if (v_result->>'posted_this_batch')::int<>2 then
  raise exception 'Reviewed financial cutover did not post invoice and payment';end if;
 if public.document_outstanding(v_org,v_invoice)<>75 then
  raise exception 'Imported payment did not reduce receivable';end if;
 if not exists(select 1 from public.migration_records where organization_id=v_org and batch_id=v_batch
  and record_kind='journal' and status='staged')
 then raise exception 'Historical GL was incorrectly double posted';end if;
 select coalesce(sum(total_debits-total_credits),0) into v_total
  from public.ledger_trial_balance(v_org,current_date);
 if v_total<>0 then raise exception 'Imported ledger is unbalanced';end if;
 v_trial:=public.store_migration_source_report(v_org,v_batch,'TrialBalance',
  date_trunc('year',current_date)::date,current_date,
  '{"Header":{"ReportName":"TrialBalance"},"Rows":{"Row":[]}}'::jsonb,repeat('a',64));
 v_balance:=public.store_migration_source_report(v_org,v_batch,'BalanceSheet',
  date_trunc('year',current_date)::date,current_date,
  '{"Header":{"ReportName":"BalanceSheet"},"Rows":{"Row":[]}}'::jsonb,repeat('b',64));
 v_profit:=public.store_migration_source_report(v_org,v_batch,'ProfitAndLoss',
  date_trunc('year',current_date)::date,current_date,
  '{"Header":{"ReportName":"ProfitAndLoss"},"Rows":{"Row":[]}}'::jsonb,repeat('c',64));
 v_ar:=public.store_migration_source_report(v_org,v_batch,'AgedReceivables',
  date_trunc('year',current_date)::date,current_date,
  '{"Header":{"ReportName":"AgedReceivables"},"Rows":{"Row":[]}}'::jsonb,repeat('d',64));
 v_ap:=public.store_migration_source_report(v_org,v_batch,'AgedPayables',
  date_trunc('year',current_date)::date,current_date,
  '{"Header":{"ReportName":"AgedPayables"},"Rows":{"Row":[]}}'::jsonb,repeat('e',64));
 v_failed:=false;
 begin perform public.record_migration_reconciliation(v_org,v_batch,'accounts_receivable',
    75,74,v_ar,'Deliberately invalid target amount');
 exception when others then v_failed:=true;end;
 if not v_failed then raise exception 'Unverified reconciliation target amount accepted';end if;
 perform public.record_migration_reconciliation(v_org,v_batch,'trial_balance',100,100,v_trial,'Debit trial balance source checked');
 perform public.record_migration_reconciliation(v_org,v_batch,'accounts_receivable',75,75,v_ar,'Source aged receivables checked');
 perform public.record_migration_reconciliation(v_org,v_batch,'accounts_payable',0,0,v_ap,'Source payable list verified');
 perform public.record_migration_reconciliation(v_org,v_batch,'bank_cash',25,25,v_balance,'Cash and bank balances checked');
 perform public.record_migration_reconciliation(v_org,v_batch,'gst_hst',0,0,v_balance,'Tax liability balances reviewed');
 perform public.record_migration_reconciliation(v_org,v_batch,'historic_profit_loss',100,100,v_profit,'Profit and loss period reviewed');
 perform public.accept_migration_financial_cutover(v_org,v_batch);
 if not exists(select 1 from public.migration_batches where organization_id=v_org
 and id=v_batch and financial_cutover_approved_at is not null)
 then raise exception 'Financial cutover approval not persisted';end if;
  v_failed:=false;
 begin perform public.stage_migration_records(v_org,v_batch,'customer',jsonb_build_array(
  jsonb_build_object('source_id','qbo-customer','name','Wrong overwrite')));
 exception when others then v_failed:=true;end;
 if not v_failed then raise exception 'Approved source archive was mutable';end if;
 select id into v_bank from public.accounts where organization_id=v_org and code='1000';
 perform set_config('qa.m8_bank',v_bank::text,false);
 perform set_config('request.jwt.claim.sub','88888888-8888-4888-8888-888888888882',true);
 v_failed:=false;
 begin perform public.approve_migration_batch(v_org,v_batch);
 exception when others then v_failed:=true;end;
 if not v_failed then raise exception 'Other tenant approved migration';end if;
 if exists(select 1 from public.migration_records where organization_id=v_org)
 then raise exception 'Migration source records leaked to outsider';end if;
end $test$;
reset role;
set local role service_role;
do $test$
declare v_org uuid:=current_setting('qa.m8_org')::uuid;
 v_bank uuid:=current_setting('qa.m8_bank')::uuid;
 v_conn uuid;v_account uuid;v_row uuid;v_out jsonb;v_failed boolean;
begin
 insert into public.bank_feed_connections(organization_id,provider,provider_item_id,
  encrypted_token,created_by)
 values(v_org,'plaid','sandbox-item-42','ciphertext-placeholder',
  '88888888-8888-4888-8888-888888888881') returning id into v_conn;
 insert into public.bank_feed_accounts(organization_id,connection_id,provider_account_id,
 display_name,ledger_bank_account_id)
 values(v_org,v_conn,'plaid-account-1','Example Checking',v_bank) returning id into v_account;
 v_out:=public.apply_bank_feed_sync(v_conn,null,'cursor-1',
  jsonb_build_array(jsonb_build_object('transaction_id','tx-1','account_id','plaid-account-1',
  'amount',23.45,'date',current_date,'name','Deposit','pending',false)),
  '[]'::jsonb,'[]'::jsonb);
 if (v_out->>'updated')::integer<>1 then raise exception 'Initial feed sync failed';end if;
 select id into v_row from public.bank_feed_transactions
 where connection_id=v_conn and provider_transaction_id='tx-1';
 if not exists(select 1 from public.bank_feed_transactions where id=v_row
  and amount=-23.45 and not removed) then raise exception 'Plaid sign convention incorrect';end if;
 v_out:=public.apply_bank_feed_sync(v_conn,'cursor-1','cursor-2','[]'::jsonb,
 jsonb_build_array(jsonb_build_object('transaction_id','tx-1','account_id','plaid-account-1',
  'amount',25,'date',current_date,'name','Corrected','pending',false)),'[]'::jsonb);
 if (select count(*) from public.bank_feed_transactions where connection_id=v_conn)<>1
 then raise exception 'Modified feed item duplicated';end if;
 v_failed:=false;
 begin perform public.apply_bank_feed_sync(v_conn,'cursor-1','cursor-3','[]'::jsonb,'[]'::jsonb,'[]'::jsonb);
 exception when others then v_failed:=true;end;
 if not v_failed then raise exception 'Stale cursor update allowed';end if;
 v_out:=public.apply_bank_feed_sync(v_conn,'cursor-2','cursor-3','[]'::jsonb,
 '[]'::jsonb,jsonb_build_array(jsonb_build_object('transaction_id','tx-1')));
 if not (select removed from public.bank_feed_transactions where id=v_row)
 then raise exception 'Removed feed item not tombstoned';end if;
 perform public.apply_bank_feed_sync(v_conn,'cursor-3','cursor-4',
  jsonb_build_array(jsonb_build_object('transaction_id','tx-2','account_id','plaid-account-1',
  'amount',10,'date',current_date,'name','Purchase','pending',false)),
  '[]'::jsonb,'[]'::jsonb);
 select id into v_row from public.bank_feed_transactions
  where connection_id=v_conn and provider_transaction_id='tx-2';
 perform set_config('qa.m8_active_feed',v_row::text,false);
  raise notice 'MILESTONE 8 MIGRATION AND BANK FEED REGRESSION PASSED';
end $test$;
reset role;
set local role authenticated;
do $test$
declare v_org uuid:=current_setting('qa.m8_org')::uuid;
 v_bank uuid:=current_setting('qa.m8_bank')::uuid;
 v_feed uuid:=current_setting('qa.m8_active_feed')::uuid;
 v_stmt uuid;v_result jsonb;v_failed boolean:=false;
begin
 perform set_config('request.jwt.claim.sub','88888888-8888-4888-8888-888888888881',true);
 v_stmt:=public.create_bank_statement(v_org,v_bank,current_date,current_date,0,-10);
 v_result:=public.promote_bank_feed_transactions(v_org,v_stmt,array[v_feed]);
 if (v_result->>'imported')::integer<>1 then raise exception 'Feed staging bridge did not import';end if;
 if not exists(select 1 from public.bank_feed_import_links where organization_id=v_org
  and feed_transaction_id=v_feed) then raise exception 'Missing source feed provenance link';end if;
 if exists(select 1 from public.bank_transactions where statement_id=v_stmt
  and matched_journal_entry_id is not null) then raise exception 'Feed import automatically matched ledger';end if;
 begin perform public.promote_bank_feed_transactions(v_org,v_stmt,array[v_feed]);
 exception when others then v_failed:=true;end;
 if not v_failed then raise exception 'Feed transaction staging not idempotent-safe';end if;
end $test$;
reset role;
rollback;
