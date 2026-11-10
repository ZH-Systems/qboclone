-- Milestone 7 regression: recurring drafts, contact CSV review, receipt metadata,
-- delivery logs and safe read-only bank matching. Disposable database only.
begin;
insert into auth.users(id,email,email_confirmed_at,role,aud,created_at,updated_at) values
('77777777-7777-4777-8777-777777777771','m7owner@example.invalid',now(),'authenticated','authenticated',now(),now()),
('77777777-7777-4777-8777-777777777772','m7outsider@example.invalid',now(),'authenticated','authenticated',now(),now());
set local role authenticated;
do $qa$
declare v_org uuid;v_customer uuid;v_invoice uuid;v_rule uuid;v_bank uuid;v_statement uuid;
 v_payment uuid;v_payment_journal uuid;v_rows jsonb;v_result jsonb;v_receipt uuid;v_delivery uuid;v_import jsonb;
 v_count integer;v_failed boolean;
begin
 perform set_config('request.jwt.claim.sub','77777777-7777-4777-8777-777777777771',true);
 v_org:=public.create_organization('Milestone 7 Integration QA');
 perform set_config('qa.m7_org',v_org::text,false);
 v_customer:=public.create_contact(v_org,'customer','Subscription Customer','buyer@example.invalid');
 v_invoice:=public.create_financial_document(v_org,v_customer,'invoice',current_date,current_date+14,
  'Monthly service',null,jsonb_build_array(jsonb_build_object(
  'description','Retainer','quantity',1,'unit_price',75,'tax_rate_bps',0)));
  v_rule:=public.create_recurring_document_rule(v_org,v_invoice,'monthly',current_date,14);
 perform set_config('qa.m7_rule',v_rule::text,false);
 select id into v_bank from public.accounts where organization_id=v_org and code='1000';
 perform public.post_financial_document(v_org,v_invoice);
 v_payment:=public.record_document_payment(v_org,v_invoice,75,current_date,'QA receipt',
  '77770000-0000-4000-8000-000000000001');
 select journal_entry_id into v_payment_journal from public.document_payments where id=v_payment;
 v_statement:=public.create_bank_statement(v_org,v_bank,current_date,current_date,0,75);
 perform public.import_bank_statement_rows(v_org,v_statement,jsonb_build_array(
  jsonb_build_object('line_number',1,'date',current_date,'description','QA deposit',
  'amount',75,'reference','QA-1')));
 if not exists(select 1 from public.suggest_bank_transaction_matches(v_org,v_statement,50)
   where journal_entry_id=v_payment_journal and amount=75)
 then raise exception 'Read-only matching suggestion missing';end if;
 if exists(select 1 from public.bank_transactions where organization_id=v_org
   and statement_id=v_statement and matched_journal_entry_id is not null)
 then raise exception 'Suggestion mutated bank transaction';end if;
 v_import:=public.import_contact_review_rows(v_org,'quickbooks_csv','customers','contacts.csv',
  jsonb_build_array(jsonb_build_object('name','Added Customer','email','added@example.invalid'),
   jsonb_build_object('name','Added Customer','email','added@example.invalid')));
 if (v_import->>'imported')::int<>1 then raise exception 'CSV deduplication failed';end if;
 v_receipt:=gen_random_uuid();
 perform public.register_receipt_document(v_org,v_receipt,
  'organizations/'||v_org||'/'||v_receipt,'test.png','image/png',repeat('a',64),100);
 perform public.link_receipt_document(v_org,v_receipt,v_invoice);
 if not exists(select 1 from public.receipt_document_links where organization_id=v_org and receipt_id=v_receipt)
 then raise exception 'Receipt link missing';end if;
 v_delivery:=public.record_document_delivery(v_org,v_invoice,'buyer@example.invalid',
  'invoice','sent','mock-email-id');
 if not exists(select 1 from public.document_deliveries where id=v_delivery)
 then raise exception 'Delivery log missing';end if;
 v_failed:=false;
 begin perform public.run_due_recurring_documents(current_date,10);
 exception when others then v_failed:=true;end;
 if not v_failed then raise exception 'Authenticated caller ran service-only scheduler';end if;
 perform set_config('request.jwt.claim.sub','77777777-7777-4777-8777-777777777772',true);
 if exists(select 1 from public.recurring_document_rules where organization_id=v_org)
 then raise exception 'Cross-tenant schedule leak';end if;
 v_failed:=false;
 begin perform public.create_recurring_document_rule(v_org,v_invoice,'weekly',current_date,14);
 exception when others then v_failed:=true;end;
 if not v_failed then raise exception 'Cross-tenant schedule creation';end if;
end $qa$;
reset role;
set local role service_role;
do $qa$
declare v_org uuid:=current_setting('qa.m7_org')::uuid;v_rule uuid:=current_setting('qa.m7_rule')::uuid;
 v_result jsonb;v_doc uuid;v_count integer;
begin
 v_result:=public.run_due_recurring_documents(current_date,10);
 if (v_result->>'generated')::int<>1 then raise exception 'Recurring scheduler did not generate one draft';end if;
 select document_id into v_doc from public.recurring_document_runs
  where organization_id=v_org and rule_id=v_rule and occurrence_date=current_date;
 if not exists(select 1 from public.financial_documents where id=v_doc and status='draft' and total=75)
 then raise exception 'Generated recurring document totals/status invalid';end if;
 if not exists(select 1 from public.financial_document_lines where document_id=v_doc and amount=75)
 then raise exception 'Generated recurring lines missing';end if;
 v_result:=public.run_due_recurring_documents(current_date,10);
 if (v_result->>'generated')::int<>0 then raise exception 'Duplicate occurrence generated';end if;
 raise notice 'MILESTONE 7 REGRESSION PASS';
end $qa$;
reset role;
do $qa$
begin
 if private.recurring_next_month('2026-01-31',31)<>'2026-02-28'::date or
  private.recurring_next_month('2026-02-28',31)<>'2026-03-31'::date or
  private.recurring_next_month('2028-01-31',31)<>'2028-02-29'::date then
  raise exception 'End-of-month recurring dates are not anchored';end if;
end $qa$;
rollback;
