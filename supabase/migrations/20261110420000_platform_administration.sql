-- Platform provisioning, deliberately separate from organization-scoped roles.
-- No browser role can read the superadmin allowlist or execute provisioning RPCs.
create table if not exists private.platform_superadmins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  granted_at timestamptz not null default now()
);
revoke all on private.platform_superadmins from public,anon,authenticated;

create table if not exists private.platform_admin_events (
  id bigint generated always as identity primary key,
  actor_id uuid not null references auth.users(id),
  action text not null,
  organization_id uuid references public.organizations(id),
  target_user_id uuid references auth.users(id),
  occurred_at timestamptz not null default now()
);
revoke all on private.platform_admin_events from public,anon,authenticated;

create or replace function public.platform_admin_status(p_actor uuid)
returns boolean language sql stable security definer set search_path=''
as $$
  select exists (
    select 1 from private.platform_superadmins a
    join auth.users u on u.id=a.user_id
    where a.user_id=p_actor and u.email_confirmed_at is not null
  )
$$;
revoke all on function public.platform_admin_status(uuid) from public,anon,authenticated;
grant execute on function public.platform_admin_status(uuid) to service_role;

create or replace function public.platform_provision_organization(
 p_actor uuid,p_name text,p_owner_email text
) returns uuid language plpgsql security definer set search_path=''
as $$
declare
 v_id uuid;
 v_owner uuid;
 v_year integer := extract(year from current_date);
begin
 if not public.platform_admin_status(p_actor) then
   raise exception 'Platform administrator authorization required';
 end if;
 if p_name is null or char_length(btrim(p_name)) not between 2 and 150 then
   raise exception 'Business name must contain 2 to 150 characters';
 end if;
 if p_owner_email is null or length(btrim(p_owner_email)) > 320 or
    btrim(p_owner_email) !~* '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' then
   raise exception 'Valid owner email required';
 end if;
 select id into v_owner from auth.users
 where lower(email)=lower(btrim(p_owner_email))
   and email_confirmed_at is not null;
 if v_owner is null then
   raise exception 'Owner must already have a verified Ledger North account';
 end if;
 insert into public.organizations(name) values(btrim(p_name)) returning id into v_id;
 insert into public.organization_members(organization_id,user_id,role)
 values(v_id,v_owner,'owner');
 insert into public.fiscal_periods(organization_id,start_date,end_date)
 values(v_id,make_date(v_year,1,1),make_date(v_year,12,31));
 insert into public.accounts(organization_id,code,name,account_type,normal_balance) values
 (v_id,'1000','Operating Bank','asset','debit'),
 (v_id,'1100','Accounts Receivable','asset','debit'),
 (v_id,'1200','Undeposited Funds','asset','debit'),
 (v_id,'2000','Accounts Payable','liability','credit'),
 (v_id,'2100','GST/HST Payable','liability','credit'),
 (v_id,'3000','Owner Equity','equity','credit'),
 (v_id,'4000','Sales Revenue','revenue','credit'),
 (v_id,'5000','Operating Expenses','expense','debit');
 insert into private.platform_admin_events(actor_id,action,organization_id,target_user_id)
 values(p_actor,'organization.provisioned',v_id,v_owner);
 return v_id;
end $$;
revoke all on function public.platform_provision_organization(uuid,text,text)
 from public,anon,authenticated;
grant execute on function public.platform_provision_organization(uuid,text,text)
 to service_role;

create or replace function public.platform_list_organizations(p_actor uuid)
returns table(
 id uuid,name text,created_at timestamptz,owner_email text,member_count bigint
) language plpgsql stable security definer set search_path=''
as $$
begin
 if not public.platform_admin_status(p_actor) then
   raise exception 'Platform administrator authorization required';
 end if;
 return query select o.id,o.name,o.created_at,
  (select u.email::text from public.organization_members m
   join auth.users u on u.id=m.user_id
   where m.organization_id=o.id and m.role='owner'
   order by m.created_at limit 1),
  (select count(*) from public.organization_members m where m.organization_id=o.id)
 from public.organizations o order by o.created_at desc,o.id limit 500;
end $$;
revoke all on function public.platform_list_organizations(uuid)
 from public,anon,authenticated;
grant execute on function public.platform_list_organizations(uuid) to service_role;
