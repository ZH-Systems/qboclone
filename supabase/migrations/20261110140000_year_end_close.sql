-- Milestone 6: fiscal year-end accounting, non-destructive period close and retained earnings.
-- Runs after Milestone 5 migrations. This does not implement statutory corporate income tax.
create table public.year_end_closures(
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  fiscal_period_id uuid not null,
  closing_journal_id uuid,
  retained_earnings_account_id uuid not null,
  closed_at timestamptz not null default now(),
  closed_by uuid not null references auth.users(id),
  unique(organization_id,fiscal_period_id),
  unique(organization_id,id),
  foreign key(organization_id,fiscal_period_id) references public.fiscal_periods(organization_id,id),
  foreign key(organization_id,closing_journal_id) references public.journal_entries(organization_id,id),
  foreign key(organization_id,retained_earnings_account_id) references public.accounts(organization_id,id)
);
create index year_end_closures_org_idx on public.year_end_closures(organization_id,closed_at desc);
alter table public.year_end_closures enable row level security;
create policy year_end_closures_read on public.year_end_closures for select to authenticated
 using(public.has_org_access(organization_id));
revoke all on public.year_end_closures from public,anon,authenticated;
grant select on public.year_end_closures to authenticated;

-- Existing organizations and new organizations both need the retained earnings account.
insert into public.accounts(organization_id,code,name,account_type,normal_balance)
 select o.id,'3100','Retained Earnings','equity','credit'
 from public.organizations o
 where not exists(select 1 from public.accounts a where a.organization_id=o.id and a.code='3100');

create function private.seed_retained_earnings() returns trigger
language plpgsql set search_path=''
as $$
begin
 if new.code='3000' and new.account_type='equity' then
  insert into public.accounts(organization_id,code,name,account_type,normal_balance)
  values(new.organization_id,'3100','Retained Earnings','equity','credit')
  on conflict (organization_id,code) do nothing;
 end if;
 return new;
end $$;
create trigger seed_retained_account after insert on public.accounts
 for each row execute function private.seed_retained_earnings();

-- A fiscal period with a completed year end may not be unlocked through the
-- existing administration RPC or other application SQL.
create function private.prevent_closed_year_reopen() returns trigger
language plpgsql set search_path=''
as $$
begin
 if old.is_locked and not new.is_locked and exists (
  select 1 from public.year_end_closures c
  where c.organization_id=old.organization_id and c.fiscal_period_id=old.id
 ) then raise exception 'Closed financial year cannot be reopened without a formal restatement workflow'; end if;
 return new;
end $$;
create trigger closed_year_cannot_reopen before update of is_locked on public.fiscal_periods
 for each row execute function private.prevent_closed_year_reopen();

-- Protect finalized financial years even if a privileged caller modifies
-- fiscal-period flags directly (without bypassing triggers).
create function private.reject_closed_year_journal() returns trigger
language plpgsql set search_path=''
as $$
begin
 if exists(select 1 from public.year_end_closures c
   join public.fiscal_periods p on p.organization_id=c.organization_id and p.id=c.fiscal_period_id
   where c.organization_id=new.organization_id and new.entry_date between p.start_date and p.end_date)
 then raise exception 'Cannot post journal into a completed financial year'; end if;
 return new;
end $$;
create trigger block_journal_in_completed_year before insert on public.journal_entries
 for each row execute function private.reject_closed_year_journal();

-- Close an entire fiscal period after all bookkeeper adjustments have been posted.
-- Journal lines clear cumulative revenue/expense movements only for this period.
-- Returned profit figure is signed: positive=income; negative=loss.
create function public.close_financial_year(p_organization_id uuid,p_period_id uuid)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_actor_role text; v_period public.fiscal_periods%rowtype;
 v_retained uuid;v_line record;v_lines jsonb:='[]'::jsonb;
 v_net numeric(20,2):=0;v_net_debit numeric(20,2);
 v_journal uuid;v_close_id uuid;v_count integer:=0;
begin
 select role into v_actor_role from public.organization_members where
  organization_id=p_organization_id and user_id=auth.uid();
 if v_actor_role not in ('owner','administrator','accountant') then
  raise exception 'Financial year close requires owner, administrator or accountant'; end if;
 perform 1 from public.organizations where id=p_organization_id for update;
 select * into v_period from public.fiscal_periods
  where organization_id=p_organization_id and id=p_period_id for update;
 if not found then raise exception 'Fiscal period not found'; end if;
 select id into v_close_id from public.year_end_closures
  where organization_id=p_organization_id and fiscal_period_id=p_period_id;
 if found then
  return (select jsonb_build_object('closure_id',id,'journal_id',closing_journal_id,
          'already_closed',true) from public.year_end_closures where id=v_close_id);
 end if;
 if v_period.is_locked then raise exception 'Unlock this period before completing the final close'; end if;
 if v_period.end_date>current_date then raise exception 'Cannot close a future financial period';end if;
 if exists(select 1 from public.fiscal_periods p where p.organization_id=p_organization_id
    and p.end_date<v_period.start_date and not exists(
      select 1 from public.year_end_closures c where c.organization_id=p_organization_id
      and c.fiscal_period_id=p.id))
 then raise exception 'Prior fiscal periods must be formally closed first'; end if;
 select id into v_retained from public.accounts where organization_id=p_organization_id
  and code='3100' and account_type='equity' and is_active;
 if v_retained is null then raise exception 'Retained earnings account missing or inactive'; end if;
 for v_line in
  select a.id account_id,a.account_type,coalesce(sum(l.debit-l.credit),0)::numeric(20,2) net_debit
  from public.accounts a
  left join (
   select l.organization_id,l.account_id,l.debit,l.credit
   from public.journal_lines l join public.journal_entries j
    on j.organization_id=l.organization_id and j.id=l.journal_entry_id
   where l.organization_id=p_organization_id
   and j.entry_date between v_period.start_date and v_period.end_date
  ) l on l.organization_id=a.organization_id and l.account_id=a.id
  where a.organization_id=p_organization_id and a.account_type in ('revenue','expense')
  group by a.id,a.account_type
 loop
  if v_line.net_debit=0 then continue; end if;
  v_count:=v_count+1;
  if v_count>99 then raise exception 'Year-end has more than 99 income accounts; use grouped close posting';end if;
  v_net:=v_net+v_line.net_debit;
  v_lines:=v_lines||jsonb_build_array(jsonb_build_object('account_id',v_line.account_id,
    'debit',greatest(0,-v_line.net_debit),'credit',greatest(0,v_line.net_debit)));
 end loop;
 -- v_net = expenses minus revenues; balancing retained earnings line is net.
 if v_count>0 then
  if v_net<>0 then
   v_lines:=v_lines||jsonb_build_array(jsonb_build_object('account_id',v_retained,
    'debit',greatest(0,v_net),'credit',greatest(0,-v_net)));
  elsif v_count<2 then
   raise exception 'Closing with one nonzero account cannot balance';
  end if;
  v_journal:=private.post_accounting_journal_internal(
    'manual',p_organization_id,v_period.end_date,
    'Fiscal year close '||v_period.start_date||' to '||v_period.end_date,
    'YEAR-END',gen_random_uuid(),v_lines);
 end if;
 insert into public.year_end_closures(organization_id,fiscal_period_id,closing_journal_id,
  retained_earnings_account_id,closed_by)
 values(p_organization_id,p_period_id,v_journal,v_retained,auth.uid())
 returning id into v_close_id;
 update public.fiscal_periods set is_locked=true where id=p_period_id and organization_id=p_organization_id;
 perform private.write_audit(p_organization_id,'ledger.year_closed','year_end',v_close_id,
  jsonb_build_object('period_id',p_period_id,'closing_journal_id',v_journal,'net_income',-v_net));
 return jsonb_build_object('closure_id',v_close_id,'journal_id',v_journal,
   'net_income',-v_net,'already_closed',false);
end $$;

-- Closing journal cannot be reversed even in a later, open fiscal period.
alter function public.reverse_manual_journal(uuid,uuid,date,text)
 rename to reverse_manual_journal_legacy;
revoke all on function public.reverse_manual_journal_legacy(uuid,uuid,date,text)
 from public,anon,authenticated,service_role;
create function public.reverse_manual_journal(
 p_organization_id uuid,p_journal_id uuid,p_reversal_date date,p_reason text
) returns uuid language plpgsql security definer set search_path=''
as $$
begin
 if not public.has_org_write(p_organization_id) then raise exception 'Not authorized';end if;
 perform 1 from public.organizations where id=p_organization_id for update;
 if exists(select 1 from public.year_end_closures where organization_id=p_organization_id
  and closing_journal_id=p_journal_id)
 then raise exception 'Year-end close must be corrected through a formal restatement workflow';end if;
 return public.reverse_manual_journal_legacy(p_organization_id,p_journal_id,p_reversal_date,p_reason);
end $$;
revoke all on function public.close_financial_year(uuid,uuid),
 public.reverse_manual_journal(uuid,uuid,date,text) from public,anon;
grant execute on function public.close_financial_year(uuid,uuid),
 public.reverse_manual_journal(uuid,uuid,date,text) to authenticated;
revoke all on function private.seed_retained_earnings(),
 private.prevent_closed_year_reopen(),private.reject_closed_year_journal()
 from public,anon,authenticated;
