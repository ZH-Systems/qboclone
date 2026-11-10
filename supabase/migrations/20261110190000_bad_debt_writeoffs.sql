-- Milestone 6: controlled customer bad-debt writeoffs. This does not
-- automatically adjust GST/HST for statutory bad-debt recovery provisions.
insert into public.accounts(organization_id,code,name,account_type,normal_balance)
select o.id,'5100','Bad Debt Expense','expense','debit'
from public.organizations o where not exists(
 select 1 from public.accounts a where a.organization_id=o.id and a.code='5100'
);
create function private.seed_bad_debt_account() returns trigger
language plpgsql set search_path=''
as $$
begin
 if new.code='5000' and new.account_type='expense' then
  insert into public.accounts(organization_id,code,name,account_type,normal_balance)
  values(new.organization_id,'5100','Bad Debt Expense','expense','debit')
  on conflict(organization_id,code) do nothing;
 end if;
 return new;
end $$;
create trigger seed_bad_debt after insert on public.accounts
 for each row execute function private.seed_bad_debt_account();

create table public.document_writeoffs(
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null references public.organizations(id) on delete restrict,
 document_id uuid not null,
 entry_date date not null,
 amount numeric(20,2) not null check(amount>0),
 reason varchar(500) not null check(length(trim(reason)) between 10 and 500),
 journal_entry_id uuid not null,
 idempotency_key uuid not null,
 created_by uuid not null references auth.users(id),
 created_at timestamptz not null default now(),
 unique(organization_id,id),
 unique(organization_id,idempotency_key),
 foreign key(organization_id,document_id) references public.financial_documents(organization_id,id),
 foreign key(organization_id,journal_entry_id) references public.journal_entries(organization_id,id)
);
create index document_writeoffs_org_doc_idx on public.document_writeoffs(organization_id,document_id);
alter table public.document_writeoffs enable row level security;
create policy document_writeoffs_read on public.document_writeoffs
 for select to authenticated using(public.has_org_access(organization_id));
revoke all on public.document_writeoffs from public,anon,authenticated;
grant select on public.document_writeoffs to authenticated;

create function public.writeoff_unpaid_invoice(
 p_organization_id uuid,p_invoice_id uuid,p_amount numeric,p_entry_date date,
 p_reason text,p_idempotency_key uuid
) returns uuid language plpgsql security definer set search_path=''
as $$
declare d public.financial_documents%rowtype;v_prev public.document_writeoffs%rowtype;
 v_bad_debt uuid;v_ar uuid;v_journal uuid;v_id uuid;
begin
 if not public.has_org_write(p_organization_id) then raise exception 'Not authorized';end if;
 if p_entry_date is null or p_idempotency_key is null or p_amount is null or
  p_amount<=0 or scale(p_amount)>2 or p_reason is null or length(trim(p_reason)) not between 10 and 500
 then raise exception 'Invalid writeoff details';end if;
 perform 1 from public.organizations where id=p_organization_id for update;
 select * into v_prev from public.document_writeoffs where
  organization_id=p_organization_id and idempotency_key=p_idempotency_key;
 if found then
  if v_prev.document_id<>p_invoice_id or v_prev.entry_date<>p_entry_date or
   v_prev.amount<>p_amount or v_prev.reason<>trim(p_reason) then
   raise exception 'Writeoff idempotency key reused with different details';end if;
  return v_prev.id;
 end if;
 select * into d from public.financial_documents where
  organization_id=p_organization_id and id=p_invoice_id and status='posted'
  and document_type='invoice' for update;
 if not found then raise exception 'Only posted customer invoices can be written off';end if;
 if p_amount>public.document_outstanding(p_organization_id,p_invoice_id)
 then raise exception 'Writeoff exceeds outstanding receivable';end if;
 select id into v_bad_debt from public.accounts where organization_id=p_organization_id
  and code='5100' and is_active and account_type='expense';
 select id into v_ar from public.accounts where organization_id=p_organization_id
  and code='1100' and is_active;
 if v_bad_debt is null or v_ar is null then raise exception 'Bad debt or AR account unavailable';end if;
 v_journal:=private.post_accounting_journal_internal('reversal',p_organization_id,
 p_entry_date,'Bad debt writeoff: '||d.document_number,left(trim(p_reason),80),
 p_idempotency_key,jsonb_build_array(
  jsonb_build_object('account_id',v_bad_debt,'debit',p_amount,'credit',0),
  jsonb_build_object('account_id',v_ar,'debit',0,'credit',p_amount)));
 insert into public.document_writeoffs(organization_id,document_id,entry_date,amount,
  reason,journal_entry_id,idempotency_key,created_by)
 values(p_organization_id,p_invoice_id,p_entry_date,p_amount,trim(p_reason),
   v_journal,p_idempotency_key,auth.uid()) returning id into v_id;
 perform private.write_audit(p_organization_id,'document.bad_debt_written_off',
  'document_writeoff',v_id,jsonb_build_object('document_id',p_invoice_id,'amount',p_amount));
 return v_id;
end $$;
revoke all on function public.writeoff_unpaid_invoice(uuid,uuid,numeric,date,text,uuid) from public,anon;
grant execute on function public.writeoff_unpaid_invoice(uuid,uuid,numeric,date,text,uuid) to authenticated;
revoke all on function private.seed_bad_debt_account() from public,anon,authenticated;

create or replace function public.document_outstanding(p_organization_id uuid,p_document_id uuid)
returns numeric language sql stable security definer set search_path=''
as $$
 select case when d.document_type in ('invoice','bill') and d.status='posted' then
  greatest(0,d.total-
    coalesce((select sum(p.amount) from public.document_payments p
       where p.organization_id=d.organization_id and p.document_id=d.id),0)+
    coalesce((select sum(r.amount) from public.payment_refunds r
       join public.document_payments p on p.organization_id=r.organization_id and p.id=r.original_payment_id
       where p.organization_id=d.organization_id and p.document_id=d.id),0)-
    coalesce((select sum(c.total) from public.financial_documents c
       where c.organization_id=d.organization_id and c.source_document_id=d.id
         and c.status='posted' and c.document_type in ('credit_note','vendor_credit')),0)-
    coalesce((select sum(w.amount) from public.document_writeoffs w
       where w.organization_id=d.organization_id and w.document_id=d.id),0))
 else 0 end
 from public.financial_documents d
 where d.organization_id=p_organization_id and d.id=p_document_id
   and public.has_org_access(d.organization_id)
$$;

create or replace function public.aged_open_documents(
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
       and cr.status='posted' and cr.issue_date<=p_as_of),0)
    -coalesce((select sum(w.amount) from public.document_writeoffs w
      where w.organization_id=d.organization_id and w.document_id=d.id
        and w.entry_date<=p_as_of),0))::numeric balance
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


-- Source writeoff journals must never be reversed through manual journal UI.
create or replace function public.reverse_manual_journal(
 p_organization_id uuid,p_journal_id uuid,p_reversal_date date,p_reason text
) returns uuid language plpgsql security definer set search_path=''
as $$
begin
 if not public.has_org_write(p_organization_id) then raise exception 'Not authorized';end if;
 perform 1 from public.organizations where id=p_organization_id for update;
 if exists(select 1 from public.year_end_closures where organization_id=p_organization_id and closing_journal_id=p_journal_id)
 or exists(select 1 from public.payment_refunds where organization_id=p_organization_id and journal_entry_id=p_journal_id)
 or exists(select 1 from public.document_writeoffs where organization_id=p_organization_id and journal_entry_id=p_journal_id)
 then raise exception 'Source financial journals cannot be reversed manually';end if;
 return public.reverse_manual_journal_legacy(p_organization_id,p_journal_id,p_reversal_date,p_reason);
end $$;
