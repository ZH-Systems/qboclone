-- Phase 2: transactional sales, purchasing, credits, payments, reversals, and complete-ledger reports.
-- Requires 20261110000000_ledger_foundation.sql.
-- DEV/QA ONLY until an accounting professional validates the accounting policy and tax treatment.
-- CAUTION: tax rates are manually entered estimates. This is NOT a CRA tax engine.

-- Separate system posting namespaces from caller-controlled manual journal keys.
alter table public.journal_entries add column source_kind text not null default 'manual'
  check(source_kind in ('manual','document','payment','reversal'));
alter table public.journal_entries drop constraint journal_entries_organization_id_idempotency_key_key;
alter table public.journal_entries add constraint journal_entries_tenant_source_idempotency_key
  unique(organization_id,source_kind,idempotency_key);
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create function private.post_accounting_journal_internal(
  p_source_kind text,
  p_organization_id uuid,
  p_entry_date date,
  p_memo text,
  p_reference text,
  p_idempotency_key uuid,
  p_lines jsonb
) returns uuid
language plpgsql security definer set search_path = ''
as $
declare v_id uuid; v_line jsonb; v_debit numeric; v_credit numeric;
        v_debits numeric(20,2) := 0; v_credits numeric(20,2) := 0;
        v_account uuid; v_count integer := 0; v_period uuid;
begin
  if p_source_kind not in ('manual','document','payment','reversal') then raise exception 'Invalid posting origin'; end if;
  if not public.has_org_write(p_organization_id) then raise exception 'Not authorized to post'; end if;
  if p_entry_date is null or p_memo is null or char_length(trim(p_memo)) not between 3 and 500 then raise exception 'Invalid journal header'; end if;
  if p_idempotency_key is null then raise exception 'Idempotency key is required'; end if;
  if jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines) not between 2 and 100 then raise exception 'Journal must contain 2 to 100 lines'; end if;
  -- Lock the organization to serialize same-tenant posting and period changes.
  perform 1 from public.organizations where id=p_organization_id for update;
  select id into v_id from public.journal_entries where organization_id=p_organization_id and source_kind=p_source_kind and idempotency_key=p_idempotency_key;
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
  insert into public.journal_entries(organization_id,entry_date,memo,reference,idempotency_key,source_kind,created_by)
    values(p_organization_id,p_entry_date,trim(p_memo),nullif(trim(p_reference),''),p_idempotency_key,p_source_kind,auth.uid())
    returning id into v_id;
  for v_line in select value from jsonb_array_elements(p_lines)
  loop
    insert into public.journal_lines(organization_id,journal_entry_id,account_id,debit,credit)
    values(p_organization_id,v_id,(v_line->>'account_id')::uuid,(v_line->>'debit')::numeric,(v_line->>'credit')::numeric);
  end loop;
  return v_id;
end $;

revoke all on function private.post_accounting_journal_internal(text,uuid,date,text,text,uuid,jsonb)
  from public,anon,authenticated;

-- Public RPC can only create manual-origin journals.
create or replace function public.post_journal(
  p_organization_id uuid,p_entry_date date,p_memo text,p_reference text,
  p_idempotency_key uuid,p_lines jsonb
) returns uuid language sql security definer set search_path=''
as $
  select private.post_accounting_journal_internal(
    'manual',p_organization_id,p_entry_date,p_memo,p_reference,p_idempotency_key,p_lines);
$;

alter table public.organizations add column if not exists document_sequence bigint not null default 0;
insert into public.accounts(organization_id,code,name,account_type,normal_balance)
select o.id,'1300','Sales Tax Recoverable','asset','debit'
from public.organizations o
where not exists(select 1 from public.accounts a where a.organization_id=o.id and a.code='1300');

create or replace function public.create_organization(p_name text) returns uuid
language plpgsql security definer set search_path = ''
as $$
declare v_id uuid; v_user uuid := auth.uid(); v_year integer := extract(year from current_date);
begin
  if v_user is null then raise exception 'Authentication required'; end if;
  if p_name is null or char_length(trim(p_name)) not between 2 and 150 then
    raise exception 'Business name must contain 2 to 150 characters';
  end if;
  insert into public.organizations(name) values(trim(p_name)) returning id into v_id;
  insert into public.organization_members(organization_id,user_id,role) values(v_id,v_user,'owner');
  insert into public.fiscal_periods(organization_id,start_date,end_date)
    values(v_id,make_date(v_year,1,1),make_date(v_year,12,31));
  insert into public.accounts(organization_id,code,name,account_type,normal_balance) values
    (v_id,'1000','Operating Bank','asset','debit'),
    (v_id,'1100','Accounts Receivable','asset','debit'),
    (v_id,'1200','Undeposited Funds','asset','debit'),
    (v_id,'1300','Sales Tax Recoverable','asset','debit'),
    (v_id,'2000','Accounts Payable','liability','credit'),
    (v_id,'2100','GST/HST Payable','liability','credit'),
    (v_id,'3000','Owner Equity','equity','credit'),
    (v_id,'4000','Sales Revenue','revenue','credit'),
    (v_id,'5000','Operating Expenses','expense','debit');
  return v_id;
end $$;

create table public.contacts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  contact_kind text not null check(contact_kind in ('customer','vendor')),
  display_name varchar(180) not null check(length(trim(display_name)) between 2 and 180),
  email varchar(255),
  created_at timestamptz not null default now(),
  unique(organization_id,id)
);
create index contacts_org_kind_idx on public.contacts(organization_id,contact_kind);

create table public.financial_documents (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  contact_id uuid not null,
  document_type text not null check(document_type in ('invoice','bill','credit_note','vendor_credit')),
  document_number text not null,
  issue_date date not null,
  due_date date not null,
  memo varchar(500) not null default '',
  status text not null default 'draft' check(status in ('draft','posted')),
  source_document_id uuid,
  subtotal numeric(20,2) not null default 0 check(subtotal>=0),
  tax_total numeric(20,2) not null default 0 check(tax_total>=0),
  total numeric(20,2) generated always as (subtotal + tax_total) stored,
  journal_entry_id uuid,
  posted_at timestamptz,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  unique(organization_id,id),
  unique(organization_id,document_number),
  foreign key(organization_id,contact_id) references public.contacts(organization_id,id),
  foreign key(organization_id,source_document_id) references public.financial_documents(organization_id,id),
  foreign key(organization_id,journal_entry_id) references public.journal_entries(organization_id,id),
  check(due_date>=issue_date),
  check(
    (status='draft' and journal_entry_id is null and posted_at is null)
    or (status='posted' and journal_entry_id is not null and posted_at is not null)
  ),
  check (
    (document_type in ('invoice','bill') and source_document_id is null)
    or (document_type in ('credit_note','vendor_credit') and source_document_id is not null)
  )
);
create index financial_docs_org_date_idx on public.financial_documents(organization_id,issue_date desc);

create table public.financial_document_lines (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  document_id uuid not null,
  position integer not null check(position between 1 and 100),
  description varchar(250) not null check(length(trim(description)) between 1 and 250),
  quantity numeric(12,3) not null check(quantity>0 and quantity<=1000000),
  unit_price numeric(20,2) not null check(unit_price>=0),
  tax_rate_bps integer not null check(tax_rate_bps between 0 and 2500),
  amount numeric(20,2) not null check(amount>=0),
  tax_amount numeric(20,2) not null check(tax_amount>=0),
  foreign key(organization_id,document_id) references public.financial_documents(organization_id,id) on delete restrict,
  unique(organization_id,document_id,position)
);

create table public.document_payments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  document_id uuid not null,
  amount numeric(20,2) not null check(amount>0),
  payment_date date not null,
  reference varchar(100),
  idempotency_key uuid not null,
  journal_entry_id uuid not null,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  foreign key(organization_id,document_id) references public.financial_documents(organization_id,id),
  foreign key(organization_id,journal_entry_id) references public.journal_entries(organization_id,id),
  unique(organization_id,idempotency_key)
);
create index doc_payments_document_idx on public.document_payments(organization_id,document_id);

create table public.journal_reversals (
  organization_id uuid not null,
  original_journal_id uuid not null,
  reversing_journal_id uuid not null,
  reason varchar(500) not null check(length(trim(reason))>=3),
  reversed_at timestamptz not null default now(),
  reversed_by uuid not null references auth.users(id),
  primary key(organization_id,original_journal_id),
  unique(organization_id,reversing_journal_id),
  foreign key(organization_id,original_journal_id) references public.journal_entries(organization_id,id),
  foreign key(organization_id,reversing_journal_id) references public.journal_entries(organization_id,id),
  check(original_journal_id<>reversing_journal_id)
);

alter table public.contacts enable row level security;
alter table public.financial_documents enable row level security;
alter table public.financial_document_lines enable row level security;
alter table public.document_payments enable row level security;
alter table public.journal_reversals enable row level security;
create policy contacts_visible on public.contacts for select to authenticated using(public.has_org_access(organization_id));
create policy financial_docs_visible on public.financial_documents for select to authenticated using(public.has_org_access(organization_id));
create policy financial_lines_visible on public.financial_document_lines for select to authenticated using(public.has_org_access(organization_id));
create policy doc_payments_visible on public.document_payments for select to authenticated using(public.has_org_access(organization_id));
create policy journal_reversals_visible on public.journal_reversals for select to authenticated using(public.has_org_access(organization_id));
revoke all on public.contacts,public.financial_documents,public.financial_document_lines,
  public.document_payments,public.journal_reversals from public,anon,authenticated;
grant select on public.contacts,public.financial_documents,public.financial_document_lines,
  public.document_payments,public.journal_reversals to authenticated;

create function public.create_contact(p_organization_id uuid,p_kind text,p_name text,p_email text default null)
returns uuid language plpgsql security definer set search_path=''
as $$
declare v_id uuid;
begin
  if not public.has_org_write(p_organization_id) then raise exception 'Not authorized'; end if;
  if p_kind not in ('customer','vendor') then raise exception 'Invalid contact kind'; end if;
  if p_name is null or length(trim(p_name)) not between 2 and 180 then raise exception 'Invalid name'; end if;
  if p_email is not null and (length(p_email)>255 or p_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$') then raise exception 'Invalid email'; end if;
  insert into public.contacts(organization_id,contact_kind,display_name,email)
  values(p_organization_id,p_kind,trim(p_name),nullif(trim(p_email),'')) returning id into v_id;
  return v_id;
end $$;

-- A document's lines, totals, contact, and tax snapshots are created atomically.
-- The client cannot edit database documents directly; a draft can be discarded and recreated.
create function public.create_financial_document(
  p_organization_id uuid,p_contact_id uuid,p_type text,p_issue_date date,
  p_due_date date,p_memo text,p_source_document_id uuid,p_lines jsonb
) returns uuid language plpgsql security definer set search_path=''
as $$
declare v_id uuid; v_source public.financial_documents%rowtype;
  v_line jsonb; v_qty numeric; v_price numeric; v_rate integer; v_amount numeric(20,2);
  v_tax numeric(20,2); v_subtotal numeric(20,2):=0; v_taxes numeric(20,2):=0;
  v_position integer:=0; v_seq bigint; v_kind text;
begin
  if not public.has_org_write(p_organization_id) then raise exception 'Not authorized'; end if;
  if p_type not in ('invoice','bill','credit_note','vendor_credit') then raise exception 'Invalid document type'; end if;
  if p_issue_date is null or p_due_date is null or p_due_date<p_issue_date then raise exception 'Invalid dates'; end if;
  if length(coalesce(p_memo,''))>500 then raise exception 'Memo too long'; end if;
  if jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines) not between 1 and 100 then
    raise exception 'Document requires 1 to 100 lines';
  end if;
  v_kind:=case when p_type in ('invoice','credit_note') then 'customer' else 'vendor' end;
  if not exists(select 1 from public.contacts where id=p_contact_id and organization_id=p_organization_id and contact_kind=v_kind) then
    raise exception 'Contact does not match document type or tenant';
  end if;
  if p_type in ('credit_note','vendor_credit') then
    select * into v_source from public.financial_documents
    where id=p_source_document_id and organization_id=p_organization_id and status='posted'
    for update;
    if not found or v_source.contact_id<>p_contact_id or
       v_source.document_type<>case when p_type='credit_note' then 'invoice' else 'bill' end then
      raise exception 'Credit must reference a posted document for this contact';
    end if;
  elsif p_source_document_id is not null then raise exception 'Only credits may reference another document';
  end if;
  update public.organizations set document_sequence=document_sequence+1
  where id=p_organization_id returning document_sequence into v_seq;
  insert into public.financial_documents(
    organization_id,contact_id,document_type,document_number,issue_date,due_date,memo,
    source_document_id,created_by)
  values(p_organization_id,p_contact_id,p_type,
    (case p_type when 'invoice' then 'INV-' when 'bill' then 'BILL-' when 'credit_note' then 'CN-' else 'VC-' end)||
     lpad(v_seq::text,6,'0'),
    p_issue_date,p_due_date,coalesce(p_memo,''),p_source_document_id,auth.uid())
  returning id into v_id;
  for v_line in select value from jsonb_array_elements(p_lines)
  loop
    v_position:=v_position+1;
    if length(trim(coalesce(v_line->>'description',''))) not between 1 and 250 then raise exception 'Invalid description'; end if;
    v_qty:=(v_line->>'quantity')::numeric;
    v_price:=(v_line->>'unit_price')::numeric;
    v_rate:=(v_line->>'tax_rate_bps')::integer;
    if v_qty is null or v_price is null or v_rate is null or
      v_qty<=0 or v_qty>1000000 or scale(v_qty)>3 or
      v_price<0 or v_price>999999999999 or scale(v_price)>2 or
      v_rate<0 or v_rate>2500 then raise exception 'Invalid quantity, price, or tax rate'; end if;
    v_amount:=round(v_qty*v_price,2);
    v_tax:=round(v_amount*v_rate/10000,2);
    v_subtotal:=v_subtotal+v_amount; v_taxes:=v_taxes+v_tax;
    insert into public.financial_document_lines(
      organization_id,document_id,position,description,quantity,unit_price,tax_rate_bps,amount,tax_amount)
    values(p_organization_id,v_id,v_position,trim(v_line->>'description'),v_qty,v_price,v_rate,v_amount,v_tax);
  end loop;
  if v_subtotal+v_taxes<=0 then raise exception 'Document total must exceed zero'; end if;
  update public.financial_documents set subtotal=v_subtotal,tax_total=v_taxes where id=v_id;
  return v_id;
end $$;

-- Outstanding includes posted payments and posted credits. No direct client modifications.
create function public.document_outstanding(p_organization_id uuid,p_document_id uuid)
returns numeric language sql stable security definer set search_path=''
as $$
  select case when d.document_type in ('invoice','bill') and d.status='posted' then
    greatest(0, d.total -
      coalesce((select sum(p.amount) from public.document_payments p
        where p.organization_id=d.organization_id and p.document_id=d.id),0) -
      coalesce((select sum(c.total) from public.financial_documents c
        where c.organization_id=d.organization_id and c.source_document_id=d.id and
          c.status='posted' and c.document_type in ('credit_note','vendor_credit')),0))
  else 0 end
  from public.financial_documents d
  where d.organization_id=p_organization_id and d.id=p_document_id
    and public.has_org_access(d.organization_id)
$$;

create function public.post_financial_document(p_organization_id uuid,p_document_id uuid)
returns uuid language plpgsql security definer set search_path=''
as $$
declare d public.financial_documents%rowtype; v_journal uuid; v_ar uuid; v_bank uuid;
  v_income uuid; v_tax uuid; v_offset uuid; v_lines jsonb; v_outstanding numeric;
begin
  if not public.has_org_write(p_organization_id) then raise exception 'Not authorized'; end if;
  perform 1 from public.organizations where id=p_organization_id for update;
  select * into d from public.financial_documents where organization_id=p_organization_id and id=p_document_id for update;
  if not found then raise exception 'Document not found'; end if;
  if d.status='posted' then return d.journal_entry_id; end if;
  if d.total<=0 then raise exception 'Empty document'; end if;
  if d.source_document_id is not null then
    select public.document_outstanding(p_organization_id,d.source_document_id) into v_outstanding;
    if d.total>v_outstanding then raise exception 'Credit exceeds outstanding source document'; end if;
  end if;
  select id into strict v_ar from public.accounts where organization_id=p_organization_id and code=
    case when d.document_type in ('invoice','credit_note') then '1100' else '2000' end and is_active;
  select id into strict v_income from public.accounts where organization_id=p_organization_id and code=
    case when d.document_type in ('invoice','credit_note') then '4000' else '5000' end and is_active;
  select id into strict v_tax from public.accounts where organization_id=p_organization_id and code=
    case when d.document_type in ('invoice','credit_note') then '2100' else '1300' end and is_active;
  if d.document_type='invoice' then
    v_lines:=jsonb_build_array(
      jsonb_build_object('account_id',v_ar,'debit',d.total,'credit',0),
      jsonb_build_object('account_id',v_income,'debit',0,'credit',d.subtotal));
    if d.tax_total>0 then v_lines:=v_lines||jsonb_build_array(jsonb_build_object('account_id',v_tax,'debit',0,'credit',d.tax_total)); end if;
  elsif d.document_type='bill' then
    v_lines:=jsonb_build_array(
      jsonb_build_object('account_id',v_income,'debit',d.subtotal,'credit',0),
      jsonb_build_object('account_id',v_ar,'debit',0,'credit',d.total));
    if d.tax_total>0 then v_lines:=v_lines||jsonb_build_array(jsonb_build_object('account_id',v_tax,'debit',d.tax_total,'credit',0)); end if;
  elsif d.document_type='credit_note' then
    v_lines:=jsonb_build_array(
      jsonb_build_object('account_id',v_income,'debit',d.subtotal,'credit',0),
      jsonb_build_object('account_id',v_ar,'debit',0,'credit',d.total));
    if d.tax_total>0 then v_lines:=v_lines||jsonb_build_array(jsonb_build_object('account_id',v_tax,'debit',d.tax_total,'credit',0)); end if;
  else
    v_lines:=jsonb_build_array(
      jsonb_build_object('account_id',v_ar,'debit',d.total,'credit',0),
      jsonb_build_object('account_id',v_income,'debit',0,'credit',d.subtotal));
    if d.tax_total>0 then v_lines:=v_lines||jsonb_build_array(jsonb_build_object('account_id',v_tax,'debit',0,'credit',d.tax_total)); end if;
  end if;
  -- Both journal and source document are posted in one database transaction.
  v_journal:=private.post_accounting_journal_internal('document',p_organization_id,d.issue_date,
    left(d.document_number||' '||coalesce(nullif(d.memo,''),d.document_type),500),
    d.document_number,d.id,v_lines);
  update public.financial_documents
  set journal_entry_id=v_journal,status='posted',posted_at=now()
  where organization_id=p_organization_id and id=p_document_id;
  return v_journal;
end $$;

create function public.record_document_payment(
  p_organization_id uuid,p_document_id uuid,p_amount numeric,
  p_payment_date date,p_reference text,p_idempotency_key uuid
) returns uuid language plpgsql security definer set search_path=''
as $$
declare d public.financial_documents%rowtype; v_id uuid; v_journal uuid; v_bank uuid;
  v_ar uuid; v_lines jsonb; v_outstanding numeric;
begin
  if not public.has_org_write(p_organization_id) then raise exception 'Not authorized'; end if;
  if p_idempotency_key is null or p_payment_date is null then raise exception 'Missing payment key or date'; end if;
  if p_amount is null or p_amount<=0 or scale(p_amount)>2 then raise exception 'Invalid payment amount'; end if;
  if length(coalesce(p_reference,''))>100 then raise exception 'Payment reference too long'; end if;
  perform 1 from public.organizations where id=p_organization_id for update;
  select id into v_id from public.document_payments where organization_id=p_organization_id and idempotency_key=p_idempotency_key;
  if found then return v_id; end if;
  select * into d from public.financial_documents where organization_id=p_organization_id and id=p_document_id for update;
  if not found or d.status<>'posted' or d.document_type not in ('invoice','bill') then
    raise exception 'Payments require a posted invoice or bill';
  end if;
  v_outstanding:=public.document_outstanding(p_organization_id,p_document_id);
  if p_amount>v_outstanding then raise exception 'Payment exceeds outstanding amount'; end if;
  select id into strict v_bank from public.accounts where organization_id=p_organization_id and code='1000' and is_active;
  select id into strict v_ar from public.accounts where organization_id=p_organization_id and code=
    case when d.document_type='invoice' then '1100' else '2000' end and is_active;
  if d.document_type='invoice' then
    v_lines:=jsonb_build_array(
      jsonb_build_object('account_id',v_bank,'debit',p_amount,'credit',0),
      jsonb_build_object('account_id',v_ar,'debit',0,'credit',p_amount));
  else
    v_lines:=jsonb_build_array(
      jsonb_build_object('account_id',v_ar,'debit',p_amount,'credit',0),
      jsonb_build_object('account_id',v_bank,'debit',0,'credit',p_amount));
  end if;
  v_journal:=private.post_accounting_journal_internal('payment',p_organization_id,p_payment_date,
    'Payment '||d.document_number,
    left(coalesce(p_reference,'Payment'),80),p_idempotency_key,v_lines);
  insert into public.document_payments(
    organization_id,document_id,amount,payment_date,reference,idempotency_key,journal_entry_id,created_by)
  values(p_organization_id,p_document_id,p_amount,p_payment_date,
    nullif(trim(p_reference),''),p_idempotency_key,v_journal,auth.uid()) returning id into v_id;
  return v_id;
end $$;

-- Reversing posted source-document journals directly would desynchronize receivables/payables.
-- Only standalone/manual journal entries can be reversed through this RPC.
create function public.reverse_manual_journal(
  p_organization_id uuid,p_journal_id uuid,p_reversal_date date,p_reason text
) returns uuid language plpgsql security definer set search_path=''
as $$
declare v_original public.journal_entries%rowtype; v_reverse uuid; v_lines jsonb;
begin
  if not public.has_org_write(p_organization_id) then raise exception 'Not authorized'; end if;
  if p_reason is null or length(trim(p_reason)) not between 3 and 500 then raise exception 'Invalid reversal reason'; end if;
  perform 1 from public.organizations where id=p_organization_id for update;
  select * into v_original from public.journal_entries where organization_id=p_organization_id and id=p_journal_id for update;
  if not found then raise exception 'Journal not found'; end if;
  if exists(select 1 from public.financial_documents where organization_id=p_organization_id and journal_entry_id=p_journal_id)
    or exists(select 1 from public.document_payments where organization_id=p_organization_id and journal_entry_id=p_journal_id)
    or exists(select 1 from public.journal_reversals where organization_id=p_organization_id and reversing_journal_id=p_journal_id) then
      raise exception 'This journal is part of a source workflow and cannot be reversed here';
  end if;
  select reversing_journal_id into v_reverse from public.journal_reversals
  where organization_id=p_organization_id and original_journal_id=p_journal_id;
  if found then return v_reverse; end if;
  select jsonb_agg(jsonb_build_object('account_id',account_id,'debit',credit,'credit',debit) order by id)
  into v_lines from public.journal_lines where organization_id=p_organization_id and journal_entry_id=p_journal_id;
  v_reverse:=private.post_accounting_journal_internal('reversal',p_organization_id,p_reversal_date,
    'Reversal: '||left(trim(p_reason),480),'REV-'||left(p_journal_id::text,32),
    p_journal_id,v_lines);
  insert into public.journal_reversals(organization_id,original_journal_id,reversing_journal_id,reason,reversed_by)
    values(p_organization_id,p_journal_id,v_reverse,trim(p_reason),auth.uid());
  return v_reverse;
end $$;

create function public.ledger_trial_balance(p_organization_id uuid,p_through date)
returns table(account_id uuid,account_code text,account_name text,account_type text,
  total_debits numeric,total_credits numeric,net_debit numeric)
language plpgsql stable security definer set search_path=''
as $$
begin
  if not public.has_org_access(p_organization_id) then raise exception 'Not authorized'; end if;
  if p_through is null then raise exception 'Reporting date required'; end if;
  return query
    select a.id,a.code::text,a.name::text,a.account_type::text,
      coalesce(sum(l.debit),0)::numeric,coalesce(sum(l.credit),0)::numeric,
      (coalesce(sum(l.debit),0)-coalesce(sum(l.credit),0))::numeric
    from public.accounts a
    left join public.journal_lines l on l.organization_id=a.organization_id and l.account_id=a.id
    left join public.journal_entries j on j.organization_id=l.organization_id
      and j.id=l.journal_entry_id and j.entry_date<=p_through
    where a.organization_id=p_organization_id
    group by a.id,a.code,a.name,a.account_type
    order by a.code;
end $$;

-- Corrected as-of query: filter date inside the financial-line join so later postings never leak.
create or replace function public.ledger_trial_balance(p_organization_id uuid,p_through date)
returns table(account_id uuid,account_code text,account_name text,account_type text,
  total_debits numeric,total_credits numeric,net_debit numeric)
language plpgsql stable security definer set search_path=''
as $$
begin
  if not public.has_org_access(p_organization_id) then raise exception 'Not authorized'; end if;
  if p_through is null then raise exception 'Reporting date required'; end if;
  return query
    select a.id,a.code::text,a.name::text,a.account_type::text,
      coalesce(sum(l.debit),0)::numeric,coalesce(sum(l.credit),0)::numeric,
      (coalesce(sum(l.debit),0)-coalesce(sum(l.credit),0))::numeric
    from public.accounts a
    left join (
      select l.organization_id,l.account_id,l.debit,l.credit
      from public.journal_lines l
      join public.journal_entries j on j.organization_id=l.organization_id
        and j.id=l.journal_entry_id and j.entry_date<=p_through
      where l.organization_id=p_organization_id
    ) l on l.organization_id=a.organization_id and l.account_id=a.id
    where a.organization_id=p_organization_id
    group by a.id,a.code,a.name,a.account_type
    order by a.code;
end $$;

create function public.ledger_profit_loss(p_organization_id uuid,p_from date,p_through date)
returns table(account_code text,account_name text,account_type text,amount numeric)
language plpgsql stable security definer set search_path=''
as $$
begin
  if not public.has_org_access(p_organization_id) then raise exception 'Not authorized'; end if;
  if p_from is null or p_through is null or p_from>p_through then raise exception 'Invalid report dates'; end if;
  return query
    select a.code::text,a.name::text,a.account_type::text,
      coalesce(sum(case when a.account_type='revenue' then l.credit-l.debit else l.debit-l.credit end),0)::numeric
    from public.accounts a
    left join (
      select l.organization_id,l.account_id,l.debit,l.credit
      from public.journal_lines l join public.journal_entries j
      on j.organization_id=l.organization_id and j.id=l.journal_entry_id
      where l.organization_id=p_organization_id and j.entry_date between p_from and p_through
    ) l on l.organization_id=a.organization_id and l.account_id=a.id
    where a.organization_id=p_organization_id and a.account_type in ('revenue','expense')
    group by a.code,a.name,a.account_type order by a.code;
end $$;

-- RPC endpoints are executable only by authenticated users; RLS blocks direct table writes.
do $$
declare r record;
begin
  for r in select p.oid::regprocedure as signature
           from pg_proc p join pg_namespace n on n.oid=p.pronamespace
           where n.nspname='public' and p.proname in
             ('create_contact','create_financial_document','document_outstanding',
              'post_financial_document','record_document_payment','reverse_manual_journal',
              'ledger_trial_balance','ledger_profit_loss')
  loop
    execute format('revoke all on function %s from public, anon',r.signature);
    execute format('grant execute on function %s to authenticated',r.signature);
  end loop;
end $$;
