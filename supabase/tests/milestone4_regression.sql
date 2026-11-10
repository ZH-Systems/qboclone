-- Rollback-safe Milestone 4 financial SaaS/organization tests.
-- Run after all migrations in an isolated, disposable PostgreSQL database.
begin;
insert into auth.users(id,email,email_confirmed_at,role,aud,created_at,updated_at) values
 ('44444444-4444-4444-8444-444444444441','owner4@example.invalid',now(),'authenticated','authenticated',now(),now()),
 ('44444444-4444-4444-8444-444444444442','bookkeeper4@example.invalid',now(),'authenticated','authenticated',now(),now()),
 ('44444444-4444-4444-8444-444444444443','outsider4@example.invalid',now(),'authenticated','authenticated',now(),now());
update public.subscription_plans set stripe_price_id='price_qa_business' where code='business';

set local role authenticated;
do $test$
declare org uuid;v_token text;v_inv_count integer;v_failed boolean;
begin
 perform set_config('request.jwt.claim.sub','44444444-4444-4444-8444-444444444441',true);
 org:=public.create_organization('Milestone 4 SaaS QA');
 perform set_config('qa.m4_org',org::text,false);
 v_token:=public.invite_organization_member(org,'bookkeeper4@example.invalid','bookkeeper');
 perform set_config('qa.m4_invite',v_token,false);
 select count(*) into v_inv_count from public.organization_invitations
  where organization_id=org and accepted_at is null and revoked_at is null;
 if v_inv_count<>1 then raise exception 'Invite failed';end if;
 if exists(select 1 from information_schema.column_privileges where table_schema='public'
   and table_name='organization_invitations' and column_name='token_hash'
   and grantee='authenticated' and privilege_type='SELECT')
 then raise exception 'Invitation token hash exposed to authenticated';end if;
 perform set_config('request.jwt.claim.sub','44444444-4444-4444-8444-444444444442',true);
 v_failed:=false;
 begin perform public.accept_organization_invitation(v_token);
 exception when others then v_failed:=true; end;
 if not v_failed then raise exception 'Unsubscribed tenant accepted additional user';end if;
end $test$;
reset role;

-- Verified Stripe event application is an RPC reserved for service_role only.
set local role service_role;
select public.apply_stripe_subscription_event('evt_qa_m4_1',1794355000,
 current_setting('qa.m4_org')::uuid,'cus_qa_m4_1','sub_qa_m4_1',
 'price_qa_business','active',now()+interval '30 days',false,'customer.subscription.created');
reset role;

set local role authenticated;
do $test$
declare org uuid:=current_setting('qa.m4_org')::uuid;
 token text:=current_setting('qa.m4_invite');v_failed boolean;v_role text;v_features jsonb;
 v_event_count integer;
begin
 perform set_config('request.jwt.claim.sub','44444444-4444-4444-8444-444444444442',true);
 if public.accept_organization_invitation(token)<>org then raise exception 'Invite acceptance failed';end if;
 select role into v_role from public.organization_members
 where organization_id=org and user_id=auth.uid();
 if v_role<>'bookkeeper' then raise exception 'Incorrect role';end if;
 v_features:=public.organization_entitlements(org);
 if v_features->>'plan'<>'business' or (v_features->>'users')::int<>5
 then raise exception 'Incorrect entitlements';end if;
 v_failed:=false;
 begin perform public.set_organization_member_role(org,
  '44444444-4444-4444-8444-444444444441','viewer');
 exception when others then v_failed:=true;end;
 if not v_failed then raise exception 'Bookkeeper modified owner';end if;
 perform set_config('request.jwt.claim.sub','44444444-4444-4444-8444-444444444443',true);
 if exists(select 1 from public.audit_events where organization_id=org) then
   raise exception 'Cross-tenant audit leak'; end if;
 v_failed:=false;
 begin perform public.invite_organization_member(org,'intruder@example.invalid','administrator');
 exception when others then v_failed:=true;end;
 if not v_failed then raise exception 'Outsider invited member';end if;
 perform set_config('request.jwt.claim.sub','44444444-4444-4444-8444-444444444441',true);
 perform public.set_organization_member_role(org,'44444444-4444-4444-8444-444444444442','accountant');
 select role into v_role from public.organization_members where organization_id=org
  and user_id='44444444-4444-4444-8444-444444444442';
 if v_role<>'accountant' then raise exception 'Owner role change failed';end if;
 if not exists(select 1 from public.audit_events where organization_id=org and action='membership.role_changed')
 then raise exception 'Missing role change audit';end if;
 perform public.remove_organization_member(org,'44444444-4444-4444-8444-444444444442');
 if exists(select 1 from public.organization_members where organization_id=org
  and user_id='44444444-4444-4444-8444-444444444442')
 then raise exception 'Member removal failed';end if;
end $test$;
reset role;
set local role service_role;
-- Event idempotency: duplicate events return false.
do $test$
declare org uuid:=current_setting('qa.m4_org')::uuid;v_applied boolean;
begin
 select public.apply_stripe_subscription_event('evt_qa_m4_1',1794355000,org,
 'cus_qa_m4_1','sub_qa_m4_1','price_qa_business','active',
 now()+interval '30 days',false,'customer.subscription.created')
 into v_applied;
 if v_applied then raise exception 'Duplicate Stripe event applied';end if;
 select public.apply_stripe_subscription_event('evt_qa_m4_0',1794354000,org,
 'cus_qa_m4_1','sub_qa_m4_1','price_qa_business','canceled',
 now(),false,'customer.subscription.deleted') into v_applied;
 if v_applied then raise exception 'Stale Stripe event overwrote current subscription';end if;
end $test$;
reset role;
do $test$
declare v_status text;
begin
 select status into v_status from public.organization_subscriptions where organization_id=current_setting('qa.m4_org')::uuid;
 if v_status<>'active' then raise exception 'Stale Stripe event changed state';end if;
 raise notice 'MILESTONE 4 QA ASSERTIONS PASSED';
end $test$;
rollback;
