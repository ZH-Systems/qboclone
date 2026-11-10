-- Milestone 6: customer prepayments and allocation to posted invoices.
-- Deposits are liabilities, not recognized revenue. Allocation transfers deposits to AR.
insert into public.accounts(organization_id,code,name,account_type,normal_balance)
 select o.id,'2200','Customer Deposits','liability','credit' from public.organizations o
 where not exists(select 1 from public.accounts a where a.organization_id=o.id and a.code='2200');
create function private.seed_customer_deposit_account() returns trigger
language plpgsql set search_path=''
as $$
begin
 if new.code='2000' and new.account_type='liability' then
  insert into public.accounts(organization_id,code,name,account_type,normal_balance)
  values(new.organization_id,'2200','Customer Deposits','liability','credit')
  on conflict(organization_id,code) do nothing;
 end if;
 return new;
end $$;
create trigger seed_customer_deposit_account after insert on public.accounts
 for each row execute function private.seed_customer_deposit_account();

create table public.customer_deposits(
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null references public.organizations(id) on delete restrict,
 customer_id uuid not null,
 received_on date not null,
 amount numeric(20,2) not null check(amount>0),
 reference varchar(100),
 journal_entry_id uuid not null,
 idempotency_key uuid not null,
 created_by uuid not null references auth.users(id),
 created_at timestamptz not null default now(),
 unique(organization_id,id),unique(organization_id,idempotency_key),
 foreign key(organization_id,customer_id) references public.contacts(organization_id,id),
 foreign key(organization_id,journal_entry_id) references public.journal_entries(organization_id,id)
);
create table public.deposit_applications(
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null,
 deposit_id uuid not null,
 invoice_id uuid not null,
 applied_on date not null,
 amount numeric(20,2) not null check(amount>0),
 journal_entry_id uuid not null,
 idempotency_key uuid not null,
 created_by uuid not null references auth.users(id),
 created_at timestamptz not null default now(),
 unique(organization_id,id),unique(organization_id,idempotency_key),
 foreign key(organization_id,deposit_id) references public.customer_deposits(organization_id,id),
 foreign key(organization_id,invoice_id) references public.financial_documents(organization_id,id),
 foreign key(organization_id,journal_entry_id) references public.journal_entries(organization_id,id)
);
create table public.deposit_refunds(
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null,
 deposit_id uuid not null,
 refunded_on date not null,
 amount numeric(20,2) not null check(amount>0),
 journal_entry_id uuid not null,
 idempotency_key uuid not null,
 reason varchar(500) not null check(length(trim(reason)) between 3 and 500),
 created_by uuid not null references auth.users(id),
 created_at timestamptz not null default now(),
 unique(organization_id,id),unique(organization_id,idempotency_key),
 foreign key(organization_id,deposit_id) references public.customer_deposits(organization_id,id),
 foreign key(organization_id,journal_entry_id) references public.journal_entries(organization_id,id)
);
create index customer_deposits_customer_idx on public.customer_deposits(organization_id,customer_id);
create index deposit_applications_dep_idx on public.deposit_applications(organization_id,deposit_id);
create index deposit_applications_invoice_idx on public.deposit_applications(organization_id,invoice_id);
create index deposit_refunds_dep_idx on public.deposit_refunds(organization_id,deposit_id);
alter table public.customer_deposits enable row level security;
alter table public.deposit_applications enable row level security;
alter table public.deposit_refunds enable row level security;
create policy customer_deposits_read on public.customer_deposits for select to authenticated using(public.has_org_access(organization_id));
create policy deposit_applications_read on public.deposit_applications for select to authenticated using(public.has_org_access(organization_id));
create policy deposit_refunds_read on public.deposit_refunds for select to authenticated using(public.has_org_access(organization_id));
revoke all on public.customer_deposits,public.deposit_applications,public.deposit_refunds from public,anon,authenticated;
grant select on public.customer_deposits,public.deposit_applications,public.deposit_refunds to authenticated;

create function public.customer_deposit_available(p_organization_id uuid,p_deposit_id uuid)
returns numeric language sql stable security definer set search_path=''
as $$
 select greatest(0,d.amount-
   coalesce((select sum(a.amount) from public.deposit_applications a
    where a.organization_id=d.organization_id and a.deposit_id=d.id),0)-
   coalesce((select sum(r.amount) from public.deposit_refunds r
    where r.organization_id=d.organization_id and r.deposit_id=d.id),0))
 from public.customer_deposits d where d.organization_id=p_organization_id and d.id=p_deposit_id
 and public.has_org_access(d.organization_id)
$$;

create function public.receive_customer_deposit(
 p_organization_id uuid,p_customer_id uuid,p_received_on date,
 p_amount numeric,p_reference text,p_idempotency_key uuid
) returns uuid language plpgsql security definer set search_path=''
as $$
declare v_existing public.customer_deposits%rowtype;v_bank uuid;v_liability uuid;
 v_journal uuid;v_id uuid;
begin
 if not public.has_org_write(p_organization_id) then raise exception 'Not authorized';end if;
 if p_received_on is null or p_idempotency_key is null or p_amount is null
 or p_amount<=0 or scale(p_amount)>2 or length(coalesce(p_reference,''))>100
 then raise exception 'Invalid deposit request';end if;
 perform 1 from public.organizations where id=p_organization_id for update;
 select * into v_existing from public.customer_deposits where
 organization_id=p_organization_id and idempotency_key=p_idempotency_key;
 if found then
  if v_existing.customer_id<>p_customer_id or v_existing.received_on<>p_received_on
  or v_existing.amount<>p_amount or
   v_existing.reference is distinct from nullif(trim(p_reference),'')
  then raise exception 'Conflicting deposit idempotency replay';end if;
  return v_existing.id;
 end if;
 if not exists(select 1 from public.contacts where organization_id=p_organization_id
  and id=p_customer_id and contact_kind='customer')
 then raise exception 'Deposit requires a customer in this organization';end if;
 select id into v_bank from public.accounts where organization_id=p_organization_id
 and code='1000' and is_active;
 select id into v_liability from public.accounts where organization_id=p_organization_id
 and code='2200' and is_active;
 if v_bank is null or v_liability is null then raise exception 'Deposit accounts unavailable';end if;
 v_journal:=private.post_accounting_journal_internal('payment',p_organization_id,
  p_received_on,'Customer deposit received',left(coalesce(p_reference,'Deposit'),80),
  p_idempotency_key,jsonb_build_array(
   jsonb_build_object('account_id',v_bank,'debit',p_amount,'credit',0),
   jsonb_build_object('account_id',v_liability,'debit',0,'credit',p_amount)));
 insert into public.customer_deposits(organization_id,customer_id,received_on,amount,
 reference,journal_entry_id,idempotency_key,created_by)
 values(p_organization_id,p_customer_id,p_received_on,p_amount,
  nullif(trim(p_reference),''),v_journal,p_idempotency_key,auth.uid()) returning id into v_id;
 perform private.write_audit(p_organization_id,'deposit.received','customer_deposit',v_id,
  jsonb_build_object('amount',p_amount,'customer_id',p_customer_id));
 return v_id;
end $$;

create function public.apply_customer_deposit(
 p_organization_id uuid,p_deposit_id uuid,p_invoice_id uuid,
 p_amount numeric,p_applied_on date,p_idempotency_key uuid
) returns uuid language plpgsql security definer set search_path=''
as $$
declare d public.customer_deposits%rowtype;v_invoice public.financial_documents%rowtype;
 v_existing public.deposit_applications%rowtype;
 v_ar uuid;v_liability uuid;v_journal uuid;v_id uuid;
begin
 if not public.has_org_write(p_organization_id) then raise exception 'Not authorized';end if;
 if p_applied_on is null or p_idempotency_key is null or p_amount is null
 or p_amount<=0 or scale(p_amount)>2 then raise exception 'Invalid allocation';end if;
 perform 1 from public.organizations where id=p_organization_id for update;
 select * into v_existing from public.deposit_applications
  where organization_id=p_organization_id and idempotency_key=p_idempotency_key;
 if found then
  if v_existing.deposit_id<>p_deposit_id or v_existing.invoice_id<>p_invoice_id or
    v_existing.amount<>p_amount or v_existing.applied_on<>p_applied_on then
    raise exception 'Conflicting allocation replay';end if;
  return v_existing.id;
 end if;
 select * into d from public.customer_deposits
 where organization_id=p_organization_id and id=p_deposit_id for update;
 if not found then raise exception 'Customer deposit not found';end if;
 select * into v_invoice from public.financial_documents
 where organization_id=p_organization_id and id=p_invoice_id and status='posted'
 and document_type='invoice' for update;
 if not found or v_invoice.contact_id<>d.customer_id then
   raise exception 'Deposit can only be applied to a posted invoice for the same customer';end if;
 if p_applied_on<d.received_on or p_applied_on<v_invoice.issue_date then
   raise exception 'Allocation date must follow the deposit receipt and invoice issue dates';end if;
 if p_amount>public.customer_deposit_available(p_organization_id,p_deposit_id) then
   raise exception 'Allocation exceeds remaining customer deposit';end if;
 if p_amount>public.document_outstanding(p_organization_id,p_invoice_id) then
   raise exception 'Allocation exceeds outstanding invoice balance';end if;
 select id into v_ar from public.accounts where organization_id=p_organization_id and code='1100' and is_active;
 select id into v_liability from public.accounts where organization_id=p_organization_id and code='2200' and is_active;
 if v_ar is null or v_liability is null then raise exception 'Allocation accounts unavailable';end if;
 v_journal:=private.post_accounting_journal_internal('payment',p_organization_id,
 p_applied_on,'Apply customer deposit to '||v_invoice.document_number,'DEPOSIT-APPLY',
 p_idempotency_key,jsonb_build_array(
  jsonb_build_object('account_id',v_liability,'debit',p_amount,'credit',0),
  jsonb_build_object('account_id',v_ar,'debit',0,'credit',p_amount)));
 insert into public.deposit_applications(organization_id,deposit_id,invoice_id,applied_on,
  amount,journal_entry_id,idempotency_key,created_by)
 values(p_organization_id,p_deposit_id,p_invoice_id,p_applied_on,p_amount,
  v_journal,p_idempotency_key,auth.uid()) returning id into v_id;
 perform private.write_audit(p_organization_id,'deposit.allocated','deposit_application',v_id,
  jsonb_build_object('invoice_id',p_invoice_id,'amount',p_amount));
 return v_id;
end $$;

create function public.refund_customer_deposit(
 p_organization_id uuid,p_deposit_id uuid,p_amount numeric,p_refunded_on date,
 p_reason text,p_idempotency_key uuid
) returns uuid language plpgsql security definer set search_path=''
as $$
declare d public.customer_deposits%rowtype;v_existing public.deposit_refunds%rowtype;
 v_bank uuid;v_liability uuid;v_journal uuid;v_id uuid;
begin
 if not public.has_org_write(p_organization_id) then raise exception 'Not authorized';end if;
 if p_idempotency_key is null or p_refunded_on is null or p_amount is null or p_amount<=0
 or scale(p_amount)>2 or p_reason is null or length(trim(p_reason)) not between 3 and 500
 then raise exception 'Invalid deposit refund';end if;
 perform 1 from public.organizations where id=p_organization_id for update;
 select * into v_existing from public.deposit_refunds
  where organization_id=p_organization_id and idempotency_key=p_idempotency_key;
 if found then
  if v_existing.deposit_id<>p_deposit_id or v_existing.amount<>p_amount
  or v_existing.refunded_on<>p_refunded_on or v_existing.reason<>trim(p_reason)
  then raise exception 'Conflicting deposit refund replay';end if;
  return v_existing.id;
 end if;
 select * into d from public.customer_deposits
 where organization_id=p_organization_id and id=p_deposit_id for update;
 if not found then raise exception 'Deposit not found';end if;
 if p_refunded_on<d.received_on then raise exception 'Refund cannot precede original deposit';end if;
 if p_amount>public.customer_deposit_available(p_organization_id,p_deposit_id)
 then raise exception 'Refund exceeds unallocated customer deposit';end if;
 select id into v_bank from public.accounts where organization_id=p_organization_id
 and code='1000' and is_active;
 select id into v_liability from public.accounts where organization_id=p_organization_id
 and code='2200' and is_active;
 if v_bank is null or v_liability is null then raise exception 'Deposit accounts unavailable';end if;
 v_journal:=private.post_accounting_journal_internal('reversal',p_organization_id,
 p_refunded_on,'Refund customer deposit',left(trim(p_reason),80),
 p_idempotency_key,jsonb_build_array(
  jsonb_build_object('account_id',v_liability,'debit',p_amount,'credit',0),
  jsonb_build_object('account_id',v_bank,'debit',0,'credit',p_amount)));
 insert into public.deposit_refunds(organization_id,deposit_id,refunded_on,amount,reason,
  journal_entry_id,idempotency_key,created_by)
 values(p_organization_id,p_deposit_id,p_refunded_on,p_amount,trim(p_reason),
   v_journal,p_idempotency_key,auth.uid()) returning id into v_id;
 perform private.write_audit(p_organization_id,'deposit.refunded','deposit_refund',v_id,
  jsonb_build_object('deposit_id',p_deposit_id,'amount',p_amount));
 return v_id;
end $$;

revoke all on function public.customer_deposit_available(uuid,uuid),
 public.receive_customer_deposit(uuid,uuid,date,numeric,text,uuid),
 public.apply_customer_deposit(uuid,uuid,uuid,numeric,date,uuid),
 public.refund_customer_deposit(uuid,uuid,numeric,date,text,uuid) from public,anon;
grant execute on function public.customer_deposit_available(uuid,uuid),
 public.receive_customer_deposit(uuid,uuid,date,numeric,text,uuid),
 public.apply_customer_deposit(uuid,uuid,uuid,numeric,date,uuid),
 public.refund_customer_deposit(uuid,uuid,numeric,date,text,uuid) to authenticated;
revoke all on function private.seed_customer_deposit_account() from public,anon,authenticated;

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
       where w.organization_id=d.organization_id and w.document_id=d.id),0)-
    coalesce((select sum(ap.amount) from public.deposit_applications ap
       where ap.organization_id=d.organization_id and ap.invoice_id=d.id),0))
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
        and w.entry_date<=p_as_of),0)
    -coalesce((select sum(ap.amount) from public.deposit_applications ap
      where ap.organization_id=d.organization_id and ap.invoice_id=d.id
        and ap.applied_on<=p_as_of),0))::numeric balance
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



-- Refund/receipt/allocation journals are source-linked and may not be reversed
-- by the manual reversal API, which would desynchronize balances.
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
 or exists(select 1 from public.customer_deposits where organization_id=p_organization_id and journal_entry_id=p_journal_id)
 or exists(select 1 from public.deposit_applications where organization_id=p_organization_id and journal_entry_id=p_journal_id)
 or exists(select 1 from public.deposit_refunds where organization_id=p_organization_id and journal_entry_id=p_journal_id)
 then raise exception 'Source accounting journal cannot be manually reversed';end if;
 return public.reverse_manual_journal_legacy(p_organization_id,p_journal_id,p_reversal_date,p_reason);
end $$;
