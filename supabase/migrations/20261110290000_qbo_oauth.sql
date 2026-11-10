-- OAuth linkage is maintained entirely server-side. End users never read
-- decrypted tokens or authorization state. Credentials are AES-GCM-encrypted.
create table public.qbo_connections(
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null references public.organizations(id) on delete restrict,
 realm_id text not null check(length(realm_id) between 1 and 100),
 encrypted_access_token text not null,
 encrypted_refresh_token text not null,
 access_expires_at timestamptz not null,
 refresh_expires_at timestamptz,
 created_by uuid not null references auth.users(id),
 connected_at timestamptz not null default now(),
 status text not null default 'active' check(status in ('active','reauthorization_required','disconnected')),
 unique(organization_id,id),unique(organization_id,realm_id)
);
create table public.qbo_oauth_states(
 state_hash char(64) primary key,
 organization_id uuid not null references public.organizations(id) on delete restrict,
 user_id uuid not null references auth.users(id),
 created_at timestamptz not null default now(),
 expires_at timestamptz not null,
 consumed_at timestamptz
);
alter table public.qbo_connections enable row level security;
alter table public.qbo_oauth_states enable row level security;
revoke all on public.qbo_connections,public.qbo_oauth_states from public,anon,authenticated;
create function public.qbo_connection_overview(p_org uuid)
returns table(realm_id text,connected_at timestamptz,status text)
language sql stable security definer set search_path=''
as $$
 select c.realm_id,c.connected_at,c.status from public.qbo_connections c
 where c.organization_id=p_org and public.has_org_access(c.organization_id)
$$;
revoke all on function public.qbo_connection_overview(uuid) from public,anon;
grant execute on function public.qbo_connection_overview(uuid) to authenticated;

-- Nonfinancial QBO records remain preserved as original provider JSON until
-- a separate accountant-approved semantic mapping is implemented.
create function public.migration_batch_progress(p_org uuid,p_batch uuid)
returns jsonb language sql stable security definer set search_path=''
as $$
 select case when public.has_org_access(p_org) then
  jsonb_build_object('batch_id',b.id,'state',b.state,
   'counts',coalesce((select jsonb_object_agg(record_kind,
    jsonb_build_object('total',total,'imported',imported,'archived',archived))
    from (select record_kind,count(*) total,count(*) filter(where status='imported') imported,
     count(*) filter(where status='archived') archived
     from public.migration_records r where r.organization_id=b.organization_id and r.batch_id=b.id
     group by record_kind) counts),'{}'::jsonb))
 else null end
 from public.migration_batches b where b.organization_id=p_org and b.id=p_batch
$$;
revoke all on function public.migration_batch_progress(uuid,uuid) from public,anon;
grant execute on function public.migration_batch_progress(uuid,uuid) to authenticated;
