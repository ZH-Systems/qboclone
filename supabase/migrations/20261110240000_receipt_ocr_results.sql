-- Provider OCR output is untrusted and advisory; the service role may record it
-- after validating an authenticated user's tenant membership in the API.
create function public.save_receipt_ocr_result(p_org uuid,p_receipt uuid,
 p_status text,p_data jsonb)
returns void language plpgsql security definer set search_path=''
as $$
begin
 if p_status not in ('completed','failed') or p_data is null or
 jsonb_typeof(p_data)<>'object' or octet_length(p_data::text)>60000
 then raise exception 'Invalid OCR result';end if;
 update public.receipt_documents set extraction_status=p_status,extraction_data=p_data
 where id=p_receipt and organization_id=p_org;
 if not found then raise exception 'Receipt not found';end if;
 perform private.write_audit(p_org,'receipt.ocr_completed','receipt',p_receipt,
 jsonb_build_object('status',p_status));
end $$;
revoke all on function public.save_receipt_ocr_result(uuid,uuid,text,jsonb)
 from public,anon,authenticated;
grant execute on function public.save_receipt_ocr_result(uuid,uuid,text,jsonb) to service_role;
