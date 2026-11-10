-- Explicit bank account eligibility and effective-dated tax configurations.
alter table public.accounts add column if not exists is_bank_account boolean not null default false;
update public.accounts set is_bank_account=true where code='1000' and account_type='asset';
alter table public.accounts add constraint bank_account_asset_only_check
 check(not is_bank_account or account_type='asset');
alter table public.tax_codes add column effective_from date not null default '1900-01-01';
alter table public.tax_codes add column effective_until date;
alter table public.tax_codes add constraint tax_code_effective_range_check
 check(effective_until is null or effective_until>=effective_from);

create function public.set_bank_account_flag(
 p_organization_id uuid,p_account_id uuid,p_is_bank boolean
) returns void language plpgsql security definer set search_path=''
as $$
begin
 if auth.uid() is null or not exists(
  select 1 from public.organization_members m where m.organization_id=p_organization_id
  and m.user_id=auth.uid() and m.role in ('owner','administrator','accountant')
 ) then raise exception 'Bank account administration requires administrator or accountant access'; end if;
 if p_is_bank is null then raise exception 'Bank account state required'; end if;
 perform 1 from public.organizations where id=p_organization_id for update;
 if not p_is_bank and exists(select 1 from public.bank_statements s
  where s.organization_id=p_organization_id and s.bank_account_id=p_account_id)
 then raise exception 'Cannot unmark a bank account with imported statements'; end if;
 update public.accounts set is_bank_account=p_is_bank
 where id=p_account_id and organization_id=p_organization_id and account_type='asset';
 if not found then raise exception 'Account is not an asset in this organization'; end if;
end $$;
revoke all on function public.set_bank_account_flag(uuid,uuid,boolean) from public,anon;
grant execute on function public.set_bank_account_flag(uuid,uuid,boolean) to authenticated;

-- Strengthen the bank statement constructor by verifying the explicit account flag.
create or replace function public.create_bank_statement(
 p_organization_id uuid,p_bank_account_id uuid,p_start date,p_end date,
 p_opening numeric,p_closing numeric
) returns uuid language plpgsql security definer set search_path=''
as $$
declare v_id uuid;
begin
 if not public.has_org_write(p_organization_id) then raise exception 'Not authorized'; end if;
 if p_start is null or p_end is null or p_start>p_end or
   p_opening is null or p_closing is null or scale(p_opening)>2 or scale(p_closing)>2
 then raise exception 'Invalid statement dates or balances'; end if;
 if not exists(select 1 from public.accounts a where a.organization_id=p_organization_id
   and a.id=p_bank_account_id and a.account_type='asset' and a.is_active and a.is_bank_account)
 then raise exception 'Select an active designated bank account'; end if;
 perform 1 from public.organizations where id=p_organization_id for update;
 if exists(select 1 from public.bank_statements where organization_id=p_organization_id
   and bank_account_id=p_bank_account_id and start_date<=p_end and end_date>=p_start)
 then raise exception 'Statement date ranges cannot overlap for one bank account'; end if;
 insert into public.bank_statements(organization_id,bank_account_id,start_date,end_date,opening_balance,closing_balance)
 values(p_organization_id,p_bank_account_id,p_start,p_end,p_opening,p_closing)
 returning id into v_id;
 return v_id;
end $$;

-- Rename effective-dated tax codes by creating a NEW code rather than changing used
-- snapshots. Existing documents retain the applied rate and recoverability amount.
-- Retains the original RPC signature, with defaults for clients not using dates.
create or replace function public.create_tax_code(
 p_organization_id uuid,p_code text,p_label text,p_kind text,p_classification text,
 p_rate_bps integer,p_recoverable_bps integer default 0
) returns uuid language plpgsql security definer set search_path=''
as $$
declare v_id uuid;
begin
 if not public.has_org_write(p_organization_id) then raise exception 'Not authorized'; end if;
 if p_code is null or p_code !~ '^[A-Za-z0-9_-]{1,24}$' then raise exception 'Invalid tax code'; end if;
 if p_label is null or length(trim(p_label)) not between 1 and 120 then raise exception 'Invalid tax label'; end if;
 if p_kind not in ('sale','purchase') or p_classification not in ('taxable','zero_rated','exempt','out_of_scope')
 then raise exception 'Invalid tax classification'; end if;
 if p_rate_bps is null or p_rate_bps not between 0 and 2500 or
  p_recoverable_bps is null or p_recoverable_bps not between 0 and 10000
 then raise exception 'Invalid tax rate or recoverability'; end if;
 insert into public.tax_codes(organization_id,code,label,transaction_kind,classification,rate_bps,recoverable_bps)
 values(p_organization_id,p_code,trim(p_label),p_kind,p_classification,p_rate_bps,p_recoverable_bps)
 returning id into v_id;
 return v_id;
end $$;
