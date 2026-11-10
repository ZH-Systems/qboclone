-- Milestone 4 organization administration, subscription-based limits and audit hooks.
-- These functions read billing entitlements server-side, not client-supplied limits.
create function public.list_organization_members(p_org uuid)
returns table(user_id uuid,email text,role text,joined_at timestamptz)
language plpgsql stable security definer set search_path=''
as $$
begin
 if not public.has_org_access(p_org) then raise exception 'Not authorized'; end if;
 return query
 select m.user_id,u.email,m.role,m.created_at
 from public.organization_members m
 join auth.users u on u.id=m.user_id
 where m.organization_id=p_org
 order by m.created_at,m.user_id;
end $$;
revoke all on function public.list_organization_members(uuid) from public,anon;
grant execute on function public.list_organization_members(uuid) to authenticated;

-- Keep the SQL function name stable for clients, enforcing subscribed member counts
-- on acceptance as well as invitation creation to prevent race/over-provisioning.
create or replace function public.accept_organization_invitation(p_token text)
returns uuid language plpgsql security definer set search_path=''
as $$
declare v_inv public.organization_invitations%rowtype;v_user_email text;v_confirmed timestamptz;
 v_org uuid;v_limit integer;v_count integer;v_entitlements jsonb;
begin
 if auth.uid() is null or p_token is null or p_token !~ '^[a-f0-9]{64}$' then
  raise exception 'Authentication and valid token required'; end if;
 select lower(email),email_confirmed_at into v_user_email,v_confirmed
 from auth.users where id=auth.uid();
 if v_confirmed is null then raise exception 'Verify email before accepting invitations'; end if;
 -- First locate org, then acquire locks consistently in org -> invitation order.
 select organization_id into v_org from public.organization_invitations
 where token_hash=encode(extensions.digest(p_token,'sha256'),'hex');
 if v_org is null then raise exception 'Invitation is invalid'; end if;
 perform 1 from public.organizations where id=v_org for update;
 select * into v_inv from public.organization_invitations
 where token_hash=encode(extensions.digest(p_token,'sha256'),'hex') for update;
 if not found or v_inv.revoked_at is not null or v_inv.accepted_at is not null
   or v_inv.expires_at<=now() or v_inv.invited_email<>v_user_email then
   raise exception 'Invitation invalid, expired or issued to another email'; end if;
 -- Unsubscribed organizations retain only their original owner.
 select case when s.status in ('active','trialing') then (p.features->>'users')::integer else 1 end
 into v_limit from public.organization_subscriptions s
 join public.subscription_plans p on p.code=s.plan_code and p.active
 where s.organization_id=v_org;
 v_limit:=coalesce(v_limit,1);
 select count(*) into v_count from public.organization_members where organization_id=v_org;
 if v_count>=v_limit then raise exception 'Organization subscription user limit reached'; end if;
 insert into public.organization_members(organization_id,user_id,role)
 values(v_org,auth.uid(),v_inv.role)
 on conflict(organization_id,user_id) do nothing;
 update public.organization_invitations set accepted_at=now(),accepted_by=auth.uid() where id=v_inv.id;
 perform private.write_audit(v_org,'membership.accepted','invitation',v_inv.id,
  jsonb_build_object('role',v_inv.role));
 return v_org;
end $$;

-- Reassert correct RPC permissions, never expose service-only subscription writer.
revoke all on function public.accept_organization_invitation(text) from public,anon;
grant execute on function public.accept_organization_invitation(text) to authenticated;

-- Audit existing system financial actions without exposing direct journal changes.
-- Trigger runs only on inserts. Posted journal updates/deletes remain outside ordinary client grants.
create function private.audit_new_journal()
returns trigger language plpgsql security definer set search_path=''
as $$
begin
 perform private.write_audit(new.organization_id,'ledger.journal_created','journal',new.id,
   jsonb_build_object('source_kind',new.source_kind,'entry_date',new.entry_date,
      'idempotency_key',new.idempotency_key));
 return new;
end $$;
create trigger audit_journal_insert after insert on public.journal_entries
 for each row execute function private.audit_new_journal();
revoke all on function private.audit_new_journal() from public,anon,authenticated;

create function private.audit_document_state()
returns trigger language plpgsql security definer set search_path=''
as $$
begin
 if tg_op='INSERT' then
  perform private.write_audit(new.organization_id,'document.created','financial_document',new.id,
    jsonb_build_object('document_type',new.document_type,'number',new.document_number));
 elsif new.status is distinct from old.status then
  perform private.write_audit(new.organization_id,'document.status_changed','financial_document',new.id,
    jsonb_build_object('from',old.status,'to',new.status,'number',new.document_number));
 end if;
 return new;
end $$;
create trigger audit_document_insert after insert on public.financial_documents
 for each row execute function private.audit_document_state();
create trigger audit_document_status after update of status on public.financial_documents
 for each row execute function private.audit_document_state();
revoke all on function private.audit_document_state() from public,anon,authenticated;

-- Owner-controlled invitation creation, acceptance, role changes and removal
-- are all captured in the append-only audit_events table.
