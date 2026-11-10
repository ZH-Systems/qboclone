-- Milestone 6: payment refunds and accurate receivable/payable outstanding calculations.
-- A refund undoes an allocated payment movement. To return goods, post the
-- corresponding credit document afterwards to offset the restored receivable.
create table public.payment_refunds(
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null references public.organizations(id) on delete restrict,
 original_payment_id uuid not null,
 refund_date date not null,
 amount numeric(20,2) not null check(amount>0),
 reason varchar(500) not null check(length(trim(reason))>=3),
 idempotency_key uuid not null,
 journal_entry_id uuid not null,
 created_at timestamptz not null default now(),
 created_by uuid not null references auth.users(id),
 unique(organization_id,id),
 unique(organization_id,idempotency_key),
 foreign key(organization_id,original_payment_id) references public.document_payments(organization_id,id),
 foreign key(organization_id,journal_entry_id) references public.journal_entries(organization_id,id)
);
create index payment_refunds_org_original_idx on public.payment_refunds(organization_id,original_payment_id);
alter table public.payment_refunds enable row level security;
create policy payment_refunds_visible on public.payment_refunds for select to authenticated
 using(public.has_org_access(organization_id));
revoke all on public.payment_refunds from public,anon,authenticated;
grant select on public.payment_refunds to authenticated;

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
         and c.status='posted' and c.document_type in ('credit_note','vendor_credit')),0))
 else 0 end
 from public.financial_documents d
 where d.organization_id=p_organization_id and d.id=p_document_id
   and public.has_org_access(d.organization_id)
$$;

-- Partial refunds are allowed only up to the remaining unrefunded amount
-- of a particular payment. Lock tenant, then payment, before posting.
create function public.refund_document_payment(
 p_organization_id uuid,p_payment_id uuid,p_amount numeric,p_refund_date date,
 p_reason text,p_idempotency_key uuid
) returns uuid language plpgsql security definer set search_path=''
as $$
declare p public.document_payments%rowtype;d public.financial_documents%rowtype;
 v_refund public.payment_refunds%rowtype;v_refunded numeric(20,2);
 v_bank uuid;v_ar uuid;v_lines jsonb;v_journal uuid;v_refund_id uuid;
begin
 if not public.has_org_write(p_organization_id) then raise exception 'Not authorized';end if;
 if p_payment_id is null or p_idempotency_key is null or p_refund_date is null
 or p_amount is null or p_amount<=0 or scale(p_amount)>2
 or p_reason is null or length(trim(p_reason)) not between 3 and 500 then
  raise exception 'Invalid refund details'; end if;
 perform 1 from public.organizations where id=p_organization_id for update;
 select * into v_refund from public.payment_refunds
  where organization_id=p_organization_id and idempotency_key=p_idempotency_key;
 if found then
  if v_refund.original_payment_id<>p_payment_id or v_refund.amount<>p_amount or
   v_refund.refund_date<>p_refund_date or v_refund.reason<>trim(p_reason) then
   raise exception 'Conflicting refund idempotency replay';end if;
  return v_refund.id;
 end if;
 select * into p from public.document_payments where
   organization_id=p_organization_id and id=p_payment_id for update;
 if not found then raise exception 'Original payment not found';end if;
 select * into d from public.financial_documents where
   organization_id=p_organization_id and id=p.document_id for update;
 if not found or d.status<>'posted' or d.document_type not in ('invoice','bill')
 then raise exception 'Payment source is not a posted invoice or bill';end if;
 select coalesce(sum(amount),0) into v_refunded from public.payment_refunds
 where organization_id=p_organization_id and original_payment_id=p_payment_id;
 if p_amount>p.amount-v_refunded then raise exception 'Refund exceeds unrefunded payment';end if;
 select id into strict v_bank from public.accounts where organization_id=p_organization_id
  and code='1000' and is_active;
 select id into strict v_ar from public.accounts where organization_id=p_organization_id
  and code=case when d.document_type='invoice' then '1100' else '2000' end and is_active;
 if d.document_type='invoice' then
  v_lines:=jsonb_build_array(
   jsonb_build_object('account_id',v_ar,'debit',p_amount,'credit',0),
   jsonb_build_object('account_id',v_bank,'debit',0,'credit',p_amount));
 else
  v_lines:=jsonb_build_array(
   jsonb_build_object('account_id',v_bank,'debit',p_amount,'credit',0),
   jsonb_build_object('account_id',v_ar,'debit',0,'credit',p_amount));
 end if;
 v_journal:=private.post_accounting_journal_internal('reversal',p_organization_id,
  p_refund_date,'Refund of '||d.document_number,left(trim(p_reason),80),
  p_idempotency_key,v_lines);
 insert into public.payment_refunds(organization_id,original_payment_id,refund_date,amount,
  reason,idempotency_key,journal_entry_id,created_by)
 values(p_organization_id,p_payment_id,p_refund_date,p_amount,trim(p_reason),
  p_idempotency_key,v_journal,auth.uid()) returning id into v_refund_id;
 perform private.write_audit(p_organization_id,'payment.refunded','payment_refund',v_refund_id,
  jsonb_build_object('payment_id',p_payment_id,'amount',p_amount,'document_id',d.id));
 return v_refund_id;
end $$;

-- Defend source-linked refund journals from arbitrary reversal.
create or replace function public.reverse_manual_journal(
 p_organization_id uuid,p_journal_id uuid,p_reversal_date date,p_reason text
) returns uuid language plpgsql security definer set search_path=''
as $$
begin
 if not public.has_org_write(p_organization_id) then raise exception 'Not authorized';end if;
 perform 1 from public.organizations where id=p_organization_id for update;
 if exists(select 1 from public.year_end_closures
  where organization_id=p_organization_id and closing_journal_id=p_journal_id)
 or exists(select 1 from public.payment_refunds
  where organization_id=p_organization_id and journal_entry_id=p_journal_id)
 then raise exception 'Financial closing and refund journals cannot be manually reversed';end if;
 return public.reverse_manual_journal_legacy(p_organization_id,p_journal_id,p_reversal_date,p_reason);
end $$;
revoke all on function public.refund_document_payment(uuid,uuid,numeric,date,text,uuid),
 public.reverse_manual_journal(uuid,uuid,date,text) from public,anon;
grant execute on function public.refund_document_payment(uuid,uuid,numeric,date,text,uuid),
 public.reverse_manual_journal(uuid,uuid,date,text) to authenticated;
