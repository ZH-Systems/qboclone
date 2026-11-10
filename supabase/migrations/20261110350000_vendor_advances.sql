-- Milestone 9: supplier prepayments (unapplied vendor advances).
-- Supplier payments are assets until allocated to posted supplier bills or refunded.
insert into public.accounts(organization_id,code,name,account_type,normal_balance)
 select o.id,'1350','Supplier Advances','asset','debit' from public.organizations o
 where not exists(select 1 from public.accounts a where a.organization_id=o.id and a.code='1350');
create function private.seed_supplier_advances() returns trigger language plpgsql set search_path=''
as $$
begin
 if new.code='2000' and new.account_type='liability' then
  insert into public.accounts(organization_id,code,name,account_type,normal_balance)
  values(new.organization_id,'1350','Supplier Advances','asset','debit')
  on conflict(organization_id,code) do nothing;
 end if;
 return new;
end $$;
create trigger seed_supplier_advances after insert on public.accounts
 for each row execute function private.seed_supplier_advances();
revoke all on function private.seed_supplier_advances() from public,anon,authenticated;

create table public.vendor_advances(
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null references public.organizations(id) on delete restrict,
 vendor_id uuid not null,
 paid_on date not null,
 amount numeric(20,2) not null check(amount>0),
 reference varchar(100),
 journal_entry_id uuid not null,
 idempotency_key uuid not null,
 created_at timestamptz not null default now(),
 created_by uuid not null references auth.users(id),
 unique(organization_id,id),unique(organization_id,idempotency_key),
 foreign key(organization_id,vendor_id) references public.contacts(organization_id,id),
 foreign key(organization_id,journal_entry_id) references public.journal_entries(organization_id,id)
);
create table public.vendor_advance_applications(
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null,
 advance_id uuid not null,
 bill_id uuid not null,
 amount numeric(20,2) not null check(amount>0),
 applied_on date not null,
 journal_entry_id uuid not null,
 idempotency_key uuid not null,
 created_by uuid not null references auth.users(id),
 created_at timestamptz not null default now(),
 unique(organization_id,id),unique(organization_id,idempotency_key),
 foreign key(organization_id,advance_id) references public.vendor_advances(organization_id,id),
 foreign key(organization_id,bill_id) references public.financial_documents(organization_id,id),
 foreign key(organization_id,journal_entry_id) references public.journal_entries(organization_id,id)
);
create table public.vendor_advance_refunds(
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null,
 advance_id uuid not null,
 amount numeric(20,2) not null check(amount>0),
 refunded_on date not null,
 reason varchar(500) not null check(length(trim(reason)) between 3 and 500),
 journal_entry_id uuid not null,
 idempotency_key uuid not null,
 created_by uuid not null references auth.users(id),
 created_at timestamptz not null default now(),
 unique(organization_id,id),unique(organization_id,idempotency_key),
 foreign key(organization_id,advance_id) references public.vendor_advances(organization_id,id),
 foreign key(organization_id,journal_entry_id) references public.journal_entries(organization_id,id)
);
alter table public.vendor_advances enable row level security;
alter table public.vendor_advance_applications enable row level security;
alter table public.vendor_advance_refunds enable row level security;
create policy vendor_advances_read on public.vendor_advances for select to authenticated using(public.has_org_access(organization_id));
create policy vendor_advance_applications_read on public.vendor_advance_applications for select to authenticated using(public.has_org_access(organization_id));
create policy vendor_advance_refunds_read on public.vendor_advance_refunds for select to authenticated using(public.has_org_access(organization_id));
revoke all on public.vendor_advances,public.vendor_advance_applications,public.vendor_advance_refunds from public,anon,authenticated;
grant select on public.vendor_advances,public.vendor_advance_applications,public.vendor_advance_refunds to authenticated;

create function public.vendor_advance_available(p_org uuid,p_advance uuid)
returns numeric language sql stable security definer set search_path=''
as $$
 select greatest(0,a.amount-
  coalesce((select sum(x.amount) from public.vendor_advance_applications x
   where x.organization_id=p_org and x.advance_id=a.id),0)-
  coalesce((select sum(r.amount) from public.vendor_advance_refunds r
   where r.organization_id=p_org and r.advance_id=a.id),0))
 from public.vendor_advances a
 where a.organization_id=p_org and a.id=p_advance and public.has_org_access(p_org)
$$;

create function public.pay_vendor_advance(
 p_org uuid,p_vendor uuid,p_amount numeric,p_date date,p_reference text,p_key uuid
) returns uuid language plpgsql security definer set search_path=''
as $$
declare v_existing public.vendor_advances%rowtype;v_asset uuid;v_bank uuid;v_journal uuid;v_id uuid;
begin
 if not public.has_org_write(p_org) then raise exception 'Not authorized';end if;
 if p_date is null or p_key is null or p_amount is null or p_amount<=0
 or scale(p_amount)>2 or length(coalesce(p_reference,''))>100
 then raise exception 'Invalid vendor advance';end if;
 perform 1 from public.organizations where id=p_org for update;
 select * into v_existing from public.vendor_advances
  where organization_id=p_org and idempotency_key=p_key;
 if found then
  if v_existing.vendor_id<>p_vendor or v_existing.amount<>p_amount or
   v_existing.paid_on<>p_date or v_existing.reference is distinct from nullif(trim(p_reference),'')
  then raise exception 'Conflicting advance idempotency replay';end if;
  return v_existing.id;
 end if;
 if not exists(select 1 from public.contacts where organization_id=p_org
 and id=p_vendor and contact_kind='vendor') then raise exception 'Vendor not found';end if;
 select id into v_asset from public.accounts where organization_id=p_org and code='1350'
  and account_type='asset' and is_active;
 select id into v_bank from public.accounts where organization_id=p_org and code='1000'
  and account_type='asset' and is_active;
 if v_asset is null or v_bank is null then raise exception 'Advance or bank account not available';end if;
 v_journal:=private.post_accounting_journal_internal('payment',p_org,p_date,
 'Supplier prepayment','VENDOR-ADVANCE',p_key,jsonb_build_array(
 jsonb_build_object('account_id',v_asset,'debit',p_amount,'credit',0),
 jsonb_build_object('account_id',v_bank,'debit',0,'credit',p_amount)));
 insert into public.vendor_advances(organization_id,vendor_id,paid_on,amount,reference,
 journal_entry_id,idempotency_key,created_by)
 values(p_org,p_vendor,p_date,p_amount,nullif(trim(p_reference),''),v_journal,p_key,auth.uid())
 returning id into v_id;
 perform private.write_audit(p_org,'vendor.advance_paid','vendor_advance',v_id,
  jsonb_build_object('amount',p_amount,'vendor_id',p_vendor));
 return v_id;
end $$;

create function public.apply_vendor_advance(
 p_org uuid,p_advance uuid,p_bill uuid,p_amount numeric,p_date date,p_key uuid
) returns uuid language plpgsql security definer set search_path=''
as $$
declare v_advance public.vendor_advances%rowtype;v_doc public.financial_documents%rowtype;
 v_existing public.vendor_advance_applications%rowtype;v_asset uuid;v_ap uuid;v_journal uuid;v_id uuid;
begin
 if not public.has_org_write(p_org) then raise exception 'Not authorized';end if;
 if p_key is null or p_date is null or p_amount is null or p_amount<=0 or scale(p_amount)>2
 then raise exception 'Invalid advance allocation';end if;
 perform 1 from public.organizations where id=p_org for update;
 select * into v_existing from public.vendor_advance_applications where
  organization_id=p_org and idempotency_key=p_key;
 if found then
  if v_existing.advance_id<>p_advance or v_existing.bill_id<>p_bill or
   v_existing.amount<>p_amount or v_existing.applied_on<>p_date
  then raise exception 'Conflicting allocation replay';end if;
  return v_existing.id;
 end if;
 select * into v_advance from public.vendor_advances
  where organization_id=p_org and id=p_advance for update;
 select * into v_doc from public.financial_documents where organization_id=p_org
  and id=p_bill and status='posted' and document_type='bill' for update;
 if not found or v_advance.id is null or v_doc.contact_id<>v_advance.vendor_id
 then raise exception 'Advance must match posted bill and vendor';end if;
 if p_date<v_advance.paid_on or p_date<v_doc.issue_date
 then raise exception 'Allocation predates source transaction';end if;
 if p_amount>public.vendor_advance_available(p_org,p_advance)
 or p_amount>public.document_outstanding(p_org,p_bill)
 then raise exception 'Allocation exceeds vendor advance or outstanding bill';end if;
 select id into v_asset from public.accounts where organization_id=p_org and code='1350' and is_active;
 select id into v_ap from public.accounts where organization_id=p_org and code='2000' and is_active;
 if v_asset is null or v_ap is null then raise exception 'Advance or payable account unavailable';end if;
 v_journal:=private.post_accounting_journal_internal('payment',p_org,p_date,
 'Apply supplier advance to posted bill','ADVANCE-APPLY',p_key,jsonb_build_array(
 jsonb_build_object('account_id',v_ap,'debit',p_amount,'credit',0),
 jsonb_build_object('account_id',v_asset,'debit',0,'credit',p_amount)));
 insert into public.vendor_advance_applications(organization_id,advance_id,bill_id,amount,
 applied_on,journal_entry_id,idempotency_key,created_by)
 values(p_org,p_advance,p_bill,p_amount,p_date,v_journal,p_key,auth.uid()) returning id into v_id;
 perform private.write_audit(p_org,'vendor.advance_applied','vendor_advance_application',v_id,
 jsonb_build_object('bill_id',p_bill,'amount',p_amount));
 return v_id;
end $$;

create function public.refund_vendor_advance(
 p_org uuid,p_advance uuid,p_amount numeric,p_date date,p_reason text,p_key uuid
) returns uuid language plpgsql security definer set search_path=''
as $$
declare v_advance public.vendor_advances%rowtype;v_existing public.vendor_advance_refunds%rowtype;
 v_asset uuid;v_bank uuid;v_journal uuid;v_id uuid;
begin
 if not public.has_org_write(p_org) then raise exception 'Not authorized';end if;
 if p_key is null or p_date is null or p_amount is null or p_amount<=0 or scale(p_amount)>2
 or p_reason is null or length(trim(p_reason)) not between 3 and 500
 then raise exception 'Invalid vendor advance refund';end if;
 perform 1 from public.organizations where id=p_org for update;
 select * into v_existing from public.vendor_advance_refunds
  where organization_id=p_org and idempotency_key=p_key;
 if found then
  if v_existing.advance_id<>p_advance or v_existing.amount<>p_amount or
    v_existing.refunded_on<>p_date or v_existing.reason<>trim(p_reason)
  then raise exception 'Conflicting refund replay';end if;
  return v_existing.id;
 end if;
 select * into v_advance from public.vendor_advances
 where organization_id=p_org and id=p_advance for update;
 if not found then raise exception 'Supplier advance not found';end if;
 if p_date<v_advance.paid_on or p_amount>public.vendor_advance_available(p_org,p_advance)
 then raise exception 'Refund exceeds available vendor advance or predates payment';end if;
 select id into v_asset from public.accounts where organization_id=p_org and code='1350' and is_active;
 select id into v_bank from public.accounts where organization_id=p_org and code='1000' and is_active;
 if v_asset is null or v_bank is null then raise exception 'Advance or bank account unavailable';end if;
 v_journal:=private.post_accounting_journal_internal('reversal',p_org,p_date,
 'Supplier advance returned','ADVANCE-REFUND',p_key,jsonb_build_array(
 jsonb_build_object('account_id',v_bank,'debit',p_amount,'credit',0),
 jsonb_build_object('account_id',v_asset,'debit',0,'credit',p_amount)));
 insert into public.vendor_advance_refunds(organization_id,advance_id,amount,refunded_on,
 reason,journal_entry_id,idempotency_key,created_by)
 values(p_org,p_advance,p_amount,p_date,trim(p_reason),v_journal,p_key,auth.uid())
 returning id into v_id;
 perform private.write_audit(p_org,'vendor.advance_refunded','vendor_advance_refund',v_id,
 jsonb_build_object('amount',p_amount));
 return v_id;
end $$;

-- Previous matching customer deposit and writeoff rules remain intact.
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
       where ap.organization_id=d.organization_id and ap.invoice_id=d.id),0)-
    coalesce((select sum(av.amount) from public.vendor_advance_applications av
       where av.organization_id=d.organization_id and av.bill_id=d.id),0))
 else 0 end
 from public.financial_documents d
 where d.organization_id=p_organization_id and d.id=p_document_id
   and public.has_org_access(d.organization_id)
$$;

-- Historical supplier advances must be included in dated AP aging.
create or replace function public.aged_open_documents(
 p_organization_id uuid,p_as_of date,p_kind text
) returns table(document_id uuid,document_number text,contact_name text,due_date date,
 outstanding numeric,days_past_due integer,aging_bucket text)
language plpgsql stable security definer set search_path=''
as $$
begin
 if not public.has_org_access(p_organization_id) then raise exception 'Not authorized';end if;
 if p_as_of is null or p_kind not in ('invoice','bill') then
  raise exception 'Aging requires a date and document kind';end if;
 return query
 with open_amounts as (
  select d.id,d.document_number::text,c.display_name::text,d.due_date,
   (d.total
    -coalesce((select sum(p.amount) from public.document_payments p
      where p.organization_id=d.organization_id and p.document_id=d.id and p.payment_date<=p_as_of),0)
    +coalesce((select sum(r.amount) from public.payment_refunds r
      join public.document_payments p on p.organization_id=r.organization_id and p.id=r.original_payment_id
      where p.organization_id=d.organization_id and p.document_id=d.id and r.refund_date<=p_as_of),0)
    -coalesce((select sum(cr.total) from public.financial_documents cr
      where cr.organization_id=d.organization_id and cr.source_document_id=d.id
       and cr.status='posted' and cr.issue_date<=p_as_of),0)
    -coalesce((select sum(w.amount) from public.document_writeoffs w
      where w.organization_id=d.organization_id and w.document_id=d.id
        and w.entry_date<=p_as_of),0)
    -coalesce((select sum(ap.amount) from public.deposit_applications ap
      where ap.organization_id=d.organization_id and ap.invoice_id=d.id and ap.applied_on<=p_as_of),0)
    -coalesce((select sum(av.amount) from public.vendor_advance_applications av
      where av.organization_id=d.organization_id and av.bill_id=d.id and av.applied_on<=p_as_of),0))::numeric balance
  from public.financial_documents d
  join public.contacts c on c.organization_id=d.organization_id and c.id=d.contact_id
  where d.organization_id=p_organization_id and d.document_type=p_kind
   and d.status='posted' and d.issue_date<=p_as_of
 )
 select a.id,a.document_number,a.display_name,a.due_date,a.balance,
  greatest(0,p_as_of-a.due_date)::integer,
  case when p_as_of<=a.due_date then 'current'
   when p_as_of-a.due_date between 1 and 30 then '1_30'
   when p_as_of-a.due_date between 31 and 60 then '31_60'
   when p_as_of-a.due_date between 61 and 90 then '61_90' else '90_plus' end
 from open_amounts a where a.balance>0 order by a.due_date,a.id;
end $$;

-- Prevent manual reversal of source-linked vendor advance journals.
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
 or exists(select 1 from public.vendor_advances where organization_id=p_organization_id and journal_entry_id=p_journal_id)
 or exists(select 1 from public.vendor_advance_applications where organization_id=p_organization_id and journal_entry_id=p_journal_id)
 or exists(select 1 from public.vendor_advance_refunds where organization_id=p_organization_id and journal_entry_id=p_journal_id)
 or exists(select 1 from public.inventory_receipts where organization_id=p_organization_id and journal_entry_id=p_journal_id)
 or exists(select 1 from public.inventory_issues where organization_id=p_organization_id and journal_entry_id=p_journal_id)
 then raise exception 'Source accounting journal cannot be manually reversed';end if;
 return public.reverse_manual_journal_legacy(p_organization_id,p_journal_id,p_reversal_date,p_reason);
end $$;
revoke all on function public.create_inventory_product(uuid,text,text),
 public.receive_inventory_bill_line(uuid,uuid,uuid,date,uuid),
 public.issue_inventory_invoice_line(uuid,uuid,uuid,date,uuid) from public,anon;
revoke all on function public.vendor_advance_available(uuid,uuid),
 public.pay_vendor_advance(uuid,uuid,numeric,date,text,uuid),
 public.apply_vendor_advance(uuid,uuid,uuid,numeric,date,uuid),
 public.refund_vendor_advance(uuid,uuid,numeric,date,text,uuid) from public,anon;
grant execute on function public.vendor_advance_available(uuid,uuid),
 public.pay_vendor_advance(uuid,uuid,numeric,date,text,uuid),
 public.apply_vendor_advance(uuid,uuid,uuid,numeric,date,uuid),
 public.refund_vendor_advance(uuid,uuid,numeric,date,text,uuid) to authenticated;
