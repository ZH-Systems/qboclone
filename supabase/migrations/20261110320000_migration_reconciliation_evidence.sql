-- Milestone 8 release acceptance evidence. These are explicit human
-- attestations, NOT automatically validated CPA or legal certifications.
create table public.migration_source_reports(
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null,
 batch_id uuid not null,
 report_type text not null check(report_type in (
  'TrialBalance','BalanceSheet','ProfitAndLoss','AgedReceivables','AgedPayables')),
 period_start date not null,
 period_end date not null,
 provider_report jsonb not null,
 content_sha256 char(64) not null check(content_sha256 ~ '^[a-f0-9]{64}$'),
 captured_at timestamptz not null default now(),
 unique(organization_id,id),
 unique(organization_id,batch_id,report_type,period_start,period_end),
 foreign key(organization_id,batch_id) references public.migration_batches(organization_id,id),
 check(period_end>=period_start)
);
create table public.migration_reconciliation_signoffs(
 organization_id uuid not null,
 batch_id uuid not null,
 control_name text not null check(control_name in (
  'trial_balance','accounts_receivable','accounts_payable','bank_cash',
  'gst_hst','historic_profit_loss')),
 source_amount numeric(20,2) not null,
 target_amount numeric(20,2) not null,
 difference numeric(20,2) generated always as (target_amount-source_amount) stored,
 source_report_id uuid,
 notes text not null check(length(trim(notes)) between 10 and 1000),
 reviewed_by uuid not null references auth.users(id),
 reviewed_at timestamptz not null default now(),
 primary key(organization_id,batch_id,control_name),
 foreign key(organization_id,batch_id) references public.migration_batches(organization_id,id),
 foreign key(organization_id,source_report_id) references public.migration_source_reports(organization_id,id)
);
alter table public.migration_batches add column financial_cutover_approved_at timestamptz;
alter table public.migration_batches add column financial_cutover_approved_by uuid references auth.users(id);
alter table public.migration_source_reports enable row level security;
alter table public.migration_reconciliation_signoffs enable row level security;
create policy migration_reports_visible on public.migration_source_reports for select to authenticated
 using(public.has_org_access(organization_id));
create policy migration_signoffs_visible on public.migration_reconciliation_signoffs for select to authenticated
 using(public.has_org_access(organization_id));
revoke all on public.migration_source_reports,public.migration_reconciliation_signoffs from public,anon,authenticated;
grant select on public.migration_source_reports,public.migration_reconciliation_signoffs to authenticated;

create function public.store_migration_source_report(
 p_org uuid,p_batch uuid,p_report_type text,p_start date,p_end date,
 p_document jsonb,p_sha256 text
) returns uuid language plpgsql security definer set search_path=''
as $$
declare v_id uuid;
begin
 if not exists(select 1 from public.organization_members
  where organization_id=p_org and user_id=auth.uid() and role in ('owner','administrator','accountant'))
 then raise exception 'Not authorized';end if;
 if p_report_type not in ('TrialBalance','BalanceSheet','ProfitAndLoss','AgedReceivables','AgedPayables')
 or p_start is null or p_end is null or p_start>p_end or
 jsonb_typeof(p_document) is distinct from 'object' or octet_length(p_document::text)>4000000
 or p_sha256 is null or p_sha256 !~ '^[a-f0-9]{64}$'
 then raise exception 'Invalid source report';end if;
 if not exists(select 1 from public.migration_batches
  where organization_id=p_org and id=p_batch and state in ('staged','reviewed','in_progress','completed'))
 then raise exception 'Migration batch not found';end if;
 insert into public.migration_source_reports(organization_id,batch_id,report_type,
  period_start,period_end,provider_report,content_sha256)
 values(p_org,p_batch,p_report_type,p_start,p_end,p_document,p_sha256)
 on conflict(organization_id,batch_id,report_type,period_start,period_end)
 do update set provider_report=excluded.provider_report,content_sha256=excluded.content_sha256,
 captured_at=now()
 returning id into v_id;
 perform private.write_audit(p_org,'migration.source_report_captured','source_report',v_id,
  jsonb_build_object('kind',p_report_type,'as_of',p_end));
 return v_id;
end $$;

create function public.record_migration_reconciliation(
 p_org uuid,p_batch uuid,p_control text,p_source numeric,p_target numeric,
 p_source_report uuid,p_notes text
) returns void language plpgsql security definer set search_path=''
as $reconcile$
declare v_actual numeric(20,2);v_as_of date;v_expected_report text;
begin
 if not exists(select 1 from public.organization_members
  where organization_id=p_org and user_id=auth.uid() and role in ('owner','accountant'))
 then raise exception 'Owner or accountant must reconcile';end if;
 if p_control not in ('trial_balance','accounts_receivable','accounts_payable',
  'bank_cash','gst_hst','historic_profit_loss') or p_source is null or p_target is null or
 scale(p_source)>2 or scale(p_target)>2 or
 length(trim(coalesce(p_notes,''))) not between 10 and 1000 then
 raise exception 'Invalid reconciliation evidence';end if;
 perform 1 from public.organizations where id=p_org for update;
 if not exists(select 1 from public.migration_batches where organization_id=p_org
  and id=p_batch and state in ('in_progress','completed') and financial_cutover_approved_at is null)
 then raise exception 'Migration must have a reviewed cutover in progress';end if;
 select source_as_of into v_as_of from public.migration_batches
 where organization_id=p_org and id=p_batch;
 if v_as_of is null then raise exception 'Source as-of date is required for reconciliation';end if;
 v_expected_report:=case p_control
  when 'trial_balance' then 'TrialBalance'
  when 'accounts_receivable' then 'AgedReceivables'
  when 'accounts_payable' then 'AgedPayables'
  when 'bank_cash' then 'BalanceSheet'
  when 'gst_hst' then 'BalanceSheet'
  when 'historic_profit_loss' then 'ProfitAndLoss' end;
 if p_source_report is null or not exists(select 1 from public.migration_source_reports r
  where r.id=p_source_report and r.organization_id=p_org and r.batch_id=p_batch
   and r.report_type=v_expected_report and r.period_end=v_as_of)
 then raise exception 'An as-of QuickBooks source report for this control is required';end if;
 if p_control='historic_profit_loss' then
  select coalesce(sum(case when account_type='revenue' then amount else -amount end),0)
    into v_actual from public.ledger_profit_loss(p_org,make_date(extract(year from v_as_of)::int,1,1),v_as_of);
 else
  select coalesce(sum(case
   when p_control='trial_balance' then greatest(0,net_debit)
   when p_control='accounts_receivable' and account_code='1100' then net_debit
   when p_control='accounts_payable' and account_code='2000' then -net_debit
   when p_control='bank_cash' and account_code in (
     select code from public.accounts where organization_id=p_org and is_bank_account) then net_debit
   when p_control='gst_hst' and account_code='2100' then -net_debit
   when p_control='gst_hst' and account_code='1300' then -net_debit
   else 0 end),0) into v_actual
  from public.ledger_trial_balance(p_org,v_as_of);
 end if;
 if abs(v_actual-p_target)>0.01 then
  raise exception 'Submitted target ledger amount does not match PostgreSQL-derived balance (actual %)',v_actual;end if;
  if p_source_report is not null and not exists(
  select 1 from public.migration_source_reports where id=p_source_report
   and organization_id=p_org and batch_id=p_batch) then
 raise exception 'Source report belongs to a different batch';end if;
 insert into public.migration_reconciliation_signoffs(organization_id,batch_id,control_name,
 source_amount,target_amount,source_report_id,notes,reviewed_by)
 values(p_org,p_batch,p_control,p_source,p_target,p_source_report,trim(p_notes),auth.uid())
 on conflict(organization_id,batch_id,control_name) do update set
 source_amount=excluded.source_amount,target_amount=excluded.target_amount,
 source_report_id=excluded.source_report_id,notes=excluded.notes,
 reviewed_by=excluded.reviewed_by,reviewed_at=now();
 perform private.write_audit(p_org,'migration.reconciliation_recorded','migration',p_batch,
  jsonb_build_object('control',p_control,'difference',p_target-p_source));
end $reconcile$;

create function public.accept_migration_financial_cutover(p_org uuid,p_batch uuid)
returns void language plpgsql security definer set search_path=''
as $$
declare v_count integer;v_pending integer;
begin
 if not exists(select 1 from public.organization_members
  where organization_id=p_org and user_id=auth.uid() and role in ('owner','accountant'))
 then raise exception 'Owner or accountant signoff required';end if;
 perform 1 from public.organizations where id=p_org for update;
 select count(*) into v_count from public.migration_reconciliation_signoffs
  where organization_id=p_org and batch_id=p_batch and abs(difference)<=0.01
   and source_report_id is not null;
 select count(*) into v_pending from public.migration_records
  where organization_id=p_org and batch_id=p_batch and record_kind in
  ('invoice','bill','payment','bill_payment')
  and not financial_posted;
 if v_count<>6 or v_pending<>0 then
  raise exception 'Financial cutover blocked: six evidenced reconciliations and posted open items required';end if;
 if not exists(select 1 from public.migration_batches where organization_id=p_org
  and id=p_batch and state='completed' and approved_at is not null)
 then raise exception 'Migration draft import is not complete';end if;
 update public.migration_batches set financial_cutover_approved_at=now(),
  financial_cutover_approved_by=auth.uid()
 where id=p_batch and organization_id=p_org and financial_cutover_approved_at is null;
 if not found then raise exception 'Migration cutover already approved';end if;
 perform private.write_audit(p_org,'migration.financial_cutover_accepted','migration',p_batch,
  jsonb_build_object('controls_passed',6));
end $$;
revoke all on function public.store_migration_source_report(uuid,uuid,text,date,date,jsonb,text),
 public.record_migration_reconciliation(uuid,uuid,text,numeric,numeric,uuid,text),
 public.accept_migration_financial_cutover(uuid,uuid) from public,anon;
grant execute on function public.store_migration_source_report(uuid,uuid,text,date,date,jsonb,text),
 public.record_migration_reconciliation(uuid,uuid,text,numeric,numeric,uuid,text),
 public.accept_migration_financial_cutover(uuid,uuid) to authenticated;
