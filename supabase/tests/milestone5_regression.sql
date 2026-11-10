-- Rollback-safe Milestone 5 usage quotas, export authorization and audit immutability.
begin;
insert into auth.users(id,email,email_confirmed_at,role,aud,created_at,updated_at) values
 ('55555555-5555-4555-8555-555555555551','m5owner@example.invalid',now(),'authenticated','authenticated',now(),now()),
 ('55555555-5555-4555-8555-555555555552','m5other@example.invalid',now(),'authenticated','authenticated',now(),now());
set local role authenticated;
do $test$
declare
 v_org uuid;v_bank uuid;v_stmt uuid;v_rows jsonb;
 v_count integer;v_used bigint;v_failed boolean;v_audit bigint;
begin
 perform set_config('request.jwt.claim.sub','55555555-5555-4555-8555-555555555551',true);
 v_org:=public.create_organization('Milestone Five Testing');
 perform set_config('qa.m5_org',v_org::text,false);
 select id into v_bank from public.accounts where organization_id=v_org and code='1000';
 v_stmt:=public.create_bank_statement(v_org,v_bank,current_date,current_date,0,0);
 select jsonb_agg(jsonb_build_object('line_number',g,'date',current_date,
  'description','Imported row '||g,'amount',0.01,'reference','qa-'||g))
 into v_rows from generate_series(1,500) g;
 v_count:=public.import_bank_statement_rows(v_org,v_stmt,v_rows);
 if v_count<>500 then raise exception 'Expected first import to create 500 rows';end if;
 v_count:=public.import_bank_statement_rows(v_org,v_stmt,v_rows);
 if v_count<>0 then raise exception 'Duplicate import counted toward quota';end if;
 select units into v_used from public.organization_usage_monthly
  where organization_id=v_org and metric='bank_import_rows';
 if v_used<>500 then raise exception 'Incorrect import quota usage';end if;
 v_failed:=false;
 begin
  perform public.import_bank_statement_rows(v_org,v_stmt,jsonb_build_array(
   jsonb_build_object('line_number',501,'date',current_date,
    'description','Exceeded quota','amount',0.01,'reference','qa-extra')));
 exception when others then v_failed:=true;end;
 if not v_failed then raise exception 'Import quota bypassed';end if;
 if exists(select 1 from public.bank_transactions
   where organization_id=v_org and statement_id=v_stmt and line_number=501)
 then raise exception 'Failed quota import persisted bank row';end if;
 if (public.organization_usage_summary(v_org)->>'used')::integer<>500 then
  raise exception 'Quota usage summary incorrect';end if;
 perform public.record_organization_export(v_org);
 if not exists(select 1 from public.audit_events where organization_id=v_org
 and action='organization.export_requested') then raise exception 'Missing export audit';end if;
 if not exists(select 1 from public.audit_events where organization_id=v_org
 and action='bank.rows_imported') then raise exception 'Missing bank import audit';end if;
 if not exists(select 1 from public.audit_events where organization_id=v_org
 and action='ledger.account_created') then raise exception 'Missing account creation audit';end if;
 perform set_config('request.jwt.claim.sub','55555555-5555-4555-8555-555555555552',true);
 v_failed:=false;
 begin perform public.record_organization_export(v_org);
 exception when others then v_failed:=true;end;
 if not v_failed then raise exception 'Cross-tenant export audit allowed';end if;
 if exists(select 1 from public.organization_usage_monthly where organization_id=v_org)
 then raise exception 'Cross-tenant usage leak';end if;
end $test$;
reset role;
do $test$
declare v_id bigint;v_failed boolean:=false;
begin
 select id into v_id from public.audit_events
 where organization_id=current_setting('qa.m5_org')::uuid limit 1;
 begin
  update public.audit_events set action='tampered' where id=v_id;
 exception when others then v_failed:=true;end;
 if not v_failed then raise exception 'Privileged update modified immutable audit log';end if;
 v_failed:=false;
 begin delete from public.audit_events where id=v_id;
 exception when others then v_failed:=true;end;
 if not v_failed then raise exception 'Privileged delete modified immutable audit log';end if;
 raise notice 'MILESTONE 5 QA ASSERTIONS PASSED';
end $test$;
rollback;
