-- Milestone 8: lossless full-source migration staging, mapping, approvals,
-- and deterministic import of accounts, contacts and documents. Financial
-- cutover is NOT automatic; historical source ledger may overlap documents.
create table public.migration_batches(
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null references public.organizations(id) on delete restrict,
 source_system text not null check(source_system in ('quickbooks_online','quickbooks_desktop','generic')),
 source_company_id text,
 state text not null default 'staged' check(state in ('staged','reviewed','in_progress','completed','canceled')),
 source_as_of date,
 imported_at timestamptz,
 created_by uuid not null references auth.users(id),
 approved_by uuid references auth.users(id),
 approved_at timestamptz,
 created_at timestamptz not null default now(),
 unique(organization_id,id)
);
create table public.migration_records(
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null,
 batch_id uuid not null,
 record_kind text not null check(record_kind in (
 'account','customer','vendor','tax_code','invoice','bill','credit_note','vendor_credit',
 'payment','bill_payment','journal','opening_balance','attachment','bank_transaction')),
 source_id text not null check(length(source_id) between 1 and 200),
 payload jsonb not null check(jsonb_typeof(payload)='object'),
 status text not null default 'staged' check(status in ('staged','imported','exception','archived')),
 target_id uuid,
 issue text,
 created_at timestamptz not null default now(),
 unique(organization_id,batch_id,record_kind,source_id),
 unique(organization_id,id),
 foreign key(organization_id,batch_id) references public.migration_batches(organization_id,id)
);
create index migration_records_batch_idx on public.migration_records(organization_id,batch_id,record_kind,status);
create table public.migration_checks(
 organization_id uuid not null,
 batch_id uuid not null,
 check_code text not null,
 passed boolean not null,
 details jsonb not null default '{}'::jsonb,
 created_at timestamptz not null default now(),
 primary key(organization_id,batch_id,check_code),
 foreign key(organization_id,batch_id) references public.migration_batches(organization_id,id)
);
alter table public.migration_batches enable row level security;
alter table public.migration_records enable row level security;
alter table public.migration_checks enable row level security;
create policy migration_batches_visible on public.migration_batches for select to authenticated using(public.has_org_access(organization_id));
create policy migration_records_visible on public.migration_records for select to authenticated using(public.has_org_access(organization_id));
create policy migration_checks_visible on public.migration_checks for select to authenticated using(public.has_org_access(organization_id));
revoke all on public.migration_batches,public.migration_records,public.migration_checks from public,anon,authenticated;
grant select on public.migration_batches,public.migration_records,public.migration_checks to authenticated;

create function public.create_migration_batch(p_org uuid,p_source text,p_company_id text,p_as_of date)
returns uuid language plpgsql security definer set search_path=''
as $$
declare v_id uuid;
begin
 if not exists(select 1 from public.organization_members
 where organization_id=p_org and user_id=auth.uid()
 and role in ('owner','administrator','accountant')) then raise exception 'Not authorized';end if;
 if p_source not in ('quickbooks_online','quickbooks_desktop','generic')
 or length(coalesce(p_company_id,''))>200 then raise exception 'Invalid source system';end if;
 insert into public.migration_batches(organization_id,source_system,source_company_id,
 source_as_of,created_by)
 values(p_org,p_source,nullif(trim(p_company_id),''),p_as_of,auth.uid()) returning id into v_id;
 perform private.write_audit(p_org,'migration.batch_created','migration',v_id,
 jsonb_build_object('source',p_source));
 return v_id;
end $$;

create function public.stage_migration_records(p_org uuid,p_batch uuid,p_kind text,p_records jsonb)
returns integer language plpgsql security definer set search_path=''
as $$
declare v_batch public.migration_batches%rowtype;v_row jsonb;v_id text;v_count integer:=0;
begin
 if not exists(select 1 from public.organization_members where organization_id=p_org and
  user_id=auth.uid() and role in ('owner','administrator','accountant'))
 then raise exception 'Not authorized';end if;
 if p_kind not in ('account','customer','vendor','tax_code','invoice','bill','credit_note',
  'vendor_credit','payment','bill_payment','journal','opening_balance','attachment','bank_transaction')
 or jsonb_typeof(p_records) is distinct from 'array' or jsonb_array_length(p_records)>500
 then raise exception 'Invalid migration entity batch';end if;
 perform 1 from public.organizations where id=p_org for update;
 select * into v_batch from public.migration_batches
 where organization_id=p_org and id=p_batch for update;
 if not found or v_batch.state<>'staged' then raise exception 'Migration batch is not editable';end if;
 for v_row in select value from jsonb_array_elements(p_records) loop
  if jsonb_typeof(v_row) is distinct from 'object' then raise exception 'Migration row must be an object';end if;
  v_id:=v_row->>'source_id';
  if length(coalesce(v_id,'')) not between 1 and 200 or
  octet_length(v_row::text)>200000 then raise exception 'Migration row is invalid or oversized';end if;
  insert into public.migration_records(organization_id,batch_id,record_kind,source_id,payload)
  values(p_org,p_batch,p_kind,v_id,v_row)
  on conflict(organization_id,batch_id,record_kind,source_id) do nothing;
  if found then v_count:=v_count+1;
  elsif not exists(select 1 from public.migration_records where organization_id=p_org
   and batch_id=p_batch and record_kind=p_kind and source_id=v_id and payload=v_row)
  then raise exception 'Conflicting migration replay for %/%',p_kind,v_id;end if;
 end loop;
 return v_count;
end $$;

create function public.review_migration_batch(p_org uuid,p_batch uuid)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_total bigint;v_unmatched bigint;v_unbalanced bigint;v_issues jsonb;
begin
 if not public.has_org_access(p_org) then raise exception 'Not authorized';end if;
 select count(*) into v_total from public.migration_records
  where organization_id=p_org and batch_id=p_batch;
 select count(*) into v_unmatched from public.migration_records r
 where organization_id=p_org and batch_id=p_batch
 and r.record_kind in ('invoice','bill','credit_note','vendor_credit','payment','bill_payment')
 and nullif(r.payload->>'contact_source_id','') is not null
 and not exists(select 1 from public.migration_records c
   where c.organization_id=r.organization_id and c.batch_id=r.batch_id
   and c.record_kind in ('customer','vendor')
   and c.source_id=r.payload->>'contact_source_id');
 select count(*) into v_unbalanced from public.migration_records r
 where organization_id=p_org and batch_id=p_batch and record_kind='journal'
 and ((r.payload->'lines') is null or jsonb_typeof(r.payload->'lines')<>'array'
 or abs(coalesce((select sum((x->>'debit')::numeric-(x->>'credit')::numeric)
 from jsonb_array_elements(case when jsonb_typeof(r.payload->'lines')='array'
 then r.payload->'lines' else '[]'::jsonb end) x),1))>0.005);
 if not exists(select 1 from public.migration_batches
 where organization_id=p_org and id=p_batch) then raise exception 'Batch not found';end if;
 return jsonb_build_object('total_records',v_total,'missing_contact_references',v_unmatched,
 'unbalanced_journals',v_unbalanced,'requires_accountant_signoff',true,
 'financial_cutover_automatic',false);
end $$;

-- Human review gate: preventing automatic posting of historical payments,
-- documents and journals until source GL reconciliation is approved separately.
create function public.approve_migration_batch(p_org uuid,p_batch uuid)
returns void language plpgsql security definer set search_path=''
as $$
declare v_review jsonb;
begin
 if not exists(select 1 from public.organization_members where
  organization_id=p_org and user_id=auth.uid() and role in ('owner','accountant'))
 then raise exception 'Owner or accountant must approve migration';end if;
 perform 1 from public.organizations where id=p_org for update;
 v_review:=public.review_migration_batch(p_org,p_batch);
 if (v_review->>'total_records')::integer=0 or
  (v_review->>'missing_contact_references')::integer>0 or
  (v_review->>'unbalanced_journals')::integer>0
 then raise exception 'Migration review has blockers';end if;
 update public.migration_batches set state='reviewed',approved_by=auth.uid(),approved_at=now()
 where organization_id=p_org and id=p_batch and state='staged';
 if not found then raise exception 'Migration batch cannot be approved';end if;
 perform private.write_audit(p_org,'migration.batch_approved','migration',p_batch,v_review);
end $$;

-- Imports are safe and provenance-preserving. Source documents are created
-- as DRAFTS rather than posted against an unreconciled source general ledger.
-- Nonfinancial source categories remain searchable in archive staging.
create function public.apply_reviewed_migration(p_org uuid,p_batch uuid)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_batch public.migration_batches%rowtype;v_row public.migration_records%rowtype;
 v_target uuid;v_contact uuid;v_lines jsonb;v_processed integer:=0;
 v_line jsonb;v_src text;v_mapped_account uuid;v_mapped_lines jsonb;
begin
 if not exists(select 1 from public.organization_members where organization_id=p_org
 and user_id=auth.uid() and role in ('owner','accountant'))
 then raise exception 'Owner or accountant required';end if;
 perform 1 from public.organizations where id=p_org for update;
 select * into v_batch from public.migration_batches
 where organization_id=p_org and id=p_batch for update;
 if not found or v_batch.state not in ('reviewed','in_progress') then raise exception 'Batch must be approved';end if;
 update public.migration_batches set state='in_progress' where id=p_batch;
 for v_row in select * from public.migration_records where organization_id=p_org and batch_id=p_batch
 and status='staged' and record_kind in ('account','customer','vendor','invoice','bill')
 order by case record_kind when 'account' then 1 when 'customer' then 2 when 'vendor' then 2
  else 3 end,created_at,id limit 100 loop
  v_target:=null;
  if v_row.record_kind='account' then
   select id into v_target from public.accounts where organization_id=p_org
    and code=v_row.payload->>'code';
   if v_target is null then v_target:=public.create_account(p_org,v_row.payload->>'code',
    v_row.payload->>'name',v_row.payload->>'type');end if;
  elsif v_row.record_kind in ('customer','vendor') then
   v_target:=public.create_contact(p_org,case when v_row.record_kind='customer' then 'customer'
    else 'vendor' end,v_row.payload->>'name',v_row.payload->>'email');
  else
   select target_id into v_contact from public.migration_records
    where organization_id=p_org and batch_id=p_batch
    and record_kind=case when v_row.record_kind='invoice' then 'customer' else 'vendor' end
    and source_id=v_row.payload->>'contact_source_id' and status='imported';
   if v_contact is null then raise exception 'Import referenced contact first';end if;
   v_mapped_lines:='[]'::jsonb;
   for v_line in select value from jsonb_array_elements(v_row.payload->'lines') loop
    v_src:=v_line->>'account_source_id';v_mapped_account:=null;
    if v_src is not null then
     select target_id into v_mapped_account from public.migration_records
     where organization_id=p_org and batch_id=p_batch and record_kind='account'
      and source_id=v_src and status='imported';
     if v_mapped_account is null then raise exception 'Unknown source account reference %',v_src;end if;
    end if;
    v_mapped_lines:=v_mapped_lines||jsonb_build_array(
     (v_line-'account_source_id')||case when v_mapped_account is not null
      then jsonb_build_object('account_id',v_mapped_account) else '{}'::jsonb end);
   end loop;
   v_target:=public.create_financial_document(p_org,v_contact,v_row.record_kind,
     (v_row.payload->>'issue_date')::date,
     (v_row.payload->>'due_date')::date,coalesce(v_row.payload->>'memo',''),
     null,v_mapped_lines);
  end if;
  update public.migration_records set status='imported',target_id=v_target
   where id=v_row.id and organization_id=p_org;
  v_processed:=v_processed+1;
 end loop;
 if not exists(select 1 from public.migration_records where batch_id=p_batch
  and organization_id=p_org and record_kind in ('account','customer','vendor','invoice','bill')
  and status='staged')
 then update public.migration_batches set state='completed',imported_at=now()
  where id=p_batch and organization_id=p_org;end if;
 perform private.write_audit(p_org,'migration.safe_import_applied','migration',p_batch,
  jsonb_build_object('records',v_processed,'documents_are_drafts',true));
 return jsonb_build_object('imported_this_batch',v_processed,'automatic_financial_posting',false);
end $$;
revoke all on function public.create_migration_batch(uuid,text,text,date),
 public.stage_migration_records(uuid,uuid,text,jsonb),
 public.review_migration_batch(uuid,uuid),
 public.approve_migration_batch(uuid,uuid),
 public.apply_reviewed_migration(uuid,uuid) from public,anon;
grant execute on function public.create_migration_batch(uuid,text,text,date),
 public.stage_migration_records(uuid,uuid,text,jsonb),
 public.review_migration_batch(uuid,uuid),
 public.approve_migration_batch(uuid,uuid),
 public.apply_reviewed_migration(uuid,uuid) to authenticated;
