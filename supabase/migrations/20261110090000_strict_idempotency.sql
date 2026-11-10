-- Reject conflicting payment replay even if a user reuses a UUID by accident.
-- Rename the original Phase 2 function, keeping its posting logic intact.
alter function public.record_document_payment(uuid,uuid,numeric,date,text,uuid)
 rename to record_document_payment_legacy;
revoke all on function public.record_document_payment_legacy(uuid,uuid,numeric,date,text,uuid)
 from public,anon,authenticated;

create function public.record_document_payment(
 p_organization_id uuid,p_document_id uuid,p_amount numeric,
 p_payment_date date,p_reference text,p_idempotency_key uuid
) returns uuid language plpgsql security definer set search_path=''
as $$
declare existing public.document_payments%rowtype;
begin
 if not public.has_org_write(p_organization_id) then raise exception 'Not authorized'; end if;
 if p_idempotency_key is null or p_payment_date is null or
    p_amount is null or p_amount<=0 or scale(p_amount)>2 or
    length(coalesce(p_reference,''))>100 then
    raise exception 'Invalid payment request'; end if;
 -- Serialize idempotency checks with posting for this tenant.
 perform 1 from public.organizations where id=p_organization_id for update;
 select * into existing from public.document_payments
 where organization_id=p_organization_id and idempotency_key=p_idempotency_key;
 if found then
   if existing.document_id<>p_document_id or existing.amount<>p_amount
      or existing.payment_date<>p_payment_date or
      existing.reference is distinct from nullif(trim(p_reference),'')
   then raise exception 'Idempotency key reused with different payment details'; end if;
   return existing.id;
 end if;
 return public.record_document_payment_legacy(
  p_organization_id,p_document_id,p_amount,p_payment_date,p_reference,p_idempotency_key);
end $$;
revoke all on function public.record_document_payment(uuid,uuid,numeric,date,text,uuid)
 from public,anon;
grant execute on function public.record_document_payment(uuid,uuid,numeric,date,text,uuid)
 to authenticated;
