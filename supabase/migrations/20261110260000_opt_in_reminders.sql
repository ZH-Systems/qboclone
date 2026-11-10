-- Milestone 7: opt-in payment reminders with audited, idempotent worker claims.
-- No reminders are sent until an owner/administrator enables the policy.
create table public.invoice_reminder_policies(
 organization_id uuid primary key references public.organizations(id) on delete restrict,
 enabled boolean not null default false,
 days_overdue integer not null default 3 check(days_overdue between 1 and 90),
 cooldown_days integer not null default 7 check(cooldown_days between 1 and 90),
 updated_at timestamptz not null default now(),
 updated_by uuid not null references auth.users(id)
);
create table public.invoice_reminder_states(
 organization_id uuid not null,
 invoice_id uuid not null,
 reserved_at timestamptz,
 next_eligible_on date,
 last_sent_at timestamptz,
 attempt_count integer not null default 0,
 primary key(organization_id,invoice_id),
 foreign key(organization_id,invoice_id)
  references public.financial_documents(organization_id,id)
);
alter table public.invoice_reminder_policies enable row level security;
alter table public.invoice_reminder_states enable row level security;
create policy reminder_policies_read on public.invoice_reminder_policies
 for select to authenticated using(public.has_org_access(organization_id));
create policy reminder_states_read on public.invoice_reminder_states
 for select to authenticated using(public.has_org_access(organization_id));
revoke all on public.invoice_reminder_policies,public.invoice_reminder_states from public,anon,authenticated;
grant select on public.invoice_reminder_policies,public.invoice_reminder_states to authenticated;

create function public.configure_invoice_reminders(p_org uuid,p_enabled boolean,
 p_days_overdue integer,p_cooldown_days integer)
returns void language plpgsql security definer set search_path=''
as $$
begin
 if p_enabled is null or p_days_overdue is null or
  p_days_overdue not between 1 and 90 or
  p_cooldown_days is null or p_cooldown_days not between 1 and 90
 then raise exception 'Invalid reminder policy';end if;
 if not exists(select 1 from public.organization_members
 where organization_id=p_org and user_id=auth.uid() and role in ('owner','administrator'))
 then raise exception 'Only business administrators can manage automatic reminders';end if;
 perform 1 from public.organizations where id=p_org for update;
 insert into public.invoice_reminder_policies(organization_id,enabled,days_overdue,
  cooldown_days,updated_by)
 values(p_org,p_enabled,p_days_overdue,p_cooldown_days,auth.uid())
 on conflict(organization_id) do update
 set enabled=excluded.enabled,days_overdue=excluded.days_overdue,
 cooldown_days=excluded.cooldown_days,updated_at=now(),updated_by=excluded.updated_by;
 perform private.write_audit(p_org,'automation.reminder_policy_changed','organization',p_org,
  jsonb_build_object('enabled',p_enabled,'days_overdue',p_days_overdue,'cooldown_days',p_cooldown_days));
end $$;

-- Service-only batch claim. No emails sent from database. Outstanding is derived
-- with payment, refund, credit, deposit and writeoff adjustments, not cached totals.
create function public.claim_due_invoice_reminders(p_limit integer default 20)
returns table(organization_id uuid,invoice_id uuid,invoice_number text,
 contact_email text,organization_name text,cooldown_days integer)
language plpgsql security definer set search_path=''
as $$
declare v record;v_outstanding numeric;v_state public.invoice_reminder_states%rowtype;
 v_claimed integer:=0;
begin
 if p_limit is null or p_limit not between 1 and 50 then
  raise exception 'Invalid reminder batch size';end if;
 for v in
 select d.organization_id,d.id,d.document_number,d.total,d.due_date,
  c.email,o.name,p.cooldown_days
 from public.invoice_reminder_policies p
 join public.organizations o on o.id=p.organization_id
 join public.financial_documents d on d.organization_id=p.organization_id
 join public.contacts c on c.organization_id=d.organization_id and c.id=d.contact_id
 where p.enabled and d.status='posted' and d.document_type='invoice'
 and d.due_date<=current_date-p.days_overdue
 and c.email is not null and c.email<>''
 order by d.due_date,d.id
 limit 200
 loop
  exit when v_claimed>=p_limit;
  -- Lock the business to serialize any concurrent claim/processing.
  perform 1 from public.organizations where id=v.organization_id for update skip locked;
  if not found then continue;end if;
  select * into v_state from public.invoice_reminder_states st
    where st.organization_id=v.organization_id and st.invoice_id=v.id for update;
  if found and ((v_state.reserved_at is not null and
    v_state.reserved_at>now()-interval '30 minutes')
   or (v_state.next_eligible_on is not null and v_state.next_eligible_on>current_date))
  then continue;end if;
  select (v.total
   -coalesce((select sum(p.amount) from public.document_payments p
      where p.organization_id=v.organization_id and p.document_id=v.id),0)
   +coalesce((select sum(r.amount) from public.payment_refunds r
      join public.document_payments p on p.organization_id=r.organization_id and p.id=r.original_payment_id
      where p.organization_id=v.organization_id and p.document_id=v.id),0)
   -coalesce((select sum(c.total) from public.financial_documents c
      where c.organization_id=v.organization_id and c.source_document_id=v.id
      and c.status='posted' and c.document_type='credit_note'),0)
   -coalesce((select sum(w.amount) from public.document_writeoffs w
      where w.organization_id=v.organization_id and w.document_id=v.id),0)
   -coalesce((select sum(a.amount) from public.deposit_applications a
      where a.organization_id=v.organization_id and a.invoice_id=v.id),0))
  into v_outstanding;
  if v_outstanding<=0 then continue;end if;
  insert into public.invoice_reminder_states(organization_id,invoice_id,reserved_at,attempt_count)
  values(v.organization_id,v.id,now(),1)
  on conflict(organization_id,invoice_id) do update
    set reserved_at=now(),attempt_count=public.invoice_reminder_states.attempt_count+1;
  organization_id:=v.organization_id;
  invoice_id:=v.id;invoice_number:=v.document_number;
  contact_email:=v.email;organization_name:=v.name;cooldown_days:=v.cooldown_days;
  v_claimed:=v_claimed+1;
  return next;
 end loop;
end $$;

create function public.finish_invoice_reminder(p_org uuid,p_invoice uuid,
 p_succeeded boolean,p_provider_id text)
returns void language plpgsql security definer set search_path=''
as $$
declare v_state public.invoice_reminder_states%rowtype;v_policy public.invoice_reminder_policies%rowtype;
 v_contact text;v_owner uuid;v_delivery uuid;
begin
 if p_succeeded is null or (p_provider_id is not null and length(p_provider_id)>255)
 then raise exception 'Invalid reminder result';end if;
 perform 1 from public.organizations where id=p_org for update;
 select * into v_state from public.invoice_reminder_states
 where organization_id=p_org and invoice_id=p_invoice for update;
 if not found or v_state.reserved_at is null then
  raise exception 'Reminder has no pending claim';end if;
 select * into v_policy from public.invoice_reminder_policies where organization_id=p_org;
 select c.email into v_contact from public.financial_documents d
 join public.contacts c on c.organization_id=d.organization_id and c.id=d.contact_id
 where d.organization_id=p_org and d.id=p_invoice;
 select user_id into v_owner from public.organization_members where
  organization_id=p_org and role='owner' limit 1;
 if v_owner is null or v_contact is null then raise exception 'Reminder owner or contact unavailable';end if;
 update public.invoice_reminder_states set reserved_at=null,
  next_eligible_on=case when p_succeeded then current_date+v_policy.cooldown_days
   else current_date+1 end,
  last_sent_at=case when p_succeeded then now() else last_sent_at end
 where organization_id=p_org and invoice_id=p_invoice;
 insert into public.document_deliveries(organization_id,document_id,recipient_email,
  delivery_kind,message_id,status,sent_by)
 values(p_org,p_invoice,v_contact,'payment_reminder',p_provider_id,
  case when p_succeeded then 'sent' else 'failed' end,v_owner)
 returning id into v_delivery;
 perform private.write_audit(p_org,'automation.reminder_attempt','delivery',v_delivery,
  jsonb_build_object('invoice_id',p_invoice,'success',p_succeeded));
end $$;
revoke all on function public.configure_invoice_reminders(uuid,boolean,integer,integer)
 from public,anon;
grant execute on function public.configure_invoice_reminders(uuid,boolean,integer,integer)
 to authenticated;
revoke all on function public.claim_due_invoice_reminders(integer),
 public.finish_invoice_reminder(uuid,uuid,boolean,text) from public,anon,authenticated;
grant execute on function public.claim_due_invoice_reminders(integer),
 public.finish_invoice_reminder(uuid,uuid,boolean,text) to service_role;
