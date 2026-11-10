-- Milestone 10: atomic Link and Intuit authorization replay and cross-tenant tests.
begin;
insert into auth.users(id,email,email_confirmed_at,role,aud,created_at,updated_at)
values('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1','m10-owner@example.invalid',now(),'authenticated','authenticated',now(),now()),
('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2','m10-outsider@example.invalid',now(),'authenticated','authenticated',now(),now());
set local role authenticated;
do $qa$
declare v_org uuid;v_session uuid:=gen_random_uuid();v_state text:=repeat('a',64);
begin
 perform set_config('request.jwt.claim.sub','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1',true);
 v_org:=public.create_organization('M10 Provider Claim Security QA');
 perform set_config('qa.m10_org',v_org::text,false);
 perform set_config('qa.m10_session',v_session::text,false);
end $qa$;
reset role;
set local role service_role;
do $qa$
declare v_org uuid:=current_setting('qa.m10_org')::uuid;
 v_session uuid:=current_setting('qa.m10_session')::uuid;
 v_claim boolean;v_claims integer;v_connection uuid;v_update uuid:=gen_random_uuid();
begin
 insert into public.bank_feed_link_sessions(id,organization_id,user_id,expires_at)
 values(v_session,v_org,'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1'::uuid,now()+interval '10 minutes');
 insert into public.qbo_oauth_states(state_hash,organization_id,user_id,expires_at)
 values(repeat('a',64),v_org,'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1'::uuid,
 now()+interval '10 minutes');
  v_claim:=public.claim_bank_link_session(v_session,v_org,
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2'::uuid);
 if v_claim then raise exception 'Wrong user was allowed to claim bank link';end if;
 v_claim:=public.claim_bank_link_session(v_session,gen_random_uuid(),
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1'::uuid);
 if v_claim then raise exception 'Wrong tenant was allowed to claim bank link';end if;
 v_claim:=public.claim_bank_link_session(v_session,v_org,
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1'::uuid);
 if not v_claim then raise exception 'Valid bank claim was rejected';end if;
 v_claim:=public.claim_bank_link_session(v_session,v_org,
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1'::uuid);
 if v_claim then raise exception 'Plaid Link claim replay succeeded';end if;
 select count(*) into v_claims from public.claim_qbo_oauth_state(repeat('a',64))
 where organization_id=v_org and user_id='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1'::uuid;
 if v_claims<>1 then raise exception 'Valid OAuth state claim rejected';end if;
 select count(*) into v_claims from public.claim_qbo_oauth_state(repeat('a',64));
 if v_claims<>0 then raise exception 'OAuth state replay was accepted';end if;
 select count(*) into v_claims from public.claim_qbo_oauth_state(repeat('b',64));
 if v_claims<>0 then raise exception 'Unknown OAuth state was accepted';end if;
 insert into public.bank_feed_connections(organization_id,provider,provider_item_id,encrypted_token,created_by)
 values(v_org,'plaid','m10-test-provider-item','ciphertext-test',
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1'::uuid) returning id into v_connection;
 insert into public.bank_feed_update_sessions(id,organization_id,connection_id,user_id,expires_at)
 values(v_update,v_org,v_connection,'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1'::uuid,
 now()+interval '10 minutes');
 v_claim:=public.claim_bank_update_session(v_update,v_org,
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2'::uuid,v_connection);
 if v_claim then raise exception 'Wrong user consumed Plaid consent renewal';end if;
 v_claim:=public.claim_bank_update_session(v_update,v_org,
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1'::uuid,gen_random_uuid());
 if v_claim then raise exception 'Wrong bank item consumed consent renewal';end if;
 v_claim:=public.claim_bank_update_session(v_update,v_org,
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1'::uuid,v_connection);
 if not v_claim then raise exception 'Valid Plaid consent renewal claim rejected';end if;
 v_claim:=public.claim_bank_update_session(v_update,v_org,
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1'::uuid,v_connection);
 if v_claim then raise exception 'Plaid consent renewal replay succeeded';end if;
  raise notice 'MILESTONE 10 ATOMIC PROVIDER CLAIM REGRESSION PASSED';
end $qa$;
reset role;
set local role authenticated;
do $qa$
declare v_failed boolean:=false;
begin
 perform set_config('request.jwt.claim.sub','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1',true);
 begin perform public.claim_qbo_oauth_state(repeat('a',64));
 exception when insufficient_privilege then v_failed:=true;
 when undefined_function then v_failed:=true;end;
 if not v_failed then raise exception 'Authenticated client invoked internal provider claim';end if;
end $qa$;
reset role;
rollback;
