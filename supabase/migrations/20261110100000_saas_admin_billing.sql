-- Milestone 4: SaaS plans, subscription entitlements, tenant administration, invitations and audit events.
-- Requires all migrations through 20261110090000_strict_idempotency.sql.
-- Supabase Auth and service_role are available in deployed Supabase, the CI stub emulates both.
create table public.audit_events(
 id bigint generated always as identity primary key,
 organization_id uuid not null references public.organizations(id) on delete restrict,
 actor_user_id uuid references auth.users(id),
 action text not null check(length(action) between 3 and 100),
 entity_type text not null check(length(entity_type) between 2 and 80),
 entity_id uuid,
 details jsonb not null default '{}'::jsonb check(jsonb_typeof(details)='object'),
 occurred_at timestamptz not null default now()
);
create index audit_events_org_date_idx on public.audit_events(organization_id,occurred_at desc,id desc);
alter table public.audit_events enable row level security;
create policy audit_events_read on public.audit_events for select to authenticated
 using(exists(select 1 from public.organization_members m
   where m.organization_id=audit_events.organization_id and m.user_id=(select auth.uid())
   and m.role in ('owner','administrator','accountant')));
revoke all on public.audit_events from public,anon,authenticated;
grant select on public.audit_events to authenticated;

create function private.write_audit(p_org uuid,p_action text,p_entity_type text,p_entity_id uuid,p_details jsonb default '{}'::jsonb)
returns void language plpgsql security definer set search_path=''
as $$
begin
 insert into public.audit_events(organization_id,actor_user_id,action,entity_type,entity_id,details)
 values(p_org,auth.uid(),p_action,p_entity_type,p_entity_id,coalesce(p_details,'{}'::jsonb));
end $$;
revoke all on function private.write_audit(uuid,text,text,uuid,jsonb) from public,anon,authenticated;

create table public.organization_invitations(
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null references public.organizations(id) on delete restrict,
 invited_email text not null check(length(invited_email) between 3 and 255),
 role text not null check(role in ('administrator','accountant','bookkeeper','viewer')),
 token_hash text not null unique,
 created_by uuid not null references auth.users(id),
 created_at timestamptz not null default now(),
 expires_at timestamptz not null default(now()+interval '7 days'),
 accepted_at timestamptz,
 accepted_by uuid references auth.users(id),
 revoked_at timestamptz,
 check((accepted_at is null and accepted_by is null) or
       (accepted_at is not null and accepted_by is not null)),
 check(not(accepted_at is not null and revoked_at is not null))
);
create index organization_invitations_org_idx on public.organization_invitations(organization_id,created_at desc);
create unique index organization_invitations_one_active_email
 on public.organization_invitations(organization_id,lower(invited_email))
 where accepted_at is null and revoked_at is null;
alter table public.organization_invitations enable row level security;
create policy invitations_visible on public.organization_invitations for select to authenticated
 using(exists(select 1 from public.organization_members m where
 m.organization_id=organization_invitations.organization_id and m.user_id=(select auth.uid())
 and m.role in ('owner','administrator')));
revoke all on public.organization_invitations from public,anon,authenticated;
grant select(id,organization_id,invited_email,role,created_by,created_at,expires_at,accepted_at,accepted_by,revoked_at)
 on public.organization_invitations to authenticated;
-- Never grant SELECT on token_hash.

create function private.can_manage_members(p_org uuid)
returns boolean language sql stable security definer set search_path=''
as $$
 select exists(select 1 from public.organization_members m
 where m.organization_id=p_org and m.user_id=(select auth.uid())
 and m.role in ('owner','administrator'))
$$;
revoke all on function private.can_manage_members(uuid) from public,anon,authenticated;

create function public.invite_organization_member(p_org uuid,p_email text,p_role text)
returns text language plpgsql security definer set search_path=''
as $$
declare v_token text;v_email text;v_id uuid;v_actor_role text;
begin
 if not private.can_manage_members(p_org) then raise exception 'Not authorized to invite'; end if;
 select role into v_actor_role from public.organization_members
  where organization_id=p_org and user_id=auth.uid();
 if p_role not in ('administrator','accountant','bookkeeper','viewer') or
    (p_role='administrator' and v_actor_role<>'owner') then
    raise exception 'Not authorized to grant this role'; end if;
 v_email:=lower(trim(coalesce(p_email,'')));
 if length(v_email) not between 3 and 255 or
    v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
    raise exception 'Invalid invitation email'; end if;
 perform 1 from public.organizations where id=p_org for update;
 if exists(select 1 from public.organization_members m join auth.users u on u.id=m.user_id
    where m.organization_id=p_org and lower(u.email)=v_email)
 then raise exception 'Email already belongs to an organization member'; end if;
 update public.organization_invitations set revoked_at=now()
 where organization_id=p_org and lower(invited_email)=v_email
   and accepted_at is null and revoked_at is null;
 v_token:=encode(extensions.gen_random_bytes(32),'hex');
 insert into public.organization_invitations(organization_id,invited_email,role,token_hash,created_by)
 values(p_org,v_email,p_role,encode(extensions.digest(v_token,'sha256'),'hex'),auth.uid())
 returning id into v_id;
 perform private.write_audit(p_org,'membership.invited','invitation',v_id,
    jsonb_build_object('email',v_email,'role',p_role));
 return v_token;
end $$;

create function public.accept_organization_invitation(p_token text)
returns uuid language plpgsql security definer set search_path=''
as $$
declare v_inv public.organization_invitations%rowtype;v_user_email text;v_confirmed timestamptz;
begin
 if auth.uid() is null or p_token is null or p_token !~ '^[a-f0-9]{64}$' then
   raise exception 'Authentication and valid token required'; end if;
 select lower(email),email_confirmed_at into v_user_email,v_confirmed
 from auth.users where id=auth.uid();
 if v_confirmed is null then raise exception 'Verify email before accepting invitations'; end if;
 select * into v_inv from public.organization_invitations
 where token_hash=encode(extensions.digest(p_token,'sha256'),'hex') for update;
 if not found or v_inv.revoked_at is not null or v_inv.accepted_at is not null
 or v_inv.expires_at<=now() or v_inv.invited_email<>v_user_email
 then raise exception 'Invitation invalid, expired, or issued to a different email'; end if;
 perform 1 from public.organizations where id=v_inv.organization_id for update;
 insert into public.organization_members(organization_id,user_id,role)
 values(v_inv.organization_id,auth.uid(),v_inv.role)
 on conflict(organization_id,user_id) do nothing;
 update public.organization_invitations set accepted_at=now(),accepted_by=auth.uid()
 where id=v_inv.id;
 perform private.write_audit(v_inv.organization_id,'membership.accepted','invitation',v_inv.id,
   jsonb_build_object('role',v_inv.role));
 return v_inv.organization_id;
end $$;

create function public.revoke_organization_invitation(p_org uuid,p_invitation uuid)
returns void language plpgsql security definer set search_path=''
as $$
begin
 if not private.can_manage_members(p_org) then raise exception 'Not authorized'; end if;
 perform 1 from public.organizations where id=p_org for update;
 update public.organization_invitations set revoked_at=now()
 where organization_id=p_org and id=p_invitation and accepted_at is null and revoked_at is null;
 if not found then raise exception 'Active invitation not found'; end if;
 perform private.write_audit(p_org,'membership.invitation_revoked','invitation',p_invitation);
end $$;

create function public.set_organization_member_role(p_org uuid,p_user uuid,p_role text)
returns void language plpgsql security definer set search_path=''
as $$
declare v_actor text;v_old text;
begin
 select role into v_actor from public.organization_members
 where organization_id=p_org and user_id=auth.uid();
 if v_actor not in ('owner','administrator') or p_role not in ('administrator','accountant','bookkeeper','viewer')
 then raise exception 'Not authorized'; end if;
 perform 1 from public.organizations where id=p_org for update;
 select role into v_old from public.organization_members
 where organization_id=p_org and user_id=p_user for update;
 if v_old is null or v_old='owner' then raise exception 'Owner roles cannot be reassigned'; end if;
 if (v_actor<>'owner') and (v_old='administrator' or p_role='administrator') then
   raise exception 'Only owners can administer administrators'; end if;
 update public.organization_members set role=p_role
 where organization_id=p_org and user_id=p_user;
 perform private.write_audit(p_org,'membership.role_changed','member',p_user,
  jsonb_build_object('from',v_old,'to',p_role));
end $$;

create function public.remove_organization_member(p_org uuid,p_user uuid)
returns void language plpgsql security definer set search_path=''
as $$
declare v_actor text;v_old text;
begin
 select role into v_actor from public.organization_members
 where organization_id=p_org and user_id=auth.uid();
 if v_actor not in ('owner','administrator') then raise exception 'Not authorized'; end if;
 perform 1 from public.organizations where id=p_org for update;
 select role into v_old from public.organization_members
 where organization_id=p_org and user_id=p_user for update;
 if v_old is null or v_old='owner' then raise exception 'Owner cannot be removed'; end if;
 if v_old='administrator' and v_actor<>'owner' then raise exception 'Only owners remove administrators'; end if;
 delete from public.organization_members where organization_id=p_org and user_id=p_user;
 perform private.write_audit(p_org,'membership.removed','member',p_user,
  jsonb_build_object('previous_role',v_old));
end $$;

-- Proposed plan catalog. Stripe price IDs must be configured by operator, never by end users.
create table public.subscription_plans(
 code text primary key check(code in ('starter','business','professional')),
 title text not null,
 monthly_price_cad numeric(10,2) not null,
 stripe_price_id text unique,
 active boolean not null default true,
 features jsonb not null check(jsonb_typeof(features)='object'),
 created_at timestamptz not null default now()
);
insert into public.subscription_plans(code,title,monthly_price_cad,features) values
('starter','Starter',15.00,'{"users":2,"receipt_ocr_monthly":0,"bank_connections":0,"api_access":false}'::jsonb),
('business','Business',35.00,'{"users":5,"receipt_ocr_monthly":200,"bank_connections":1,"api_access":false}'::jsonb),
('professional','Professional',65.00,'{"users":15,"receipt_ocr_monthly":1000,"bank_connections":5,"api_access":true}'::jsonb);

create table public.organization_subscriptions(
 organization_id uuid primary key references public.organizations(id) on delete restrict,
 stripe_customer_id text unique,
 stripe_subscription_id text unique,
 plan_code text references public.subscription_plans(code),
 status text not null default 'none' check(status in
 ('none','trialing','active','past_due','unpaid','incomplete','incomplete_expired','canceled','paused')),
 current_period_end timestamptz,
 cancel_at_period_end boolean not null default false,
 provider_event_created bigint not null default 0,
 provider_event_id text,
 updated_at timestamptz not null default now()
);
create table public.billing_webhook_events(
 stripe_event_id text primary key,
 event_created bigint not null,
 event_type text not null,
 organization_id uuid references public.organizations(id),
 received_at timestamptz not null default now()
);
alter table public.subscription_plans enable row level security;
alter table public.organization_subscriptions enable row level security;
alter table public.billing_webhook_events enable row level security;
create policy plans_select on public.subscription_plans for select to authenticated using(active);
create policy subscriptions_select on public.organization_subscriptions for select to authenticated
 using(public.has_org_access(organization_id));
revoke all on public.subscription_plans,public.organization_subscriptions,public.billing_webhook_events
 from public,anon,authenticated;
grant select(code,title,monthly_price_cad,features,active) on public.subscription_plans to authenticated;
grant select(organization_id,plan_code,status,current_period_end,cancel_at_period_end,updated_at)
 on public.organization_subscriptions to authenticated;

-- Resolve entitlements from provider status, never from client-selected plans.
create function public.organization_entitlements(p_org uuid) returns jsonb
language plpgsql stable security definer set search_path=''
as $$
declare s public.organization_subscriptions%rowtype;v_features jsonb;
begin
 if not public.has_org_access(p_org) then raise exception 'Not authorized'; end if;
 select * into s from public.organization_subscriptions where organization_id=p_org;
 if not found or s.status not in ('active','trialing') then
   return jsonb_build_object('plan','none','paid_features',false,'users',1,
     'receipt_ocr_monthly',0,'bank_connections',0,'api_access',false);
 end if;
 select features into v_features from public.subscription_plans where code=s.plan_code and active;
 if v_features is null then raise exception 'Plan configuration missing'; end if;
 return v_features||jsonb_build_object('plan',s.plan_code,'paid_features',true);
end $$;

-- Only the server-side service_role is allowed to apply signed Stripe event results.
-- The API verifies Stripe-Signature before calling this function.
create function public.apply_stripe_subscription_event(
 p_event_id text,p_event_created bigint,p_org uuid,p_customer text,
 p_subscription text,p_price text,p_status text,p_period_end timestamptz,
 p_cancel_at_period_end boolean,p_event_type text
) returns boolean language plpgsql security definer set search_path=''
as $$
declare v_plan text;v_current public.organization_subscriptions%rowtype;
begin
 if p_event_id is null or length(p_event_id)>255 or p_event_created is null or
    p_event_created<=0 or p_org is null or p_customer is null or p_subscription is null or
    p_price is null or p_status not in
 ('trialing','active','past_due','unpaid','incomplete','incomplete_expired','canceled','paused')
 then raise exception 'Invalid subscription event'; end if;
 if p_event_type not in ('customer.subscription.created','customer.subscription.updated','customer.subscription.deleted')
 then raise exception 'Unsupported subscription event'; end if;
 select code into v_plan from public.subscription_plans where stripe_price_id=p_price and active;
 if v_plan is null then raise exception 'Unrecognized Stripe price ID'; end if;
 perform 1 from public.organizations where id=p_org for update;
 if not found then raise exception 'Organization does not exist'; end if;
 if exists(select 1 from public.billing_webhook_events where stripe_event_id=p_event_id)
 then return false; end if;
 select * into v_current from public.organization_subscriptions where organization_id=p_org for update;
 if found and ((v_current.stripe_customer_id is not null and v_current.stripe_customer_id<>p_customer)
 or (v_current.stripe_subscription_id is not null and v_current.stripe_subscription_id<>p_subscription
 and v_current.status not in ('canceled','incomplete_expired','none')))
 then raise exception 'Stripe customer or subscription mismatch'; end if;
 if found and p_event_created<v_current.provider_event_created then
   insert into public.billing_webhook_events(stripe_event_id,event_created,event_type,organization_id)
   values(p_event_id,p_event_created,p_event_type,p_org);
   return false;
 end if;
 insert into public.organization_subscriptions(organization_id,stripe_customer_id,
  stripe_subscription_id,plan_code,status,current_period_end,cancel_at_period_end,
  provider_event_created,provider_event_id,updated_at)
 values(p_org,p_customer,p_subscription,v_plan,
  case when p_event_type='customer.subscription.deleted' then 'canceled' else p_status end,
  p_period_end,coalesce(p_cancel_at_period_end,false),p_event_created,p_event_id,now())
 on conflict(organization_id) do update set
 stripe_customer_id=excluded.stripe_customer_id,
 stripe_subscription_id=excluded.stripe_subscription_id,
 plan_code=excluded.plan_code,status=excluded.status,
 current_period_end=excluded.current_period_end,
 cancel_at_period_end=excluded.cancel_at_period_end,
 provider_event_created=excluded.provider_event_created,
 provider_event_id=excluded.provider_event_id,updated_at=excluded.updated_at;
 insert into public.billing_webhook_events(stripe_event_id,event_created,event_type,organization_id)
 values(p_event_id,p_event_created,p_event_type,p_org);
 perform private.write_audit(p_org,'billing.subscription_synced','subscription',null,
   jsonb_build_object('status',p_status,'plan',v_plan,'event_type',p_event_type));
 return true;
end $$;

revoke all on function public.apply_stripe_subscription_event(
 text,bigint,uuid,text,text,text,text,timestamptz,boolean,text) from public,anon,authenticated;
grant execute on function public.apply_stripe_subscription_event(
 text,bigint,uuid,text,text,text,text,timestamptz,boolean,text) to service_role;
revoke all on function public.organization_entitlements(uuid) from public,anon;
grant execute on function public.organization_entitlements(uuid) to authenticated;
revoke all on function public.invite_organization_member(uuid,text,text) from public,anon;
grant execute on function public.invite_organization_member(uuid,text,text) to authenticated;
revoke all on function public.accept_organization_invitation(text) from public,anon;
grant execute on function public.accept_organization_invitation(text) to authenticated;
revoke all on function public.revoke_organization_invitation(uuid,uuid) from public,anon;
grant execute on function public.revoke_organization_invitation(uuid,uuid) to authenticated;
revoke all on function public.set_organization_member_role(uuid,uuid,text) from public,anon;
grant execute on function public.set_organization_member_role(uuid,uuid,text) to authenticated;
revoke all on function public.remove_organization_member(uuid,uuid) from public,anon;
grant execute on function public.remove_organization_member(uuid,uuid) to authenticated;
