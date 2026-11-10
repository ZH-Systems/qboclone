-- Milestone 7: recurring document schedules, safe drafts and bank matching suggestions.
-- Scheduler is service_role only. It NEVER posts a recurring draft automatically.
create table public.recurring_document_rules(
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null references public.organizations(id) on delete restrict,
 source_document_id uuid not null,
 cadence text not null check(cadence in ('weekly','monthly')),
 next_run_date date not null,
 due_offset_days integer not null default 14 check(due_offset_days between 0 and 365),
 active boolean not null default true,
 created_by uuid not null references auth.users(id),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 unique(organization_id,id),
 foreign key(organization_id,source_document_id) references public.financial_documents(organization_id,id)
);
create index recurring_rules_due_idx on public.recurring_document_rules(next_run_date,id) where active;
create table public.recurring_document_runs(
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null,
 rule_id uuid not null,
 occurrence_date date not null,
 document_id uuid not null,
 processed_at timestamptz not null default now(),
 unique(organization_id,rule_id,occurrence_date),
 unique(organization_id,document_id),
 foreign key(organization_id,rule_id) references public.recurring_document_rules(organization_id,id),
 foreign key(organization_id,document_id) references public.financial_documents(organization_id,id)
);
alter table public.recurring_document_rules enable row level security;
alter table public.recurring_document_runs enable row level security;
create policy recurring_rule_select on public.recurring_document_rules
 for select to authenticated using(public.has_org_access(organization_id));
create policy recurring_runs_select on public.recurring_document_runs
 for select to authenticated using(public.has_org_access(organization_id));
revoke all on public.recurring_document_rules,public.recurring_document_runs from public,anon,authenticated;
grant select on public.recurring_document_rules,public.recurring_document_runs to authenticated;

create function public.create_recurring_document_rule(
 p_org uuid,p_source_document uuid,p_cadence text,p_first_date date,p_due_offset integer
) returns uuid language plpgsql security definer set search_path=''
as $$
declare v_id uuid;v_source public.financial_documents%rowtype;
begin
 if not public.has_org_write(p_org) then raise exception 'Not authorized';end if;
 if p_first_date is null or p_first_date<current_date or p_first_date>current_date+interval '5 years'
 or p_cadence not in ('weekly','monthly') or p_due_offset is null or
 p_due_offset not between 0 and 365 then raise exception 'Invalid recurring schedule';end if;
 perform 1 from public.organizations where id=p_org for update;
 select * into v_source from public.financial_documents
 where organization_id=p_org and id=p_source_document;
 if not found or v_source.status not in ('draft','posted') or
 v_source.document_type not in ('invoice','bill') then
 raise exception 'Recurring source must be an invoice or bill';end if;
 insert into public.recurring_document_rules(organization_id,source_document_id,cadence,
  next_run_date,due_offset_days,created_by)
 values(p_org,p_source_document,p_cadence,p_first_date,p_due_offset,auth.uid())
 returning id into v_id;
 perform private.write_audit(p_org,'automation.recurring_created','recurring_rule',v_id,
 jsonb_build_object('cadence',p_cadence,'first_date',p_first_date));
 return v_id;
end $$;

create function public.set_recurring_document_rule_active(p_org uuid,p_rule uuid,p_active boolean)
returns void language plpgsql security definer set search_path=''
as $$
begin
 if not public.has_org_write(p_org) then raise exception 'Not authorized';end if;
 if p_active is null then raise exception 'Active flag required';end if;
 perform 1 from public.organizations where id=p_org for update;
 update public.recurring_document_rules set active=p_active,updated_at=now()
 where id=p_rule and organization_id=p_org;
 if not found then raise exception 'Rule not found';end if;
 perform private.write_audit(p_org,'automation.recurring_state_changed','recurring_rule',p_rule,
 jsonb_build_object('active',p_active));
end $$;

-- Audit-friendly service runner, generates drafts only with copied financial
-- snapshots. No direct calls to user-scoped draft RPCs, no JWT impersonation.
-- Occurrence generation is serialized on the rule row and is idempotent.
create function public.run_due_recurring_documents(p_as_of date,p_limit integer default 25)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_rule public.recurring_document_rules%rowtype;
 v_source public.financial_documents%rowtype;v_doc uuid;v_seq bigint;
 v_run_date date;v_generated integer:=0;v_skipped integer:=0;
 v_owner uuid;v_invalid integer;v_days integer;
begin
 if p_as_of is null or p_limit is null or p_limit not between 1 and 100
 or p_as_of>current_date+interval '1 day' then raise exception 'Invalid scheduler parameters';end if;
 for v_rule in select * from public.recurring_document_rules
  where active and next_run_date<=p_as_of order by next_run_date,id limit p_limit
  for update skip locked loop
  perform 1 from public.organizations where id=v_rule.organization_id for update;
  v_run_date:=v_rule.next_run_date;
  select * into v_source from public.financial_documents
   where organization_id=v_rule.organization_id and id=v_rule.source_document_id;
  if not found or v_source.status not in ('draft','posted') then
   update public.recurring_document_rules set active=false,updated_at=now() where id=v_rule.id;
   v_skipped:=v_skipped+1;continue;
  end if;
  -- Tax codes must still be valid on the occurrence date. An expired code
  -- pauses the schedule rather than generating invalid or misleading tax.
  select count(*) into v_invalid from public.financial_document_lines l
  left join public.tax_codes t on t.id=l.tax_code_id and t.organization_id=l.organization_id
  where l.organization_id=v_rule.organization_id and l.document_id=v_source.id
  and l.tax_code_id is not null and
   (t.id is null or not t.active or v_run_date<t.effective_from or
     (t.effective_until is not null and v_run_date>t.effective_until));
  if v_invalid>0 then
   update public.recurring_document_rules set active=false,updated_at=now() where id=v_rule.id;
   perform private.write_audit(v_rule.organization_id,'automation.recurring_paused','recurring_rule',
    v_rule.id,jsonb_build_object('reason','Expired or inactive tax code'));
   v_skipped:=v_skipped+1;continue;
  end if;
  select user_id into v_owner from public.organization_members
   where organization_id=v_rule.organization_id and role='owner' limit 1;
  if v_owner is null then
   v_skipped:=v_skipped+1;continue;
  end if;
  update public.organizations set document_sequence=document_sequence+1
   where id=v_rule.organization_id returning document_sequence into v_seq;
  insert into public.financial_documents(organization_id,contact_id,document_type,
    document_number,issue_date,due_date,memo,source_document_id,created_by,
    subtotal,tax_total)
  values(v_rule.organization_id,v_source.contact_id,v_source.document_type,
   (case when v_source.document_type='invoice' then 'INV-' else 'BILL-' end)||
   case when length(v_seq::text)>6 then v_seq::text else lpad(v_seq::text,6,'0') end,
   v_run_date,v_run_date+v_rule.due_offset_days,v_source.memo,null,v_owner,
   v_source.subtotal,v_source.tax_total)
  returning id into v_doc;
  insert into public.financial_document_lines(organization_id,document_id,position,
   description,quantity,unit_price,tax_rate_bps,amount,tax_amount,
   account_id,tax_code_id,tax_classification,recoverable_tax)
  select l.organization_id,v_doc,l.position,l.description,l.quantity,l.unit_price,
   l.tax_rate_bps,l.amount,l.tax_amount,l.account_id,l.tax_code_id,
   l.tax_classification,l.recoverable_tax from public.financial_document_lines l
   where l.organization_id=v_rule.organization_id and l.document_id=v_source.id
   order by l.position;
  insert into public.recurring_document_runs(organization_id,rule_id,occurrence_date,document_id)
  values(v_rule.organization_id,v_rule.id,v_run_date,v_doc);
  update public.recurring_document_rules set
    next_run_date=case when cadence='weekly' then v_run_date+7
      else (v_run_date+interval '1 month')::date end,updated_at=now()
    where id=v_rule.id;
  perform private.write_audit(v_rule.organization_id,'automation.recurring_generated',
   'financial_document',v_doc,jsonb_build_object('rule_id',v_rule.id,'run_date',v_run_date));
  v_generated:=v_generated+1;
 end loop;
 return jsonb_build_object('generated',v_generated,'paused_or_skipped',v_skipped);
end $$;
revoke all on function public.run_due_recurring_documents(date,integer) from public,anon,authenticated;
grant execute on function public.run_due_recurring_documents(date,integer) to service_role;

-- Read-only candidate ranking. Never automatically match or post journal entries.
create function public.suggest_bank_transaction_matches(p_org uuid,p_statement uuid,p_limit integer default 100)
returns table(bank_transaction_id uuid,journal_entry_id uuid,journal_date date,
 amount numeric,score integer)
language plpgsql stable security definer set search_path=''
as $$
begin
 if not public.has_org_access(p_org) then raise exception 'Not authorized';end if;
 if p_limit is null or p_limit not between 1 and 500 then raise exception 'Invalid suggestion limit';end if;
 return query
 select t.id,j.id,j.entry_date,t.signed_amount,
  (100-abs(j.entry_date-t.transaction_date)*5)::integer
 from public.bank_statements s
 join public.bank_transactions t on t.statement_id=s.id and t.organization_id=s.organization_id
 join public.journal_entries j on j.organization_id=s.organization_id
 join public.journal_lines l on l.journal_entry_id=j.id and l.organization_id=j.organization_id
 where s.organization_id=p_org and s.id=p_statement and s.status='open'
 and t.matched_journal_entry_id is null and abs(j.entry_date-t.transaction_date)<=7
 and l.account_id=s.bank_account_id
 and l.debit-l.credit=t.signed_amount
 and not exists(select 1 from public.bank_transactions taken
  where taken.organization_id=p_org and taken.matched_journal_entry_id=j.id)
 group by t.id,j.id,j.entry_date,t.transaction_date,t.signed_amount
 order by (100-abs(j.entry_date-t.transaction_date)*5) desc,t.id,j.id
 limit p_limit;
end $$;
revoke all on function public.create_recurring_document_rule(uuid,uuid,text,date,integer),
 public.set_recurring_document_rule_active(uuid,uuid,boolean),
 public.suggest_bank_transaction_matches(uuid,uuid,integer) from public,anon;
grant execute on function public.create_recurring_document_rule(uuid,uuid,text,date,integer),
 public.set_recurring_document_rule_active(uuid,uuid,boolean),
 public.suggest_bank_transaction_matches(uuid,uuid,integer) to authenticated;
