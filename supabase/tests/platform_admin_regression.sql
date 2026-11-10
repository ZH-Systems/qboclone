-- Regression for platform provisioning. Run after the ordered migration chain in
-- a disposable database with Supabase-compatible auth fixtures.
begin;
insert into auth.users(id,email,email_confirmed_at,role,aud,created_at,updated_at)
values
('44444444-4444-4444-8444-444444444461','platform-operator@example.invalid',now(),'authenticated','authenticated',now(),now()),
('44444444-4444-4444-8444-444444444462','provisioned-owner@example.invalid',now(),'authenticated','authenticated',now(),now()),
('44444444-4444-4444-8444-444444444463','outsider-platform@example.invalid',now(),'authenticated','authenticated',now(),now());

insert into private.platform_superadmins(user_id)
values('44444444-4444-4444-8444-444444444461');

do $test$
begin
 if has_function_privilege('authenticated','public.platform_provision_organization(uuid,text,text)','EXECUTE')
 then raise exception 'Authenticated can execute platform provisioning'; end if;
 if has_function_privilege('anon','public.platform_list_organizations(uuid)','EXECUTE')
 then raise exception 'Anonymous can list platform organizations'; end if;
 if has_table_privilege('authenticated','private.platform_superadmins','SELECT')
 then raise exception 'Platform superadmin allowlist is client-readable'; end if;
end $test$;

set local role service_role;
do $test$
declare v_org uuid;v_failed boolean;
begin
 if not public.platform_admin_status('44444444-4444-4444-8444-444444444461')
 then raise exception 'Granted superadmin not recognized'; end if;
 if public.platform_admin_status('44444444-4444-4444-8444-444444444463')
 then raise exception 'Ordinary user obtained platform privilege'; end if;

 v_failed:=false;
 begin
  perform public.platform_provision_organization(
   '44444444-4444-4444-8444-444444444463','Unauthorized Org','provisioned-owner@example.invalid');
 exception when others then v_failed:=true;end;
 if not v_failed then raise exception 'Ordinary user provisioned organization';end if;

 v_org:=public.platform_provision_organization(
 '44444444-4444-4444-8444-444444444461','QA Platform Org','provisioned-owner@example.invalid');
 if not exists (select 1 from public.organization_members
 where organization_id=v_org and user_id='44444444-4444-4444-8444-444444444462'
 and role='owner') then raise exception 'Owner was not assigned';end if;
 if exists (select 1 from public.organization_members
 where organization_id=v_org and user_id='44444444-4444-4444-8444-444444444461')
 then raise exception 'Superadmin unexpectedly gained tenant membership';end if;
 if (select count(*) from public.accounts where organization_id=v_org)<>8
 then raise exception 'Standard chart was not initialized';end if;
 if (select count(*) from public.fiscal_periods where organization_id=v_org)<>1
 then raise exception 'Fiscal year was not initialized';end if;
 if not exists(select 1 from private.platform_admin_events
  where organization_id=v_org and actor_id='44444444-4444-4444-8444-444444444461')
 then raise exception 'Platform provisioning audit missing';end if;
 if not exists(select 1 from public.platform_list_organizations(
  '44444444-4444-4444-8444-444444444461') where id=v_org)
 then raise exception 'Provisioned organization not listed';end if;
 v_failed:=false;
 begin
 perform public.platform_provision_organization(
 '44444444-4444-4444-8444-444444444461','No verified owner','missing-account@example.invalid');
 exception when others then v_failed:=true;end;
 if not v_failed then raise exception 'Missing owner was accepted';end if;
end $test$;
reset role;
rollback;
