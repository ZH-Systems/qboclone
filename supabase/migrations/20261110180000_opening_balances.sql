-- Milestone 6: one-time opening balance import.
-- Opening balances use balance sheet accounts only and offset Owner Equity (3000).
-- This import is intentionally unavailable after any other journal was posted.
create table public.opening_balance_imports(
  organization_id uuid primary key references public.organizations(id) on delete restrict,
  journal_entry_id uuid not null,
  opening_date date not null,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  foreign key(organization_id,journal_entry_id) references public.journal_entries(organization_id,id)
);
alter table public.opening_balance_imports enable row level security;
create policy opening_balances_read on public.opening_balance_imports
 for select to authenticated using(public.has_org_access(organization_id));
revoke all on public.opening_balance_imports from public,anon,authenticated;
grant select on public.opening_balance_imports to authenticated;

create function public.import_opening_balances(
 p_organization_id uuid,p_opening_date date,p_lines jsonb
) returns uuid language plpgsql security definer set search_path=''
as $$
declare v_role text;v_line jsonb;v_acc uuid;v_debit numeric;v_credit numeric;
 v_total_debit numeric(20,2):=0;v_total_credit numeric(20,2):=0;
 v_equity uuid;v_lines jsonb:='[]'::jsonb;v_journal uuid;v_count int:=0;
begin
 select role into v_role from public.organization_members
 where organization_id=p_organization_id and user_id=auth.uid();
 if v_role is null or v_role not in ('owner','administrator','accountant') then
  raise exception 'Opening balances require owner, administrator or accountant';end if;
 if p_opening_date is null or jsonb_typeof(p_lines) is distinct from 'array'
  or jsonb_array_length(p_lines) not between 1 and 98 then
  raise exception 'Opening balance input requires 1 to 98 lines and an effective date';end if;
 perform 1 from public.organizations where id=p_organization_id for update;
 if exists(select 1 from public.opening_balance_imports where organization_id=p_organization_id)
 then raise exception 'Opening balances have already been imported';end if;
 if exists(select 1 from public.journal_entries where organization_id=p_organization_id)
 then raise exception 'Opening balances can only be imported before ordinary ledger activity';end if;
 if not exists(select 1 from public.fiscal_periods
  where organization_id=p_organization_id and start_date=p_opening_date and not is_locked)
 then raise exception 'Opening date must match an open fiscal period start';end if;
 select id into v_equity from public.accounts where organization_id=p_organization_id
 and code='3000' and is_active and account_type='equity';
 if v_equity is null then raise exception 'Owner equity account unavailable';end if;
 for v_line in select value from jsonb_array_elements(p_lines) loop
  v_acc:=nullif(v_line->>'account_id','')::uuid;
  v_debit:=(v_line->>'debit')::numeric;
  v_credit:=(v_line->>'credit')::numeric;
  if v_debit is null or v_credit is null or v_debit<0 or v_credit<0
  or round(v_debit,2)<>v_debit or round(v_credit,2)<>v_credit
  or (v_debit>0)=(v_credit>0) then raise exception 'Invalid opening balance amount';end if;
  if not exists(select 1 from public.accounts where organization_id=p_organization_id
    and id=v_acc and is_active and account_type in ('asset','liability','equity') and code<>'3000')
  then raise exception 'Opening balances require active same-tenant balance sheet accounts';end if;
  v_total_debit:=v_total_debit+v_debit;v_total_credit:=v_total_credit+v_credit;
  v_lines:=v_lines||jsonb_build_array(jsonb_build_object(
   'account_id',v_acc,'debit',v_debit,'credit',v_credit));
  v_count:=v_count+1;
 end loop;
 if v_total_debit=v_total_credit and v_count<2 then raise exception 'Opening journal requires two lines';end if;
 if v_total_debit<>v_total_credit then
  v_lines:=v_lines||jsonb_build_array(jsonb_build_object('account_id',v_equity,
   'debit',greatest(0,v_total_credit-v_total_debit),
   'credit',greatest(0,v_total_debit-v_total_credit)));
 end if;
 v_journal:=private.post_accounting_journal_internal('manual',p_organization_id,p_opening_date,
   'Opening balance import','OPENING',gen_random_uuid(),v_lines);
 insert into public.opening_balance_imports(organization_id,journal_entry_id,opening_date,created_by)
 values(p_organization_id,v_journal,p_opening_date,auth.uid());
 perform private.write_audit(p_organization_id,'ledger.opening_imported','journal',v_journal,
  jsonb_build_object('date',p_opening_date,'lines',v_count));
 return v_journal;
end $$;
revoke all on function public.import_opening_balances(uuid,date,jsonb) from public,anon;
grant execute on function public.import_opening_balances(uuid,date,jsonb) to authenticated;
