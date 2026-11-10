-- Milestone 10: one-time, transactional claims for external provider authorizations.
-- Only the API service role can claim secrets; a concurrent replay cannot complete.
-- Claims are consumed before exchanging credentials and are never recycled.
alter table public.bank_feed_link_sessions add column claimed_at timestamptz;
alter table public.qbo_oauth_states add column claimed_at timestamptz;

create function public.claim_bank_link_session(p_session uuid,p_organization uuid,p_user uuid)
returns boolean language plpgsql security definer set search_path=''
as $$
declare v_result uuid;
begin
 if p_session is null or p_organization is null or p_user is null then return false;end if;
 update public.bank_feed_link_sessions set claimed_at=now(),consumed_at=now()
 where id=p_session and organization_id=p_organization and user_id=p_user
  and expires_at>now() and claimed_at is null and consumed_at is null
 returning id into v_result;
 return v_result is not null;
end $$;

create function public.claim_qbo_oauth_state(p_sha256 text)
returns table(organization_id uuid,user_id uuid)
language plpgsql security definer set search_path=''
as $$
begin
 if p_sha256 is null or p_sha256 !~ '^[a-f0-9]{64}$' then return;end if;
 return query
 update public.qbo_oauth_states s set claimed_at=now(),consumed_at=now()
 where s.state_hash=p_sha256 and s.expires_at>now()
  and s.claimed_at is null and s.consumed_at is null
 returning s.organization_id,s.user_id;
end $$;

revoke all on function public.claim_bank_link_session(uuid,uuid,uuid),
 public.claim_qbo_oauth_state(text) from public,anon,authenticated;
grant execute on function public.claim_bank_link_session(uuid,uuid,uuid),
 public.claim_qbo_oauth_state(text) to service_role;

-- Do not leak provider encrypted credentials to signed-in clients.
-- Supabase service-role access remains an explicitly trusted API boundary.
revoke all on public.bank_feed_connections,public.bank_feed_link_sessions,
 public.qbo_connections,public.qbo_oauth_states from public,anon,authenticated;
