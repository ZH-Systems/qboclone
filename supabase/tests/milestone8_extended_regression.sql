-- Extended source financial migration with independently approved credits
-- and standalone journal, all inside a rollback-only test transaction.
begin;
insert into auth.users(id,email,email_confirmed_at,role,aud,created_at,updated_at)
values('88888888-8888-4888-8888-888888888891','m8-extended@example.invalid',now(),'authenticated','authenticated',now(),now());
set local role authenticated;
do $qa$
declare v_org uuid;v_batch uuid;v_doc uuid;v_credit uuid;v_credit_target uuid;
v_result jsonb;v_journal uuid;v_outstanding numeric;v_total numeric;
begin
 perform set_config('request.jwt.claim.sub','88888888-8888-4888-8888-888888888891',true);
 v_org:=public.create_organization('M8 Extended QBO Financial Conversion');
 v_batch:=public.create_migration_batch(v_org,'quickbooks_online','test-realm',current_date);
 perform public.stage_migration_records(v_org,v_batch,'account',jsonb_build_array(
  jsonb_build_object('source_id','a-bank','code','1000','name','Source Bank','type','asset'),
  jsonb_build_object('source_id','a-sales','code','4000','name','Source Revenue','type','revenue')));
 perform public.stage_migration_records(v_org,v_batch,'customer',jsonb_build_array(
  jsonb_build_object('source_id','cust','name','Extended Customer')));
 perform public.stage_migration_records(v_org,v_batch,'invoice',jsonb_build_array(
  jsonb_build_object('source_id','inv-1','contact_source_id','cust',
   'issue_date',current_date,'due_date',current_date+14,'total',100,
   'lines',jsonb_build_array(jsonb_build_object('description','Consulting',
    'quantity',1,'unit_price',100,'tax_rate_bps',0,'account_source_id','a-sales')))));
 perform public.stage_migration_records(v_org,v_batch,'credit_note',jsonb_build_array(
  jsonb_build_object('source_id','credit-1','contact_source_id','cust',
   'issue_date',current_date,'due_date',current_date,'total',20,
   'lines',jsonb_build_array(jsonb_build_object('description','Service credit',
   'quantity',1,'unit_price',20,'tax_rate_bps',0,'account_source_id','a-sales')))));
 perform public.stage_migration_records(v_org,v_batch,'journal',jsonb_build_array(
  jsonb_build_object('source_id','standalone-1','date',current_date,
   'lines',jsonb_build_array(
    jsonb_build_object('account_source_id','a-bank','debit',5,'credit',0),
    jsonb_build_object('account_source_id','a-sales','debit',0,'credit',5)),
   'post_as_standalone',false)));
 perform public.approve_migration_batch(v_org,v_batch);
 v_result:=public.apply_reviewed_migration(v_org,v_batch);
 if (v_result->>'imported_this_batch')::integer<>4 then
  raise exception 'Expected two chart accounts, customer and draft invoice';end if;
 perform public.post_approved_migration_financials(v_org,v_batch);
 select target_id into v_doc from public.migration_records where
  organization_id=v_org and batch_id=v_batch and record_kind='invoice';
 perform public.assign_migration_credit_source(v_org,v_batch,'credit-1','inv-1');
 perform public.approve_migration_standalone_journal(v_org,v_batch,'standalone-1');
 v_result:=public.apply_reviewed_migration_credits_and_journals(v_org,v_batch);
 if (v_result->>'posted')::integer<>2 then raise exception 'Credit and journal not converted';end if;
 select target_id into v_credit_target from public.migration_records where
  organization_id=v_org and batch_id=v_batch and record_kind='credit_note';
 if not exists(select 1 from public.financial_documents where id=v_credit_target and status='posted')
 then raise exception 'Imported credit note did not post';end if;
 if public.document_outstanding(v_org,v_doc)<>80 then
  raise exception 'Applied source credit did not reduce AR';end if;
 if not exists(select 1 from public.migration_records where
  organization_id=v_org and batch_id=v_batch and source_id='standalone-1'
  and financial_posted) then raise exception 'Reviewed standalone journal not posted';end if;
 select coalesce(sum(total_debits-total_credits),0) into v_total from public.ledger_trial_balance(v_org,current_date);
 if v_total<>0 then raise exception 'Extended imported ledger is unbalanced';end if;
 raise notice 'MILESTONE 8 EXTENDED QBO FINANCIAL REGRESSION PASSED';
end $qa$;
rollback;
