-- Milestone 9: foreign-currency denomination of CAD-posted invoices/bills.
-- Reporting remains CAD, with foreign amount tracked solely for settlement.
-- Realized FX difference posts to separate gain/loss accounts. Does not perform
-- IAS 21 period-end revaluation or convert native foreign-currency invoice lines.
alter table public.financial_documents
 add column document_currency char(3) not null default 'CAD'
 check(document_currency ~ '^[A-Z]{3}$'),
 add column foreign_total numeric(20,2) check(foreign_total>0),
 add column recognition_rate_cad numeric(20,8) check(recognition_rate_cad>0),
 add constraint financial_foreign_complete check(
 (document_currency='CAD' and foreign_total is null and recognition_rate_cad is null)
 or (document_currency<>'CAD' and foreign_total is not null
     and recognition_rate_cad is not null));
create table public.foreign_document_payments(
 organization_id uuid not null,
 payment_id uuid not null,
 document_id uuid not null,
 currency_code char(3) not null,
 foreign_amount numeric(20,2) not null check(foreign_amount>0),
 bank_cad_amount numeric(20,2) not null check(bank_cad_amount>0),
 cad_book_amount numeric(20,2) not null check(cad_book_amount>0),
 realized_fx_gain numeric(20,2) not null default 0,
 realized_fx_loss numeric(20,2) not null default 0,
 created_at timestamptz not null default now(),
 primary key(organization_id,payment_id),
 foreign key(organization_id,payment_id) references public.document_payments(organization_id,id),
 foreign key(organization_id,document_id) references public.financial_documents(organization_id,id),
 check((realized_fx_gain=0 or realized_fx_loss=0) and realized_fx_gain>=0 and realized_fx_loss>=0)
);
alter table public.foreign_document_payments enable row level security;
create policy foreign_document_payments_read on public.foreign_document_payments
 for select to authenticated using(public.has_org_access(organization_id));
revoke all on public.foreign_document_payments from public,anon,authenticated;
grant select on public.foreign_document_payments to authenticated;
insert into public.accounts(organization_id,code,name,account_type,normal_balance)
select o.id,'4400','Realized Foreign Exchange Gain','revenue','credit'
from public.organizations o where not exists(select 1 from public.accounts a where a.organization_id=o.id and a.code='4400');
insert into public.accounts(organization_id,code,name,account_type,normal_balance)
select o.id,'5400','Realized Foreign Exchange Loss','expense','debit'
from public.organizations o where not exists(select 1 from public.accounts a where a.organization_id=o.id and a.code='5400');
create function private.seed_fx_accounts() returns trigger language plpgsql set search_path=''
as $$
begin
 if new.code='5000' and new.account_type='expense' then
  insert into public.accounts(organization_id,code,name,account_type,normal_balance)
  values(new.organization_id,'4400','Realized Foreign Exchange Gain','revenue','credit'),
        (new.organization_id,'5400','Realized Foreign Exchange Loss','expense','debit')
  on conflict(organization_id,code) do nothing;
 end if;
 return new;
end $$;
create trigger seed_fx_accounts after insert on public.accounts
 for each row execute function private.seed_fx_accounts();
revoke all on function private.seed_fx_accounts() from public,anon,authenticated;

create function public.denominate_draft_in_foreign_currency(
 p_org uuid,p_document uuid,p_currency text,p_foreign_total numeric,p_book_rate numeric
) returns void language plpgsql security definer set search_path=''
as $$
declare d public.financial_documents%rowtype;v_role text;
begin
 select role into v_role from public.organization_members
 where organization_id=p_org and user_id=auth.uid();
 if v_role is null or v_role not in ('owner','administrator','accountant')
 then raise exception 'Foreign invoice denomination requires accountant or administrator';end if;
 if p_currency is null or p_currency !~ '^[A-Z]{3}$' or p_currency='CAD'
 or p_foreign_total is null or p_foreign_total<=0 or scale(p_foreign_total)>2
 or p_book_rate is null or p_book_rate<=0 or scale(p_book_rate)>8
 then raise exception 'Invalid foreign currency reference';end if;
 perform 1 from public.organizations where id=p_org for update;
 select * into d from public.financial_documents where organization_id=p_org
 and id=p_document and status='draft' and document_type in ('invoice','bill') for update;
 if not found then raise exception 'Only draft invoices or bills can be denominated';end if;
 if round(p_foreign_total*p_book_rate,2)<>d.total then
  raise exception 'CAD document total must equal foreign total multiplied by book rate';end if;
 update public.financial_documents set document_currency=p_currency,
  foreign_total=p_foreign_total,recognition_rate_cad=p_book_rate where id=p_document;
 perform private.write_audit(p_org,'fx.document_denominated','financial_document',p_document,
 jsonb_build_object('currency',p_currency,'foreign_amount',p_foreign_total,
 'book_rate',p_book_rate));
end $$;

-- Prevent standard CAD payment and refund APIs from corrupting FX movement.
alter function public.record_document_payment(uuid,uuid,numeric,date,text,uuid)
 rename to record_document_payment_cad_legacy;
create function public.record_document_payment(
 p_organization_id uuid,p_document_id uuid,p_amount numeric,
 p_payment_date date,p_reference text,p_idempotency_key uuid
) returns uuid language plpgsql security definer set search_path=''
as $$
begin
 if not public.has_org_write(p_organization_id) then raise exception 'Not authorized';end if;
 if exists(select 1 from public.financial_documents where organization_id=p_organization_id
   and id=p_document_id and document_currency<>'CAD') then
  raise exception 'Foreign-denominated documents require the explicit FX payment workflow';end if;
 return public.record_document_payment_cad_legacy(p_organization_id,p_document_id,
  p_amount,p_payment_date,p_reference,p_idempotency_key);
end $$;
revoke all on function public.record_document_payment_cad_legacy(uuid,uuid,numeric,date,text,uuid)
 from public,anon,authenticated;

alter function public.refund_document_payment(uuid,uuid,numeric,date,text,uuid)
 rename to refund_document_payment_cad_legacy;
create function public.refund_document_payment(
 p_organization_id uuid,p_payment_id uuid,p_amount numeric,p_refund_date date,
 p_reason text,p_idempotency_key uuid
) returns uuid language plpgsql security definer set search_path=''
as $$
begin
 if not public.has_org_write(p_organization_id) then raise exception 'Not authorized';end if;
 if exists(select 1 from public.foreign_document_payments where organization_id=p_organization_id
  and payment_id=p_payment_id) then
 raise exception 'Foreign-currency refunds need explicit FX gain/loss reversal and accountant review';end if;
 return public.refund_document_payment_cad_legacy(p_organization_id,p_payment_id,
 p_amount,p_refund_date,p_reason,p_idempotency_key);
end $$;
revoke all on function public.refund_document_payment_cad_legacy(uuid,uuid,numeric,date,text,uuid)
 from public,anon,authenticated;

create function public.record_foreign_currency_payment(
 p_org uuid,p_doc uuid,p_foreign_amount numeric,p_cad_book_amount numeric,
 p_bank_cad_amount numeric,p_date date,p_reference text,p_key uuid
) returns uuid language plpgsql security definer set search_path=''
as $$
declare d public.financial_documents%rowtype;v_existing public.document_payments%rowtype;
 v_fx public.foreign_document_payments%rowtype;v_ar uuid;v_bank uuid;v_gain uuid;v_loss uuid;
 v_variance numeric(20,2);v_fx_gain numeric(20,2):=0;v_fx_loss numeric(20,2):=0;
 v_paid_foreign numeric;v_lines jsonb:='[]'::jsonb;v_journal uuid;v_id uuid;
begin
 if not public.has_org_write(p_org) then raise exception 'Not authorized';end if;
 if p_key is null or p_date is null or p_foreign_amount is null or p_cad_book_amount is null
 or p_bank_cad_amount is null or p_foreign_amount<=0 or p_cad_book_amount<=0
 or p_bank_cad_amount<=0 or scale(p_foreign_amount)>2 or scale(p_cad_book_amount)>2
 or scale(p_bank_cad_amount)>2 or length(coalesce(p_reference,''))>100
 then raise exception 'Invalid foreign payment';end if;
 perform 1 from public.organizations where id=p_org for update;
 select * into v_existing from public.document_payments
 where organization_id=p_org and idempotency_key=p_key;
 if found then
  select * into v_fx from public.foreign_document_payments
   where organization_id=p_org and payment_id=v_existing.id;
  if not found or v_existing.document_id<>p_doc or v_existing.amount<>p_cad_book_amount
   or v_existing.payment_date<>p_date or v_fx.foreign_amount<>p_foreign_amount
   or v_fx.bank_cad_amount<>p_bank_cad_amount
   then raise exception 'Conflicting FX settlement idempotency replay';end if;
  return v_existing.id;
 end if;
 select * into d from public.financial_documents where organization_id=p_org
 and id=p_doc and status='posted' and document_type in ('invoice','bill')
 and document_currency<>'CAD' for update;
 if not found then raise exception 'Posted foreign-denominated invoice/bill required';end if;
 if p_date<d.issue_date or p_cad_book_amount>public.document_outstanding(p_org,p_doc)
 then raise exception 'Payment date or CAD outstanding balance invalid';end if;
 select coalesce(sum(foreign_amount),0) into v_paid_foreign
 from public.foreign_document_payments where organization_id=p_org and document_id=p_doc;
 if p_foreign_amount>d.foreign_total-v_paid_foreign then
 raise exception 'FX settlement exceeds original foreign amount';end if;
 select id into v_ar from public.accounts where organization_id=p_org
  and code=case when d.document_type='invoice' then '1100' else '2000' end and is_active;
 select id into v_bank from public.accounts where organization_id=p_org and code='1000' and is_active;
 select id into v_gain from public.accounts where organization_id=p_org and code='4400' and is_active;
 select id into v_loss from public.accounts where organization_id=p_org and code='5400' and is_active;
 if v_ar is null or v_bank is null or v_gain is null or v_loss is null
 then raise exception 'Missing FX posting accounts';end if;
 -- For receipts, bank proceeds > CAD receivable means gain.
 -- For supplier payments, CAD paid > CAD payable means loss.
 v_variance:=case when d.document_type='invoice'
  then p_bank_cad_amount-p_cad_book_amount
  else p_cad_book_amount-p_bank_cad_amount end;
 v_fx_gain:=greatest(0,v_variance);v_fx_loss:=greatest(0,-v_variance);
 if d.document_type='invoice' then
  v_lines:=jsonb_build_array(
   jsonb_build_object('account_id',v_bank,'debit',p_bank_cad_amount,'credit',0),
   jsonb_build_object('account_id',v_ar,'debit',0,'credit',p_cad_book_amount));
 else
  v_lines:=jsonb_build_array(
   jsonb_build_object('account_id',v_ar,'debit',p_cad_book_amount,'credit',0),
   jsonb_build_object('account_id',v_bank,'debit',0,'credit',p_bank_cad_amount));
 end if;
 if v_fx_gain>0 then v_lines:=v_lines||jsonb_build_array(
   jsonb_build_object('account_id',v_gain,'debit',0,'credit',v_fx_gain));end if;
 if v_fx_loss>0 then v_lines:=v_lines||jsonb_build_array(
   jsonb_build_object('account_id',v_loss,'debit',v_fx_loss,'credit',0));end if;
 v_journal:=private.post_accounting_journal_internal('payment',p_org,p_date,
 'Foreign-currency invoice settlement','FX-PAYMENT',p_key,v_lines);
 insert into public.document_payments(organization_id,document_id,amount,payment_date,
  reference,idempotency_key,journal_entry_id,created_by)
 values(p_org,p_doc,p_cad_book_amount,p_date,nullif(trim(p_reference),''),p_key,v_journal,auth.uid())
 returning id into v_id;
 insert into public.foreign_document_payments(organization_id,payment_id,document_id,
 currency_code,foreign_amount,bank_cad_amount,cad_book_amount,realized_fx_gain,realized_fx_loss)
 values(p_org,v_id,p_doc,d.document_currency,p_foreign_amount,
 p_bank_cad_amount,p_cad_book_amount,v_fx_gain,v_fx_loss);
 perform private.write_audit(p_org,'fx.payment_recorded','foreign_document_payment',v_id,
 jsonb_build_object('currency',d.document_currency,'foreign_amount',p_foreign_amount,
  'cad_book',p_cad_book_amount,'cad_bank',p_bank_cad_amount,
  'gain',v_fx_gain,'loss',v_fx_loss));
 return v_id;
end $$;

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
 or exists(select 1 from public.foreign_document_payments fx
   join public.document_payments p on p.organization_id=fx.organization_id and p.id=fx.payment_id
   where fx.organization_id=p_organization_id and p.journal_entry_id=p_journal_id)
 then raise exception 'Source accounting journal cannot be manually reversed';end if;
 return public.reverse_manual_journal_legacy(p_organization_id,p_journal_id,p_reversal_date,p_reason);
end $$;
revoke all on function public.denominate_draft_in_foreign_currency(uuid,uuid,text,numeric,numeric),
 public.record_document_payment(uuid,uuid,numeric,date,text,uuid),
 public.refund_document_payment(uuid,uuid,numeric,date,text,uuid),
 public.record_foreign_currency_payment(uuid,uuid,numeric,numeric,numeric,date,text,uuid) from public,anon;
grant execute on function public.denominate_draft_in_foreign_currency(uuid,uuid,text,numeric,numeric),
 public.record_document_payment(uuid,uuid,numeric,date,text,uuid),
 public.refund_document_payment(uuid,uuid,numeric,date,text,uuid),
 public.record_foreign_currency_payment(uuid,uuid,numeric,numeric,numeric,date,text,uuid) to authenticated;
