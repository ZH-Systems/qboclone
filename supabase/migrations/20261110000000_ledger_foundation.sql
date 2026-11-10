-- Ledger North: multi-tenant accounting foundation.
-- Apply to a NEW Supabase project. Independently review before production use.
create extension if not exists pgcrypto;

create table public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(trim(name)) between 2 and 150),
  base_currency char(3) not null default 'CAD' check (base_currency = 'CAD'),
  created_at timestamptz not null default now()
);
create table public.organization_members (
  organization_id uuid not null references public.organizations(id) on delete restrict,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('owner','administrator','accountant','bookkeeper','viewer')),
  created_at timestamptz not null default now(),
  primary key (organization_id,user_id)
);
create table public.accounts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  code varchar(20) not null,
  name varchar(150) not null,
  account_type text not null check (account_type in ('asset','liability','equity','revenue','expense')),
  normal_balance text not null check (normal_balance in ('debit','credit')),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique(organization_id,code),
  unique(organization_id,id)
);
create table public.fiscal_periods (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  start_date date not null,
  end_date date not null,
  is_locked boolean not null default false,
  check (start_date <= end_date),
  unique(organization_id,start_date),
  unique(organization_id,id)
);
create table public.journal_entries (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  entry_date date not null,
  memo text not null check (char_length(trim(memo)) between 3 and 500),
  reference varchar(80),
  idempotency_key uuid not null,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  unique (organization_id,id),
  unique (organization_id,idempotency_key)
);
create table public.journal_lines (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  journal_entry_id uuid not null,
  account_id uuid not null,
  debit numeric(20,2) not null default 0 check (debit >= 0),
  credit numeric(20,2) not null default 0 check (credit >= 0),
  check ((debit > 0 and credit = 0) or (credit > 0 and debit = 0)),
  foreign key (organization_id,journal_entry_id) references public.journal_entries(organization_id,id) on delete restrict,
  foreign key (organization_id,account_id) references public.accounts(organization_id,id) on delete restrict
);
create index journal_entries_tenant_date_idx on public.journal_entries(organization_id,entry_date desc);
create index journal_lines_tenant_entry_idx on public.journal_lines(organization_id,journal_entry_id);
create index journal_lines_tenant_account_idx on public.journal_lines(organization_id,account_id);

-- Dedicated functions use explicit organization authorization, never client-selected tenant IDs alone.
create function public.has_org_access(p_organization_id uuid) returns boolean
language sql stable security definer set search_path = ''
as $$ select exists (select 1 from public.organization_members m where m.organization_id = p_organization_id and m.user_id = (select auth.uid())) $$;
create function public.has_org_write(p_organization_id uuid) returns boolean
language sql stable security definer set search_path = ''
as $$ select exists (select 1 from public.organization_members m where m.organization_id = p_organization_id and m.user_id = (select auth.uid()) and m.role in ('owner','administrator','accountant','bookkeeper')) $$;
revoke all on function public.has_org_access(uuid) from public, anon;
revoke all on function public.has_org_write(uuid) from public, anon;
grant execute on function public.has_org_access(uuid),public.has_org_write(uuid) to authenticated;

alter table public.organizations enable row level security;
alter table public.organization_members enable row level security;
alter table public.accounts enable row level security;
alter table public.fiscal_periods enable row level security;
alter table public.journal_entries enable row level security;
alter table public.journal_lines enable row level security;
create policy org_select on public.organizations for select to authenticated using (public.has_org_access(id));
create policy member_select on public.organization_members for select to authenticated using (public.has_org_access(organization_id));
create policy accounts_select on public.accounts for select to authenticated using (public.has_org_access(organization_id));
create policy periods_select on public.fiscal_periods for select to authenticated using (public.has_org_access(organization_id));
create policy journal_select on public.journal_entries for select to authenticated using (public.has_org_access(organization_id));
create policy lines_select on public.journal_lines for select to authenticated using (public.has_org_access(organization_id));

-- Authenticated users can read only tenant-visible rows. Mutations are through checked RPCs.
revoke all on public.organizations,public.organization_members,public.accounts,public.fiscal_periods,public.journal_entries,public.journal_lines from anon, authenticated;
grant select on public.organizations,public.organization_members,public.accounts,public.fiscal_periods,public.journal_entries,public.journal_lines to authenticated;

create function public.create_organization(p_name text) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare v_id uuid; v_user uuid := auth.uid(); v_year integer := extract(year from current_date);
begin
  if v_user is null then raise exception 'Authentication required'; end if;
  if p_name is null or char_length(trim(p_name)) not between 2 and 150 then raise exception 'Business name must contain 2 to 150 characters'; end if;
  insert into public.organizations(name) values (trim(p_name)) returning id into v_id;
  insert into public.organization_members(organization_id,user_id,role) values(v_id,v_user,'owner');
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
  return v_id;
end $$;
revoke all on function public.create_organization(text) from public, anon;
grant execute on function public.create_organization(text) to authenticated;

create function public.create_account(p_organization_id uuid,p_code text,p_name text,p_type text) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare v_id uuid; v_normal text;
begin
  if not public.has_org_write(p_organization_id) then raise exception 'Not authorized'; end if;
  if p_code is null or p_code !~ '^[A-Za-z0-9._-]{1,20}$' then raise exception 'Invalid account code'; end if;
  if p_name is null or char_length(trim(p_name)) not between 1 and 150 then raise exception 'Invalid account name'; end if;
  if p_type not in ('asset','liability','equity','revenue','expense') then raise exception 'Invalid account type'; end if;
  v_normal := case when p_type in ('asset','expense') then 'debit' else 'credit' end;
  insert into public.accounts(organization_id,code,name,account_type,normal_balance)
    values(p_organization_id,p_code,trim(p_name),p_type,v_normal) returning id into v_id;
  return v_id;
end $$;
revoke all on function public.create_account(uuid,text,text,text) from public, anon;
grant execute on function public.create_account(uuid,text,text,text) to authenticated;

-- Batch posting: no direct journal INSERT privilege for clients.
-- Same-organization constraints, idempotency and balanced sums are enforced transactionally.
create function public.post_journal(
  p_organization_id uuid,
  p_entry_date date,
  p_memo text,
  p_reference text,
  p_idempotency_key uuid,
  p_lines jsonb
) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare v_id uuid; v_line jsonb; v_debit numeric; v_credit numeric;
        v_debits numeric(20,2) := 0; v_credits numeric(20,2) := 0;
        v_account uuid; v_count integer := 0; v_period uuid;
begin
  if not public.has_org_write(p_organization_id) then raise exception 'Not authorized to post'; end if;
  if p_entry_date is null or p_memo is null or char_length(trim(p_memo)) not between 3 and 500 then raise exception 'Invalid journal header'; end if;
  if p_idempotency_key is null then raise exception 'Idempotency key is required'; end if;
  if jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines) not between 2 and 100 then raise exception 'Journal must contain 2 to 100 lines'; end if;
  -- Lock the organization to serialize same-tenant posting and period changes.
  perform 1 from public.organizations where id=p_organization_id for update;
  select id into v_id from public.journal_entries where organization_id=p_organization_id and idempotency_key=p_idempotency_key;
  if found then return v_id; end if;
  select id into v_period from public.fiscal_periods
    where organization_id=p_organization_id and p_entry_date between start_date and end_date and not is_locked
    for update;
  if v_period is null then raise exception 'Accounting period is closed or missing'; end if;
  for v_line in select value from jsonb_array_elements(p_lines)
  loop
    if (v_line->>'account_id') is null then raise exception 'Account ID missing'; end if;
    v_account := (v_line->>'account_id')::uuid;
    if not exists(select 1 from public.accounts where organization_id=p_organization_id and id=v_account and is_active) then
      raise exception 'Account not found or inactive';
    end if;
    v_debit := (v_line->>'debit')::numeric;
    v_credit := (v_line->>'credit')::numeric;
    if v_debit is null or v_credit is null or v_debit < 0 or v_credit < 0
       or (v_debit > 0) = (v_credit > 0)
       or round(v_debit,2) <> v_debit or round(v_credit,2) <> v_credit then
      raise exception 'Each line requires exactly one positive debit or credit with cent precision';
    end if;
    v_debits := v_debits + v_debit;
    v_credits := v_credits + v_credit;
    v_count := v_count + 1;
  end loop;
  if v_count < 2 or v_debits <= 0 or v_debits <> v_credits then raise exception 'Journal must balance'; end if;
  insert into public.journal_entries(organization_id,entry_date,memo,reference,idempotency_key,created_by)
    values(p_organization_id,p_entry_date,trim(p_memo),nullif(trim(p_reference),''),p_idempotency_key,auth.uid())
    returning id into v_id;
  for v_line in select value from jsonb_array_elements(p_lines)
  loop
    insert into public.journal_lines(organization_id,journal_entry_id,account_id,debit,credit)
    values(p_organization_id,v_id,(v_line->>'account_id')::uuid,(v_line->>'debit')::numeric,(v_line->>'credit')::numeric);
  end loop;
  return v_id;
end $$;
revoke all on function public.post_journal(uuid,date,text,text,uuid,jsonb) from public, anon;
grant execute on function public.post_journal(uuid,date,text,text,uuid,jsonb) to authenticated;

-- Read-only ledger tables plus restricted posting functions make posted entries immutable
-- for ordinary authenticated clients; privileged database operators require audit controls.
