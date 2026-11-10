-- Plaid update-mode sessions bind reauthorization to one known tenant, user and
-- existing provider Item. The service verifies the provider state before reactivating.
create table public.bank_feed_update_sessions(
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null,
 connection_id uuid not null,
 user_id uuid not null references auth.users(id),
 created_at timestamptz not null default now(),
 expires_at timestamptz not null,
 claimed_at timestamptz,
 consumed_at timestamptz,
 foreign key(organization_id,connection_id)
  references public.bank_feed_connections(organization_id,id),
 unique(organization_id,id)
);
alter table public.bank_feed_update_sessions enable row level security;
revoke all on public.bank_feed_update_sessions from public,anon,authenticated;

create function public.claim_bank_update_session(
 p_id uuid,p_org uuid,p_user uuid,p_connection uuid)
returns boolean language plpgsql security definer set search_path=''
as $$
declare v_id uuid;
begin
 if p_id is null or p_org is null or p_user is null or p_connection is null then return false;end if;
 update public.bank_feed_update_sessions set claimed_at=now(),consumed_at=now()
 where id=p_id and organization_id=p_org and user_id=p_user
 and connection_id=p_connection and expires_at>now()
 and claimed_at is null and consumed_at is null
 returning id into v_id;
 return v_id is not null;
end $$;
revoke all on function public.claim_bank_update_session(uuid,uuid,uuid,uuid)
 from public,anon,authenticated;
grant execute on function public.claim_bank_update_session(uuid,uuid,uuid,uuid)
 to service_role;
