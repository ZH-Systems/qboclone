-- OCR is a user-requested paid integration; enforce per-plan monthly usage
-- in the database, including concurrent requests, rather than trusting UI counts.
alter table public.organization_usage_monthly
 drop constraint if exists organization_usage_monthly_metric_check;
alter table public.organization_usage_monthly add constraint organization_usage_monthly_metric_check
 check(metric in ('bank_import_rows','receipt_ocr'));
alter table public.receipt_documents add column ocr_reserved_at timestamptz;

create function public.begin_receipt_ocr(p_org uuid,p_receipt uuid)
returns void language plpgsql security definer set search_path=''
as $$
declare v_limit integer;v_used bigint;v_receipt public.receipt_documents%rowtype;
 v_month date;v_old_month date;
begin
 perform 1 from public.organizations where id=p_org for update;
 if not found then raise exception 'Organization not found';end if;
 select * into v_receipt from public.receipt_documents
  where organization_id=p_org and id=p_receipt for update;
 if not found then raise exception 'Receipt not found';end if;
 if v_receipt.extraction_status='completed' then
  raise exception 'Receipt OCR was already completed';end if;
 if v_receipt.extraction_status='pending' then
  if v_receipt.ocr_reserved_at>now()-interval '30 minutes' then
   raise exception 'Receipt OCR is already in progress';end if;
  v_old_month:=date_trunc('month',v_receipt.ocr_reserved_at at time zone 'UTC')::date;
  update public.organization_usage_monthly set units=greatest(0,units-1),updated_at=now()
  where organization_id=p_org and month_start=v_old_month and metric='receipt_ocr';
 end if;
 select (p.features->>'receipt_ocr_monthly')::integer into v_limit
 from public.organization_subscriptions s join public.subscription_plans p on p.code=s.plan_code and p.active
 where s.organization_id=p_org and s.status in ('active','trialing');
 v_limit:=coalesce(v_limit,0);
 if v_limit<=0 then raise exception 'Receipt OCR requires an active plan with OCR entitlement';end if;
 v_month:=date_trunc('month',now() at time zone 'UTC')::date;
 select units into v_used from public.organization_usage_monthly
 where organization_id=p_org and month_start=v_month and metric='receipt_ocr';
 if coalesce(v_used,0)>=v_limit then raise exception 'Monthly OCR allowance exhausted';end if;
 insert into public.organization_usage_monthly(organization_id,month_start,metric,units)
 values(p_org,v_month,'receipt_ocr',1)
 on conflict(organization_id,month_start,metric)
 do update set units=public.organization_usage_monthly.units+1,updated_at=now();
 update public.receipt_documents set extraction_status='pending',ocr_reserved_at=now(),
  extraction_data='{}'::jsonb where organization_id=p_org and id=p_receipt;
end $$;

create or replace function public.save_receipt_ocr_result(p_org uuid,p_receipt uuid,
 p_status text,p_data jsonb)
returns void language plpgsql security definer set search_path=''
as $$
declare v_receipt public.receipt_documents%rowtype;v_month date;
begin
 if p_status not in ('completed','failed') or p_data is null or
  jsonb_typeof(p_data)<>'object' or octet_length(p_data::text)>60000
 then raise exception 'Invalid OCR result';end if;
 perform 1 from public.organizations where id=p_org for update;
 select * into v_receipt from public.receipt_documents
 where id=p_receipt and organization_id=p_org for update;
 if not found or v_receipt.extraction_status<>'pending' then
  raise exception 'No in-progress receipt OCR to complete';end if;
 update public.receipt_documents set extraction_status=p_status,extraction_data=p_data,
  ocr_reserved_at=null where id=p_receipt and organization_id=p_org;
 if p_status='failed' and v_receipt.ocr_reserved_at is not null then
  v_month:=date_trunc('month',v_receipt.ocr_reserved_at at time zone 'UTC')::date;
  update public.organization_usage_monthly set units=greatest(0,units-1),updated_at=now()
  where organization_id=p_org and month_start=v_month and metric='receipt_ocr';
 end if;
 perform private.write_audit(p_org,'receipt.ocr_completed','receipt',p_receipt,
 jsonb_build_object('status',p_status));
end $$;
revoke all on function public.begin_receipt_ocr(uuid,uuid) from public,anon,authenticated;
grant execute on function public.begin_receipt_ocr(uuid,uuid) to service_role;
