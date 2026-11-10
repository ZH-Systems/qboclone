-- Milestone 7 reminders: explicit opt-in, claim idempotency, cooldown and RLS.
begin;
insert into auth.users(id,email,email_confirmed_at,role,aud,created_at,updated_at) values
 ('77777777-7777-4777-8777-777777777791','reminder-owner@example.invalid',now(),'authenticated','authenticated',now(),now()),
 ('77777777-7777-4777-8777-777777777792','reminder-outsider@example.invalid',now(),'authenticated','authenticated',now(),now());
set local role authenticated;
do $qa$
declare v_org uuid;v_contact uuid;v_invoice uuid;v_failed boolean;
begin
 perform set_config('request.jwt.claim.sub','77777777-7777-4777-8777-777777777791',true);
 v_org:=public.create_organization('Reminder Test Business');
 v_contact:=public.create_contact(v_org,'customer','Late Customer','overdue@example.invalid');
 v_invoice:=public.create_financial_document(v_org,v_contact,'invoice',current_date-10,
  current_date-10,'Overdue test invoice',null,jsonb_build_array(
   jsonb_build_object('description','Service','quantity',1,'unit_price',100,'tax_rate_bps',0)));
 perform public.post_financial_document(v_org,v_invoice);
 perform set_config('qa.reminder_org',v_org::text,false);
 perform set_config('qa.reminder_invoice',v_invoice::text,false);
 v_failed:=false;
 begin perform public.claim_due_invoice_reminders(10);
 exception when others then v_failed:=true;end;
 if not v_failed then raise exception 'Authenticated user claimed service reminders';end if;
 perform public.configure_invoice_reminders(v_org,true,3,7);
 perform set_config('request.jwt.claim.sub','77777777-7777-4777-8777-777777777792',true);
 v_failed:=false;
 begin perform public.configure_invoice_reminders(v_org,false,3,7);
 exception when others then v_failed:=true;end;
 if not v_failed then raise exception 'Outsider changed reminder policy';end if;
 if exists(select 1 from public.invoice_reminder_policies where organization_id=v_org)
 then raise exception 'Cross-tenant reminder policy leak';end if;
end $qa$;
reset role;
set local role service_role;
do $qa$
declare v_org uuid:=current_setting('qa.reminder_org')::uuid;
 v_invoice uuid:=current_setting('qa.reminder_invoice')::uuid;
 v_count integer;v_failed boolean:=false;
begin
 select count(*) into v_count from public.claim_due_invoice_reminders(20)
 where invoice_id=v_invoice and organization_id=v_org;
 if v_count<>1 then raise exception 'Expected one claimed overdue invoice';end if;
 select count(*) into v_count from public.claim_due_invoice_reminders(20);
 if v_count<>0 then raise exception 'Duplicate reserved invoice claim';end if;
 perform public.finish_invoice_reminder(v_org,v_invoice,true,'test-resend-id');
 select count(*) into v_count from public.claim_due_invoice_reminders(20);
 if v_count<>0 then raise exception 'Reminder cooldown not enforced';end if;
 if not exists(select 1 from public.document_deliveries
  where organization_id=v_org and document_id=v_invoice
  and delivery_kind='payment_reminder' and status='sent') then
  raise exception 'No audited automatic reminder delivery';end if;
 begin perform public.finish_invoice_reminder(v_org,v_invoice,true,'duplicate');
 exception when others then v_failed:=true;end;
 if not v_failed then raise exception 'Duplicate finish was allowed';end if;
 raise notice 'MILESTONE 7 REMINDER REGRESSION PASSED';
end $qa$;
reset role;
rollback;
