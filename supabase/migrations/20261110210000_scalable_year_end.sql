-- Milestone 6: distinct protected system-origin year-end postings with up to 10,000 lines.
-- Manual journals remain capped at 100 lines; document system journals at 202.
do $check$
declare v_name text;
begin
 for v_name in select c.conname from pg_constraint c
  where c.conrelid='public.journal_entries'::regclass
  and c.contype='c' and pg_get_constraintdef(c.oid) ilike '%source_kind%'
 loop
  execute format('alter table public.journal_entries drop constraint %I',v_name);
 end loop;
end $check$;
alter table public.journal_entries add constraint journal_entries_source_kind_check
 check(source_kind in ('manual','document','payment','reversal','year_end'));

create or replace function private.post_accounting_journal_internal(
 p_source_kind text,p_organization_id uuid,p_entry_date date,p_memo text,
 p_reference text,p_idempotency_key uuid,p_lines jsonb
) returns uuid language plpgsql security definer set search_path=''
as $$
declare v_id uuid; v_line jsonb; v_debit numeric; v_credit numeric;
 v_debits numeric(20,2):=0; v_credits numeric(20,2):=0;
 v_account uuid; v_count integer:=0; v_period uuid;
 v_fingerprint text; v_stored_fingerprint text;
begin
 if p_source_kind not in ('manual','document','payment','reversal','year_end') then
  raise exception 'Invalid posting origin'; end if;
 if not public.has_org_write(p_organization_id) then raise exception 'Not authorized to post'; end if;
 if p_entry_date is null or p_memo is null or char_length(trim(p_memo)) not between 3 and 500
 then raise exception 'Invalid journal header'; end if;
 if p_idempotency_key is null then raise exception 'Idempotency key required'; end if;
 if jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines)<2 or
   jsonb_array_length(p_lines)>(case when p_source_kind='document' then 202 when p_source_kind='year_end' then 10000 else 100 end)
 then raise exception 'Invalid number of journal lines for posting origin'; end if;
 v_fingerprint:=md5(p_source_kind||'|'||p_entry_date::text||'|'||trim(p_memo)||'|'||
  coalesce(nullif(trim(p_reference),''),'')||'|'||p_lines::text);
 perform 1 from public.organizations where id=p_organization_id for update;
 select id,posting_fingerprint into v_id,v_stored_fingerprint from public.journal_entries
 where organization_id=p_organization_id and source_kind=p_source_kind and idempotency_key=p_idempotency_key;
 if found then
  if v_stored_fingerprint is not null and v_stored_fingerprint<>v_fingerprint then
   raise exception 'Idempotency key reused with different posting details'; end if;
  return v_id;
 end if;
 select id into v_period from public.fiscal_periods
 where organization_id=p_organization_id and p_entry_date between start_date and end_date and not is_locked
 for update;
 if v_period is null then raise exception 'Accounting period is closed or missing'; end if;
 for v_line in select value from jsonb_array_elements(p_lines) loop
  if (v_line->>'account_id') is null then raise exception 'Missing account'; end if;
  v_account:=(v_line->>'account_id')::uuid;
  if not exists(select 1 from public.accounts where id=v_account and organization_id=p_organization_id and is_active)
  then raise exception 'Inactive or cross-tenant account'; end if;
  if exists(select 1 from public.bank_statements s where s.organization_id=p_organization_id
    and s.bank_account_id=v_account and s.status='reconciled' and p_entry_date<=s.end_date)
  then raise exception 'Posting would change a reconciled bank account history'; end if;
  v_debit:=(v_line->>'debit')::numeric;
  v_credit:=(v_line->>'credit')::numeric;
  if v_debit is null or v_credit is null or v_debit<0 or v_credit<0
   or (v_debit>0)=(v_credit>0) or round(v_debit,2)<>v_debit
   or round(v_credit,2)<>v_credit then
   raise exception 'Each line requires one positive debit or credit with cent precision';
  end if;
  v_debits:=v_debits+v_debit;v_credits:=v_credits+v_credit;v_count:=v_count+1;
 end loop;
 if v_count<2 or v_debits<=0 or v_debits<>v_credits then raise exception 'Journal must balance'; end if;
 insert into public.journal_entries(
 organization_id,entry_date,memo,reference,idempotency_key,source_kind,created_by,posting_fingerprint)
 values(p_organization_id,p_entry_date,trim(p_memo),nullif(trim(p_reference),''),
 p_idempotency_key,p_source_kind,auth.uid(),v_fingerprint) returning id into v_id;
 for v_line in select value from jsonb_array_elements(p_lines) loop
  insert into public.journal_lines(organization_id,journal_entry_id,account_id,debit,credit)
  values(p_organization_id,v_id,(v_line->>'account_id')::uuid,
   (v_line->>'debit')::numeric,(v_line->>'credit')::numeric);
 end loop;
 return v_id;
end $$;

revoke all on function private.post_accounting_journal_internal(text,uuid,date,text,text,uuid,jsonb)
 from public,anon,authenticated;

create or replace function public.close_financial_year(p_organization_id uuid,p_period_id uuid)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_actor_role text; v_period public.fiscal_periods%rowtype;
 v_retained uuid;v_line record;v_lines jsonb:='[]'::jsonb;
 v_net numeric(20,2):=0;v_net_debit numeric(20,2);
 v_journal uuid;v_close_id uuid;v_count integer:=0;
begin
 select role into v_actor_role from public.organization_members where
  organization_id=p_organization_id and user_id=auth.uid();
 if v_actor_role is null or v_actor_role not in ('owner','administrator','accountant') then
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
  if v_count>9999 then raise exception 'Year-end contains more than 9,999 accounts';end if;
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
    'year_end',p_organization_id,v_period.end_date,
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
revoke all on function public.close_financial_year(uuid,uuid) from public,anon;
grant execute on function public.close_financial_year(uuid,uuid) to authenticated;
