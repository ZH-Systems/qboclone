-- Milestone 7 OCR subscription metering and failure rollback.
begin;
insert into auth.users(id,email,email_confirmed_at,role,aud,created_at,updated_at) values
('77777777-7777-4777-8777-777777777781','ocr-owner@example.invalid',now(),'authenticated','authenticated',now(),now());
set local role authenticated;
do $qa$
declare v_org uuid;v_receipt uuid;
begin
 perform set_config('request.jwt.claim.sub','77777777-7777-4777-8777-777777777781',true);
 v_org:=public.create_organization('OCR Quota QA');
 v_receipt:=gen_random_uuid();
 perform set_config('qa.ocr_org',v_org::text,false);
 perform set_config('qa.ocr_receipt',v_receipt::text,false);
 perform public.register_receipt_document(v_org,v_receipt,
  'organizations/'||v_org||'/'||v_receipt,'sample.png','image/png',repeat('b',64),256);
end $qa$;
reset role;
set local role service_role;
do $qa$
declare v_failed boolean:=false;v_org uuid:=current_setting('qa.ocr_org')::uuid;
 v_receipt uuid:=current_setting('qa.ocr_receipt')::uuid;
begin
 begin perform public.begin_receipt_ocr(v_org,v_receipt);
 exception when others then v_failed:=true;end;
 if not v_failed then raise exception 'OCR allowed without paid plan';end if;
end $qa$;
reset role;
insert into public.organization_subscriptions(organization_id,plan_code,status)
values(current_setting('qa.ocr_org')::uuid,'business','active');
set local role service_role;
do $qa$
declare v_org uuid:=current_setting('qa.ocr_org')::uuid;
 v_receipt uuid:=current_setting('qa.ocr_receipt')::uuid;
 v_used bigint;v_failed boolean:=false;
begin
 perform public.begin_receipt_ocr(v_org,v_receipt);
 select units into v_used from public.organization_usage_monthly
 where organization_id=v_org and metric='receipt_ocr';
 if v_used<>1 then raise exception 'OCR reservation not charged';end if;
 begin perform public.begin_receipt_ocr(v_org,v_receipt);
 exception when others then v_failed:=true;end;
 if not v_failed then raise exception 'Concurrent OCR attempt allowed';end if;
 perform public.save_receipt_ocr_result(v_org,v_receipt,'failed',
  '{"message":"Provider rejected request"}'::jsonb);
 select units into v_used from public.organization_usage_monthly
 where organization_id=v_org and metric='receipt_ocr';
 if v_used<>0 then raise exception 'Failed OCR did not refund quota';end if;
 perform public.begin_receipt_ocr(v_org,v_receipt);
 perform public.save_receipt_ocr_result(v_org,v_receipt,'completed',
  '{"text":"Sample text","suggestions":{"confidence":"unverified"}}'::jsonb);
 select units into v_used from public.organization_usage_monthly
 where organization_id=v_org and metric='receipt_ocr';
 if v_used<>1 then raise exception 'Completed OCR did not charge quota';end if;
 v_failed:=false;
 begin perform public.begin_receipt_ocr(v_org,v_receipt);
 exception when others then v_failed:=true;end;
 if not v_failed then raise exception 'Completed OCR was charged again';end if;
 raise notice 'MILESTONE 7 OCR QUOTA TEST PASSED';
end $qa$;
reset role;
rollback;
