-- Milestone 5: durable tenant-scoped usage metering, audited exports and append-only audit history.
-- No service role credentials or client-provided quota values enter these functions.

alter table public.subscription_plans
  add constraint plan_features_object_check check(jsonb_typeof(features)='object');
update public.subscription_plans set features=jsonb_set(features,'{bank_import_rows_monthly}',
  to_jsonb(case code when 'starter' then 1000 when 'business' then 5000 else 20000 end),true);

create table public.organization_usage_monthly(
  organization_id uuid not null references public.organizations(id) on delete restrict,
  month_start date not null,
  metric text not null check(metric in ('bank_import_rows')),
  units bigint not null default 0 check(units>=0),
  updated_at timestamptz not null default now(),
  primary key(organization_id,month_start,metric)
);
alter table public.organization_usage_monthly enable row level security;
create policy organization_usage_read on public.organization_usage_monthly
  for select to authenticated using(public.has_org_access(organization_id));
revoke all on public.organization_usage_monthly from public,anon,authenticated;
grant select on public.organization_usage_monthly to authenticated;

-- Existing import implementation remains inside the database transaction and is
-- inaccessible to direct client RPC invocation. Duplicate row replays count as zero.
alter function public.import_bank_statement_rows(uuid,uuid,jsonb) rename to import_bank_statement_rows_legacy;
revoke all on function public.import_bank_statement_rows_legacy(uuid,uuid,jsonb)
  from public,anon,authenticated,service_role;

create function public.import_bank_statement_rows(
  p_organization_id uuid,p_statement_id uuid,p_rows jsonb
) returns integer language plpgsql security definer set search_path=''
as $$
declare v_added integer;v_limit integer;v_current bigint;v_month date;
begin
  if not public.has_org_write(p_organization_id) then raise exception 'Not authorized'; end if;
  -- Locks the org row, serializing imports across bank statements for one tenant.
  perform 1 from public.organizations where id=p_organization_id for update;
  v_month:=date_trunc('month',now() at time zone 'UTC')::date;
  select case when s.status in ('trialing','active')
    then coalesce((p.features->>'bank_import_rows_monthly')::integer,500)
    else 500 end into v_limit
  from public.organization_subscriptions s
  join public.subscription_plans p on p.code=s.plan_code and p.active
  where s.organization_id=p_organization_id;
  v_limit:=coalesce(v_limit,500);
  v_added:=public.import_bank_statement_rows_legacy(p_organization_id,p_statement_id,p_rows);
  insert into public.organization_usage_monthly(organization_id,month_start,metric,units)
    values(p_organization_id,v_month,'bank_import_rows',v_added)
  on conflict(organization_id,month_start,metric)
    do update set units=public.organization_usage_monthly.units+excluded.units,updated_at=now();
  select units into v_current from public.organization_usage_monthly
    where organization_id=p_organization_id and month_start=v_month and metric='bank_import_rows';
  if v_current>v_limit then
    raise exception 'Bank import monthly row quota exceeded (% of %). Upgrade or resume next month.',v_current,v_limit;
  end if;
  if v_added>0 then
    perform private.write_audit(p_organization_id,'bank.rows_imported','bank_statement',
      p_statement_id,jsonb_build_object('rows',v_added,'month',v_month));
  end if;
  return v_added;
end $$;
revoke all on function public.import_bank_statement_rows(uuid,uuid,jsonb) from public,anon;
grant execute on function public.import_bank_statement_rows(uuid,uuid,jsonb) to authenticated;

create function public.organization_usage_summary(p_organization_id uuid)
returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare v_month date;v_used bigint;v_limit integer;v_plan text;
begin
  if not public.has_org_access(p_organization_id) then raise exception 'Not authorized'; end if;
  v_month:=date_trunc('month',now() at time zone 'UTC')::date;
  select units into v_used from public.organization_usage_monthly
  where organization_id=p_organization_id and month_start=v_month and metric='bank_import_rows';
  select s.plan_code,case when s.status in ('trialing','active') then
    coalesce((p.features->>'bank_import_rows_monthly')::integer,500) else 500 end
  into v_plan,v_limit from public.organization_subscriptions s
  join public.subscription_plans p on p.code=s.plan_code and p.active
  where s.organization_id=p_organization_id;
  return jsonb_build_object('month',v_month,'metric','bank_import_rows',
    'used',coalesce(v_used,0),'limit',coalesce(v_limit,500),
    'plan',coalesce(v_plan,'none'));
end $$;
revoke all on function public.organization_usage_summary(uuid) from public,anon;
grant execute on function public.organization_usage_summary(uuid) to authenticated;

-- Server export audit endpoint, independently verified by auth.uid().
-- Accountants may export; other members cannot export all tenant data.
create function public.record_organization_export(p_organization_id uuid)
returns void language plpgsql security definer set search_path=''
as $$
begin
  if not exists(select 1 from public.organization_members
    where organization_id=p_organization_id and user_id=auth.uid()
      and role in ('owner','administrator','accountant')) then
    raise exception 'Not authorized to export organization data';
  end if;
  perform private.write_audit(p_organization_id,'organization.export_requested',
    'organization',p_organization_id);
end $$;
revoke all on function public.record_organization_export(uuid) from public,anon;
grant execute on function public.record_organization_export(uuid) to authenticated;

create function private.audit_payment_insert() returns trigger
language plpgsql security definer set search_path=''
as $$
begin
  perform private.write_audit(new.organization_id,'payment.recorded','payment',new.id,
    jsonb_build_object('document_id',new.document_id,'amount',new.amount));
  return new;
end $$;
create trigger audit_payment_insert after insert on public.document_payments
 for each row execute function private.audit_payment_insert();

create function private.audit_contact_insert() returns trigger
language plpgsql security definer set search_path=''
as $$
begin
  perform private.write_audit(new.organization_id,'contact.created','contact',new.id,
   jsonb_build_object('kind',new.contact_kind));
  return new;
end $$;
create trigger audit_contact_insert after insert on public.contacts
 for each row execute function private.audit_contact_insert();

create function private.audit_statement_change() returns trigger
language plpgsql security definer set search_path=''
as $$
begin
  if tg_op='INSERT' then
    perform private.write_audit(new.organization_id,'bank.statement_created','bank_statement',new.id);
  elsif new.status is distinct from old.status then
    perform private.write_audit(new.organization_id,'bank.statement_reconciled','bank_statement',new.id);
  end if;
  return new;
end $$;
create trigger audit_statement_insert after insert on public.bank_statements
 for each row execute function private.audit_statement_change();
create trigger audit_statement_reconcile after update of status on public.bank_statements
 for each row execute function private.audit_statement_change();

create function private.audit_tax_code_insert() returns trigger
language plpgsql security definer set search_path=''
as $$
begin
  perform private.write_audit(new.organization_id,'tax.code_created','tax_code',new.id,
    jsonb_build_object('code',new.code,'classification',new.classification,
      'rate_bps',new.rate_bps));
  return new;
end $$;
create trigger audit_tax_code_insert after insert on public.tax_codes
 for each row execute function private.audit_tax_code_insert();

-- Prevent modification or deletion even if a future service routine accidentally
-- obtains direct write permissions. Superusers can still disable triggers.
create function private.block_audit_mutation() returns trigger
language plpgsql set search_path=''
as $$
begin
  raise exception 'Audit history is append-only';
end $$;
create trigger audit_events_immutable before update or delete on public.audit_events
 for each row execute function private.block_audit_mutation();

revoke all on function private.audit_payment_insert(),
 private.audit_contact_insert(),private.audit_statement_change(),
 private.audit_tax_code_insert(),private.block_audit_mutation()
 from public,anon,authenticated;
