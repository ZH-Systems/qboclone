-- Milestone 6: post-closing financial statements, historical aging and adjusting journals.
create table public.accounting_adjustments(
 organization_id uuid not null references public.organizations(id) on delete restrict,
 journal_entry_id uuid not null,
 category text not null check(category in ('accrual','deferral','reclassification','correction','other')),
 explanation text not null check(length(trim(explanation)) between 10 and 500),
 created_at timestamptz not null default now(),
 created_by uuid not null references auth.users(id),
 primary key(organization_id,journal_entry_id),
 foreign key(organization_id,journal_entry_id) references public.journal_entries(organization_id,id)
);
alter table public.accounting_adjustments enable row level security;
create policy accounting_adjustments_read on public.accounting_adjustments for select to authenticated
 using(public.has_org_access(organization_id));
revoke all on public.accounting_adjustments from public,anon,authenticated;
grant select on public.accounting_adjustments to authenticated;

create function public.post_adjusting_journal(
 p_organization_id uuid,p_entry_date date,p_category text,p_explanation text,
 p_idempotency_key uuid,p_lines jsonb
) returns uuid language plpgsql security definer set search_path=''
as $$
declare v_role text;v_journal uuid;
begin
 select role into v_role from public.organization_members
 where organization_id=p_organization_id and user_id=auth.uid();
 if v_role not in ('owner','administrator','accountant') then
  raise exception 'Only an owner, administrator or accountant can post adjusting entries';end if;
 if p_category not in ('accrual','deferral','reclassification','correction','other')
 or p_explanation is null or length(trim(p_explanation)) not between 10 and 500
 then raise exception 'Adjustment requires category and detailed explanation';end if;
 perform 1 from public.organizations where id=p_organization_id for update;
 v_journal:=public.post_journal(p_organization_id,p_entry_date,
  left('Adjustment: '||trim(p_explanation),500),
  'ADJUSTMENT',p_idempotency_key,p_lines);
 insert into public.accounting_adjustments(
  organization_id,journal_entry_id,category,explanation,created_by)
 values(p_organization_id,v_journal,p_category,trim(p_explanation),auth.uid())
 on conflict (organization_id,journal_entry_id) do nothing;
 perform private.write_audit(p_organization_id,'ledger.adjustment_posted','journal',v_journal,
  jsonb_build_object('category',p_category));
 return v_journal;
end $$;

-- P&L includes operational income/expense entries but excludes the special
-- clearing journal from each year-end close. Prior years remain reportable.
create or replace function public.ledger_profit_loss(
 p_organization_id uuid,p_from date,p_through date
) returns table(account_code text,account_name text,account_type text,amount numeric)
language plpgsql stable security definer set search_path=''
as $$
begin
 if not public.has_org_access(p_organization_id) then raise exception 'Not authorized';end if;
 if p_from is null or p_through is null or p_from>p_through then
  raise exception 'Invalid report dates';end if;
 return query
 select a.code::text,a.name::text,a.account_type::text,
  coalesce(sum(case when a.account_type='revenue'
    then l.credit-l.debit else l.debit-l.credit end),0)::numeric
 from public.accounts a
 left join (
  select l.organization_id,l.account_id,l.debit,l.credit
  from public.journal_lines l join public.journal_entries j
    on j.organization_id=l.organization_id and j.id=l.journal_entry_id
  where l.organization_id=p_organization_id
    and j.entry_date between p_from and p_through
    and not exists(select 1 from public.year_end_closures y
       where y.organization_id=l.organization_id and y.closing_journal_id=l.journal_entry_id)
 ) l on l.organization_id=a.organization_id and l.account_id=a.id
 where a.organization_id=p_organization_id and a.account_type in ('revenue','expense')
 group by a.code,a.name,a.account_type order by a.code;
end $$;

-- Canonical balance sheet: normal-side balances plus separately disclosed
-- unclosed earnings. Do not include net income a second time after year end.
create function public.ledger_balance_sheet(p_organization_id uuid,p_through date)
returns table(account_code text,account_name text,category text,amount numeric)
language plpgsql stable security definer set search_path=''
as $$
begin
 if not public.has_org_access(p_organization_id) then raise exception 'Not authorized';end if;
 if p_through is null then raise exception 'Balance-sheet date required';end if;
 return query
 with balances as (
  select * from public.ledger_trial_balance(p_organization_id,p_through)
 ), account_rows as (
  select b.account_code,b.account_name,b.account_type category,
   (case when b.account_type='asset' then b.net_debit else -b.net_debit end)::numeric amount
  from balances b where b.account_type in ('asset','liability','equity')
 ), earnings as (
  select coalesce(sum(case when b.account_type='revenue' then -b.net_debit
    else -b.net_debit end),0)::numeric amount
  from balances b where b.account_type in ('revenue','expense')
 )
 select a.account_code,a.account_name,a.category,a.amount from account_rows a
 union all
 select 'EARNINGS'::text,'Unclosed earnings'::text,'equity'::text,e.amount from earnings e
 order by account_code;
end $$;

-- Historical aging must use payment/refund/credit dates as of p_as_of,
-- not the current outstanding value of a document.
create function public.aged_open_documents(
 p_organization_id uuid,p_as_of date,p_kind text
) returns table(document_id uuid,document_number text,contact_name text,due_date date,
 outstanding numeric,days_past_due integer,aging_bucket text)
language plpgsql stable security definer set search_path=''
as $$
begin
 if not public.has_org_access(p_organization_id) then raise exception 'Not authorized';end if;
 if p_as_of is null or p_kind not in ('invoice','bill') then
  raise exception 'Aging report requires a date and invoice or bill kind';end if;
 return query
 with open_amounts as (
  select d.id,d.document_number::text,c.display_name::text,d.due_date,
   (d.total
    -coalesce((select sum(p.amount) from public.document_payments p
      where p.organization_id=d.organization_id and p.document_id=d.id
        and p.payment_date<=p_as_of),0)
    +coalesce((select sum(r.amount) from public.payment_refunds r
      join public.document_payments p
      on p.organization_id=r.organization_id and p.id=r.original_payment_id
      where p.organization_id=d.organization_id and p.document_id=d.id
       and r.refund_date<=p_as_of),0)
    -coalesce((select sum(cr.total) from public.financial_documents cr
      where cr.organization_id=d.organization_id and cr.source_document_id=d.id
       and cr.status='posted' and cr.issue_date<=p_as_of),0))::numeric balance
  from public.financial_documents d
  join public.contacts c on c.organization_id=d.organization_id and c.id=d.contact_id
  where d.organization_id=p_organization_id and d.document_type=p_kind
    and d.status='posted' and d.issue_date<=p_as_of
 )
 select o.id,o.document_number,o.display_name,o.due_date,
   o.balance,(p_as_of-o.due_date)::integer,
   case when p_as_of<=o.due_date then 'current'
    when p_as_of-o.due_date<=30 then '1_30'
    when p_as_of-o.due_date<=60 then '31_60'
    when p_as_of-o.due_date<=90 then '61_90' else '90_plus' end::text
 from open_amounts o where o.balance>0 order by o.due_date,o.document_number;
end $$;

-- Cash movement overview is NOT a formal cash flow statement, since it does
-- not classify operating, investing and financing flows.
create function public.bank_cash_movement(
 p_organization_id uuid,p_from date,p_through date
) returns table(bank_account_id uuid,account_code text,account_name text,
 opening_balance numeric,inflows numeric,outflows numeric,closing_balance numeric)
language plpgsql stable security definer set search_path=''
as $$
begin
 if not public.has_org_access(p_organization_id) then raise exception 'Not authorized';end if;
 if p_from is null or p_through is null or p_from>p_through then
  raise exception 'Invalid cash movement dates';end if;
 return query
 select a.id,a.code::text,a.name::text,
 coalesce(sum(l.debit-l.credit) filter(where j.entry_date<p_from),0)::numeric,
 coalesce(sum(l.debit) filter(where j.entry_date between p_from and p_through),0)::numeric,
 coalesce(sum(l.credit) filter(where j.entry_date between p_from and p_through),0)::numeric,
 coalesce(sum(l.debit-l.credit) filter(where j.entry_date<=p_through),0)::numeric
 from public.accounts a
 left join public.journal_lines l on l.account_id=a.id and l.organization_id=a.organization_id
 left join public.journal_entries j on j.id=l.journal_entry_id and j.organization_id=l.organization_id
 where a.organization_id=p_organization_id and a.is_bank_account
 group by a.id,a.code,a.name order by a.code;
end $$;

revoke all on function public.post_adjusting_journal(uuid,date,text,text,uuid,jsonb),
 public.ledger_balance_sheet(uuid,date),public.aged_open_documents(uuid,date,text),
 public.bank_cash_movement(uuid,date,date) from public,anon;
grant execute on function public.post_adjusting_journal(uuid,date,text,text,uuid,jsonb),
 public.ledger_balance_sheet(uuid,date),public.aged_open_documents(uuid,date,text),
 public.bank_cash_movement(uuid,date,date) to authenticated;
