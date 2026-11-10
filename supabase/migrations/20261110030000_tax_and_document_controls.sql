-- Milestone 3: tax-code snapshots, account mappings and controlled draft corrections.
-- Requires 20261110010000_accounting_workflows.sql.
-- MANUAL TAX CONFIGURATION: no jurisdiction/place-of-supply or CRA filing certification.
create table public.tax_codes(
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete restrict,
  code varchar(24) not null check(code ~ '^[A-Za-z0-9_-]{1,24}$'),
  label varchar(120) not null,
  transaction_kind text not null check(transaction_kind in ('sale','purchase')),
  classification text not null check(classification in ('taxable','zero_rated','exempt','out_of_scope')),
  rate_bps integer not null check(rate_bps between 0 and 2500),
  recoverable_bps integer not null default 0 check(recoverable_bps between 0 and 10000),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique(organization_id,code,transaction_kind),
  unique(organization_id,id),
  check(classification='taxable' or rate_bps=0),
  check(transaction_kind='purchase' or recoverable_bps=0)
);
create index tax_codes_org_kind_idx on public.tax_codes(organization_id,transaction_kind);
alter table public.tax_codes enable row level security;
create policy tax_codes_read on public.tax_codes for select to authenticated
 using(public.has_org_access(organization_id));
revoke all on public.tax_codes from public,anon,authenticated;
grant select on public.tax_codes to authenticated;

-- Preserve existing documents without rewriting their posted tax amounts.
alter table public.financial_document_lines
 add column account_id uuid,
 add column tax_code_id uuid,
 add column tax_classification text,
 add column recoverable_tax numeric(20,2) not null default 0
    check(recoverable_tax>=0 and recoverable_tax<=tax_amount),
 add constraint doc_line_account_tenant_fk foreign key(organization_id,account_id)
   references public.accounts(organization_id,id),
 add constraint doc_line_tax_tenant_fk foreign key(organization_id,tax_code_id)
   references public.tax_codes(organization_id,id);
update public.financial_document_lines l set
 account_id=(select a.id from public.accounts a where a.organization_id=l.organization_id
   and a.code=case when d.document_type in ('invoice','credit_note') then '4000' else '5000' end),
 recoverable_tax=case when d.document_type in ('bill','vendor_credit') then l.tax_amount else 0 end
 from public.financial_documents d
 where d.id=l.document_id and d.organization_id=l.organization_id;
alter table public.financial_document_lines alter column account_id set not null;

-- Tax codes are tenant-managed, with explicit permission verification.
create function public.create_tax_code(
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

-- The previous document constructor is replaced with a tax-code-aware,
-- per-line account-aware version. Existing parameter signature is retained.
create or replace function public.create_financial_document(
 p_organization_id uuid,p_contact_id uuid,p_type text,p_issue_date date,
 p_due_date date,p_memo text,p_source_document_id uuid,p_lines jsonb
) returns uuid language plpgsql security definer set search_path=''
as $$
declare v_id uuid; v_source public.financial_documents%rowtype;
 v_line jsonb; v_qty numeric; v_price numeric; v_rate integer; v_amount numeric(20,2);
 v_tax numeric(20,2); v_recoverable numeric(20,2); v_subtotal numeric(20,2):=0;
 v_taxes numeric(20,2):=0; v_pos integer:=0; v_seq bigint; v_kind text;
 v_account uuid; v_tax_code public.tax_codes%rowtype; v_tax_id uuid;
begin
 if not public.has_org_write(p_organization_id) then raise exception 'Not authorized'; end if;
 if p_type not in ('invoice','bill','credit_note','vendor_credit') then raise exception 'Invalid type'; end if;
 if p_issue_date is null or p_due_date is null or p_due_date<p_issue_date then raise exception 'Invalid dates'; end if;
 if length(coalesce(p_memo,''))>500 then raise exception 'Memo too long'; end if;
 if jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines) not between 1 and 100 then
 raise exception 'Document requires 1 to 100 lines'; end if;
 v_kind:=case when p_type in ('invoice','credit_note') then 'customer' else 'vendor' end;
 if not exists(select 1 from public.contacts where organization_id=p_organization_id
  and id=p_contact_id and contact_kind=v_kind) then raise exception 'Contact not found'; end if;
 if p_type in ('credit_note','vendor_credit') then
  select * into v_source from public.financial_documents where organization_id=p_organization_id
   and id=p_source_document_id and status='posted' for update;
  if not found or v_source.contact_id<>p_contact_id or
    v_source.document_type<>case when p_type='credit_note' then 'invoice' else 'bill' end
  then raise exception 'Credit source does not match contact'; end if;
 elsif p_source_document_id is not null then raise exception 'Unexpected source document'; end if;
 update public.organizations set document_sequence=document_sequence+1
  where id=p_organization_id returning document_sequence into v_seq;
 insert into public.financial_documents(
  organization_id,contact_id,document_type,document_number,issue_date,due_date,
  memo,source_document_id,created_by)
 values(p_organization_id,p_contact_id,p_type,
  (case p_type when 'invoice' then 'INV-' when 'bill' then 'BILL-'
    when 'credit_note' then 'CN-' else 'VC-' end)||
    case when length(v_seq::text)>6 then v_seq::text else lpad(v_seq::text,6,'0') end,
  p_issue_date,p_due_date,coalesce(p_memo,''),p_source_document_id,auth.uid())
 returning id into v_id;
 for v_line in select value from jsonb_array_elements(p_lines) loop
  v_pos:=v_pos+1;
  if length(trim(coalesce(v_line->>'description',''))) not between 1 and 250 then
   raise exception 'Invalid line description'; end if;
  v_qty:=(v_line->>'quantity')::numeric;
  v_price:=(v_line->>'unit_price')::numeric;
  if v_qty is null or v_price is null or v_qty<=0 or v_qty>1000000 or
    scale(v_qty)>3 or v_price<0 or v_price>999999999999 or scale(v_price)>2 then
    raise exception 'Invalid quantity or price'; end if;
  v_account:=nullif(v_line->>'account_id','')::uuid;
  if v_account is null then
    select a.id into v_account from public.accounts a
    where a.organization_id=p_organization_id and a.code=
     case when v_kind='customer' then '4000' else '5000' end;
  end if;
  if not exists(select 1 from public.accounts a where a.id=v_account and
    a.organization_id=p_organization_id and a.is_active and
    a.account_type=case when v_kind='customer' then 'revenue' else 'expense' end)
  then raise exception 'Line account must be a same-tenant active revenue or expense account'; end if;
  v_tax_id:=nullif(v_line->>'tax_code_id','')::uuid;
  if v_tax_id is not null then
    select * into v_tax_code from public.tax_codes t where t.id=v_tax_id
      and t.organization_id=p_organization_id and t.active
      and t.transaction_kind=case when v_kind='customer' then 'sale' else 'purchase' end;
    if not found then raise exception 'Tax code not found or wrong transaction kind'; end if;
    v_rate:=v_tax_code.rate_bps;
  else
    -- Compatibility path for Phase 2 clients. New UI should supply a tax code.
    v_rate:=coalesce((v_line->>'tax_rate_bps')::integer,0);
    if v_rate not between 0 and 2500 then raise exception 'Invalid manual tax rate'; end if;
  end if;
  v_amount:=round(v_qty*v_price,2);
  v_tax:=round(v_amount*v_rate/10000,2);
  v_recoverable:=case when v_kind='vendor' then
   case when v_tax_id is null then v_tax
   else round(v_tax*v_tax_code.recoverable_bps/10000,2) end else 0 end;
  v_subtotal:=v_subtotal+v_amount; v_taxes:=v_taxes+v_tax;
  insert into public.financial_document_lines(
   organization_id,document_id,position,description,quantity,unit_price,
   tax_rate_bps,amount,tax_amount,account_id,tax_code_id,tax_classification,recoverable_tax)
  values(p_organization_id,v_id,v_pos,trim(v_line->>'description'),v_qty,v_price,
   v_rate,v_amount,v_tax,v_account,v_tax_id,
   case when v_tax_id is null then 'manual' else v_tax_code.classification end,v_recoverable);
 end loop;
 if v_subtotal+v_taxes<=0 then raise exception 'Document total must exceed zero'; end if;
 update public.financial_documents set subtotal=v_subtotal,tax_total=v_taxes where id=v_id;
 return v_id;
end $$;

-- Repost all source lines per selected account; nonrecoverable tax becomes expense.
create or replace function public.post_financial_document(p_organization_id uuid,p_document_id uuid)
returns uuid language plpgsql security definer set search_path=''
as $$
declare d public.financial_documents%rowtype; v_journal uuid; v_ar uuid; v_tax uuid;
 v_lines jsonb:='[]'::jsonb; v_outstanding numeric;
 v_line public.financial_document_lines%rowtype; v_expense numeric(20,2);
 v_tax_recoverable numeric(20,2):=0; v_sign text;
begin
 if not public.has_org_write(p_organization_id) then raise exception 'Not authorized'; end if;
 perform 1 from public.organizations where id=p_organization_id for update;
 select * into d from public.financial_documents where organization_id=p_organization_id
 and id=p_document_id for update;
 if not found then raise exception 'Document not found'; end if;
 if d.status='posted' then return d.journal_entry_id; end if;
 if d.status<>'draft' then raise exception 'Only draft documents may post'; end if;
 if d.total<=0 then raise exception 'Empty document'; end if;
 if d.source_document_id is not null then
  v_outstanding:=public.document_outstanding(p_organization_id,d.source_document_id);
  if d.total>v_outstanding then raise exception 'Credit exceeds outstanding source balance'; end if;
 end if;
 select a.id into strict v_ar from public.accounts a where a.organization_id=p_organization_id
  and a.code=case when d.document_type in ('invoice','credit_note') then '1100' else '2000' end and a.is_active;
 select a.id into strict v_tax from public.accounts a where a.organization_id=p_organization_id
  and a.code=case when d.document_type in ('invoice','credit_note') then '2100' else '1300' end and a.is_active;

 for v_line in select * from public.financial_document_lines
  where organization_id=p_organization_id and document_id=p_document_id order by position
 loop
  if not exists(select 1 from public.accounts a where a.id=v_line.account_id
   and a.organization_id=p_organization_id and a.is_active) then
    raise exception 'Inactive document posting account'; end if;
  v_expense:=v_line.amount+case when d.document_type in ('bill','vendor_credit')
    then v_line.tax_amount-v_line.recoverable_tax else 0 end;
  if v_expense>0 then
   v_lines:=v_lines||jsonb_build_array(jsonb_build_object('account_id',v_line.account_id,
    'debit',case when d.document_type in ('bill','credit_note') then v_expense else 0 end,
    'credit',case when d.document_type in ('invoice','vendor_credit') then v_expense else 0 end));
  end if;
  v_tax_recoverable:=v_tax_recoverable+v_line.recoverable_tax;
 end loop;
 if d.document_type in ('invoice','credit_note') then
  if d.tax_total>0 then
   v_lines:=v_lines||jsonb_build_array(jsonb_build_object('account_id',v_tax,
    'debit',case when d.document_type='credit_note' then d.tax_total else 0 end,
    'credit',case when d.document_type='invoice' then d.tax_total else 0 end)); end if;
 elsif v_tax_recoverable>0 then
  v_lines:=v_lines||jsonb_build_array(jsonb_build_object('account_id',v_tax,
   'debit',case when d.document_type='bill' then v_tax_recoverable else 0 end,
   'credit',case when d.document_type='vendor_credit' then v_tax_recoverable else 0 end));
 end if;
 v_lines:=v_lines||jsonb_build_array(jsonb_build_object('account_id',v_ar,
  'debit',case when d.document_type in ('invoice','vendor_credit') then d.total else 0 end,
  'credit',case when d.document_type in ('bill','credit_note') then d.total else 0 end));
 v_journal:=private.post_accounting_journal_internal('document',p_organization_id,
  d.issue_date,left(d.document_number||' '||coalesce(nullif(d.memo,''),d.document_type),500),
  d.document_number,d.id,v_lines);
 update public.financial_documents set journal_entry_id=v_journal,status='posted',posted_at=now()
  where organization_id=p_organization_id and id=p_document_id;
 return v_journal;
end $$;

-- Posted documents are immutable. Only unposted drafts can be voided.
alter table public.financial_documents drop constraint financial_documents_status_check;
alter table public.financial_documents add constraint financial_documents_status_check
 check(status in ('draft','posted','void'));
-- Locate the original unnamed source-posting invariant by its definition.
-- PostgreSQL can assign different auto-generated CHECK constraint names.
do $migration$
declare v_name text;
begin
 for v_name in
   select c.conname from pg_constraint c
   where c.conrelid='public.financial_documents'::regclass
     and c.contype='c'
     and pg_get_constraintdef(c.oid) ilike '%journal_entry_id%'
     and pg_get_constraintdef(c.oid) ilike '%posted_at%'
 loop
   execute format('alter table public.financial_documents drop constraint %I',v_name);
 end loop;
end $migration$;
alter table public.financial_documents add constraint financial_documents_posting_state_check
 check(
  (status in ('draft','void') and journal_entry_id is null and posted_at is null)
  or (status='posted' and journal_entry_id is not null and posted_at is not null)
 );
alter table public.financial_documents add column void_reason varchar(500);
alter table public.financial_documents add column voided_at timestamptz;

create function public.void_financial_draft(p_organization_id uuid,p_document_id uuid,p_reason text)
returns void language plpgsql security definer set search_path=''
as $$
begin
 if not public.has_org_write(p_organization_id) then raise exception 'Not authorized'; end if;
 if p_reason is null or length(trim(p_reason)) not between 3 and 500 then raise exception 'Invalid reason'; end if;
 perform 1 from public.organizations where id=p_organization_id for update;
 update public.financial_documents set status='void',void_reason=trim(p_reason),voided_at=now()
 where id=p_document_id and organization_id=p_organization_id and status='draft';
 if not found then raise exception 'Only unposted drafts can be voided'; end if;
end $$;

create function public.replace_financial_draft(
 p_organization_id uuid,p_document_id uuid,p_lines jsonb,p_memo text,p_due_date date
) returns uuid language plpgsql security definer set search_path=''
as $$
declare d public.financial_documents%rowtype; v_line jsonb; v_qty numeric; v_price numeric;
 v_rate integer; v_amount numeric(20,2); v_tax numeric(20,2);
 v_recoverable numeric(20,2); v_subtotal numeric(20,2):=0; v_taxes numeric(20,2):=0;
 v_acc uuid; v_tax_id uuid; v_tc public.tax_codes%rowtype; v_kind text; v_pos integer:=0;
begin
 if not public.has_org_write(p_organization_id) then raise exception 'Not authorized'; end if;
 perform 1 from public.organizations where id=p_organization_id for update;
 select * into d from public.financial_documents where id=p_document_id
  and organization_id=p_organization_id and status='draft' for update;
 if not found then raise exception 'Only existing drafts can be edited'; end if;
 if p_due_date is null or p_due_date<d.issue_date or length(coalesce(p_memo,''))>500 then
 raise exception 'Invalid due date or memo'; end if;
 if jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines) not between 1 and 100
 then raise exception 'Document requires 1 to 100 lines'; end if;
 v_kind:=case when d.document_type in ('invoice','credit_note') then 'customer' else 'vendor' end;
 delete from public.financial_document_lines where organization_id=p_organization_id and document_id=p_document_id;
 for v_line in select value from jsonb_array_elements(p_lines) loop
  v_pos:=v_pos+1;
  if length(trim(coalesce(v_line->>'description',''))) not between 1 and 250 then raise exception 'Invalid description'; end if;
  v_qty:=(v_line->>'quantity')::numeric;v_price:=(v_line->>'unit_price')::numeric;
  if v_qty is null or v_price is null or v_qty<=0 or v_qty>1000000 or scale(v_qty)>3
   or v_price<0 or v_price>999999999999 or scale(v_price)>2 then raise exception 'Invalid amount'; end if;
  v_acc:=nullif(v_line->>'account_id','')::uuid;
  if v_acc is null then select id into v_acc from public.accounts where organization_id=p_organization_id
    and code=case when v_kind='customer' then '4000' else '5000' end; end if;
  if not exists(select 1 from public.accounts where id=v_acc and organization_id=p_organization_id and is_active
    and account_type=case when v_kind='customer' then 'revenue' else 'expense' end) then
    raise exception 'Invalid posting account'; end if;
  v_tax_id:=nullif(v_line->>'tax_code_id','')::uuid;
  if v_tax_id is not null then
   select * into v_tc from public.tax_codes where id=v_tax_id and organization_id=p_organization_id and active
    and transaction_kind=case when v_kind='customer' then 'sale' else 'purchase' end;
   if not found then raise exception 'Invalid tax code'; end if;
   v_rate:=v_tc.rate_bps;
  else v_rate:=coalesce((v_line->>'tax_rate_bps')::integer,0);end if;
  if v_rate not between 0 and 2500 then raise exception 'Invalid rate'; end if;
  v_amount:=round(v_qty*v_price,2);v_tax:=round(v_amount*v_rate/10000,2);
  v_recoverable:=case when v_kind='vendor' then
    case when v_tax_id is null then v_tax else round(v_tax*v_tc.recoverable_bps/10000,2) end else 0 end;
  v_subtotal:=v_subtotal+v_amount;v_taxes:=v_taxes+v_tax;
  insert into public.financial_document_lines(
   organization_id,document_id,position,description,quantity,unit_price,tax_rate_bps,
   amount,tax_amount,account_id,tax_code_id,tax_classification,recoverable_tax)
  values(p_organization_id,p_document_id,v_pos,trim(v_line->>'description'),v_qty,v_price,
   v_rate,v_amount,v_tax,v_acc,v_tax_id,
   case when v_tax_id is null then 'manual' else v_tc.classification end,v_recoverable);
 end loop;
 if v_subtotal+v_taxes<=0 then raise exception 'Document total must exceed zero'; end if;
 update public.financial_documents set subtotal=v_subtotal,tax_total=v_taxes,memo=coalesce(p_memo,''),
  due_date=p_due_date where id=p_document_id and organization_id=p_organization_id;
 return p_document_id;
end $$;

-- Table grants remain SELECT-only; all client mutations go through RLS-aware RPCs.
revoke all on function public.create_tax_code(uuid,text,text,text,text,integer,integer) from public,anon;
revoke all on function public.void_financial_draft(uuid,uuid,text) from public,anon;
revoke all on function public.replace_financial_draft(uuid,uuid,jsonb,text,date) from public,anon;
grant execute on function public.create_tax_code(uuid,text,text,text,text,integer,integer),
 public.void_financial_draft(uuid,uuid,text),public.replace_financial_draft(uuid,uuid,jsonb,text,date)
 to authenticated;
