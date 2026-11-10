-- Optional accountant-reviewed migration of linked credits and standalone
-- journals. Never infer which QBO credit applies to which source document.
create table public.migration_credit_assignments(
 organization_id uuid not null,
 batch_id uuid not null,
 credit_source_id text not null,
 invoice_source_id text not null,
 reviewed_by uuid not null references auth.users(id),
 reviewed_at timestamptz not null default now(),
 primary key(organization_id,batch_id,credit_source_id),
 foreign key(organization_id,batch_id) references public.migration_batches(organization_id,id)
);
alter table public.migration_credit_assignments enable row level security;
create policy migration_credit_links_visible on public.migration_credit_assignments for select to authenticated
 using(public.has_org_access(organization_id));
revoke all on public.migration_credit_assignments from public,anon,authenticated;
grant select on public.migration_credit_assignments to authenticated;

create function public.assign_migration_credit_source(
 p_org uuid,p_batch uuid,p_credit_source text,p_invoice_source text
) returns void language plpgsql security definer set search_path=''
as $$
declare v_credit_kind text;
begin
 if not exists(select 1 from public.organization_members where organization_id=p_org
  and user_id=auth.uid() and role in ('owner','accountant')) then
 raise exception 'Accountant review required';end if;
 perform 1 from public.organizations where id=p_org for update;
 select record_kind into v_credit_kind from public.migration_records
 where organization_id=p_org and batch_id=p_batch and source_id=p_credit_source
 and record_kind in ('credit_note','vendor_credit') and status='staged';
 if v_credit_kind is null then raise exception 'Credit source record is not available';end if;
 if not exists(select 1 from public.migration_records where organization_id=p_org
  and batch_id=p_batch and source_id=p_invoice_source
  and record_kind=case when v_credit_kind='credit_note' then 'invoice' else 'bill' end
  and financial_posted)
 then raise exception 'Credit must reference an already-posted source invoice or bill';end if;
 insert into public.migration_credit_assignments(organization_id,batch_id,
  credit_source_id,invoice_source_id,reviewed_by)
 values(p_org,p_batch,p_credit_source,p_invoice_source,auth.uid())
 on conflict(organization_id,batch_id,credit_source_id) do update set
 invoice_source_id=excluded.invoice_source_id,reviewed_by=excluded.reviewed_by,reviewed_at=now();
 perform private.write_audit(p_org,'migration.credit_link_reviewed','migration',p_batch,
  jsonb_build_object('credit_source_id',p_credit_source,'invoice_source_id',p_invoice_source));
end $$;

create function public.approve_migration_standalone_journal(
 p_org uuid,p_batch uuid,p_journal_source_id text
) returns void language plpgsql security definer set search_path=''
as $$
declare v_row public.migration_records%rowtype;v_amount numeric;v_count integer;
begin
 if not exists(select 1 from public.organization_members where organization_id=p_org
  and user_id=auth.uid() and role in ('owner','accountant')) then
 raise exception 'Accountant review required';end if;
 perform 1 from public.organizations where id=p_org for update;
 select * into v_row from public.migration_records where organization_id=p_org
  and batch_id=p_batch and source_id=p_journal_source_id and record_kind='journal'
  and status='staged' for update;
 if not found then raise exception 'Standalone journal source not found';end if;
 if jsonb_typeof(v_row.payload->'lines') is distinct from 'array'
 or jsonb_array_length(v_row.payload->'lines') not between 2 and 100
 then raise exception 'Journal requires 2 to 100 mapped source lines';end if;
 select coalesce(sum((l->>'debit')::numeric-(l->>'credit')::numeric),0),count(*)
 into v_amount,v_count from jsonb_array_elements(v_row.payload->'lines') l;
 if abs(v_amount)>0.005 or v_count<2 then raise exception 'Source journal does not balance';end if;
 update public.migration_records set payload=jsonb_set(payload,
  '{post_as_standalone}','true'::jsonb,true)
 where id=v_row.id and organization_id=p_org;
 perform private.write_audit(p_org,'migration.standalone_journal_approved','migration',p_batch,
  jsonb_build_object('journal_source_id',p_journal_source_id));
end $$;

create function public.apply_reviewed_migration_credits_and_journals(p_org uuid,p_batch uuid)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_row public.migration_records%rowtype;v_doc uuid;v_link uuid;
 v_contact uuid;v_item jsonb;v_src_account uuid;v_lines jsonb;
 v_expected numeric;v_actual numeric;v_journal uuid;v_processed integer:=0;
begin
 if not exists(select 1 from public.organization_members where organization_id=p_org
 and user_id=auth.uid() and role in ('owner','accountant')) then
 raise exception 'Owner or accountant required';end if;
 perform 1 from public.organizations where id=p_org for update;
 if not exists(select 1 from public.migration_batches where organization_id=p_org
  and id=p_batch and approved_at is not null and state in ('in_progress','completed'))
 then raise exception 'Reviewed migration required';end if;
 for v_row in select * from public.migration_records r where r.organization_id=p_org
  and r.batch_id=p_batch and r.record_kind in ('credit_note','vendor_credit')
  and r.status='staged' and exists(select 1 from public.migration_credit_assignments a
   where a.organization_id=r.organization_id and a.batch_id=r.batch_id
    and a.credit_source_id=r.source_id)
  order by r.created_at,r.id limit 30 loop
  select target_id into v_link from public.migration_records src
  join public.migration_credit_assignments a on a.organization_id=src.organization_id
   and a.batch_id=src.batch_id and a.invoice_source_id=src.source_id
  where src.organization_id=p_org and src.batch_id=p_batch
    and a.credit_source_id=v_row.source_id and src.financial_posted;
  if v_link is null then raise exception 'Credit target invoice mapping missing';end if;
  select contact_id into v_contact from public.financial_documents
   where organization_id=p_org and id=v_link and status='posted';
  v_lines:='[]'::jsonb;
  for v_item in select value from jsonb_array_elements(v_row.payload->'lines') loop
   v_src_account:=null;
   if nullif(v_item->>'account_source_id','') is not null then
    select target_id into v_src_account from public.migration_records
     where organization_id=p_org and batch_id=p_batch and record_kind='account'
     and source_id=v_item->>'account_source_id' and status='imported';
    if v_src_account is null then raise exception 'Credit source account mapping missing';end if;
   end if;
   v_lines:=v_lines||jsonb_build_array((v_item-'account_source_id')||
     case when v_src_account is null then '{}'::jsonb
      else jsonb_build_object('account_id',v_src_account) end);
  end loop;
  v_doc:=public.create_financial_document(p_org,v_contact,v_row.record_kind,
   (v_row.payload->>'issue_date')::date,(v_row.payload->>'due_date')::date,
   left(coalesce(v_row.payload->>'memo','Imported source credit'),500),v_link,v_lines);
  v_expected:=(v_row.payload->>'total')::numeric;
  select total into v_actual from public.financial_documents where id=v_doc;
  if v_expected is null or abs(v_expected-v_actual)>0.01 then
   raise exception 'Source credit amount/tax mismatch';end if;
  perform public.post_financial_document(p_org,v_doc);
  update public.migration_records set status='imported',financial_posted=true,
   target_id=v_doc,posted_at=now() where id=v_row.id;
  v_processed:=v_processed+1;
 end loop;
 if v_processed<30 then
  for v_row in select * from public.migration_records
   where organization_id=p_org and batch_id=p_batch and record_kind='journal'
    and status='staged' and coalesce((payload->>'post_as_standalone')::boolean,false)
   order by created_at,id limit (30-v_processed) loop
   v_lines:='[]'::jsonb;
   for v_item in select value from jsonb_array_elements(v_row.payload->'lines') loop
    select target_id into v_src_account from public.migration_records
     where organization_id=p_org and batch_id=p_batch and record_kind='account'
      and source_id=v_item->>'account_source_id' and status='imported';
    if v_src_account is null then raise exception 'Unmapped historical journal account';end if;
    v_lines:=v_lines||jsonb_build_array(jsonb_build_object('account_id',v_src_account,
     'debit',v_item->>'debit','credit',v_item->>'credit'));
   end loop;
   v_journal:=public.post_journal(p_org,(v_row.payload->>'date')::date,
    'Approved standalone QBO journal '||v_row.source_id,'QBO-JOURNAL',v_row.id,v_lines);
   update public.migration_records set target_id=v_journal,status='imported',
    financial_posted=true,posted_at=now() where id=v_row.id;
   v_processed:=v_processed+1;
  end loop;
 end if;
 perform private.write_audit(p_org,'migration.credits_journals_posted','migration',p_batch,
  jsonb_build_object('processed',v_processed));
 return jsonb_build_object('posted',v_processed);
end $$;

revoke all on function public.assign_migration_credit_source(uuid,uuid,text,text),
 public.approve_migration_standalone_journal(uuid,uuid,text),
 public.apply_reviewed_migration_credits_and_journals(uuid,uuid) from public,anon;
grant execute on function public.assign_migration_credit_source(uuid,uuid,text,text),
 public.approve_migration_standalone_journal(uuid,uuid,text),
 public.apply_reviewed_migration_credits_and_journals(uuid,uuid) to authenticated;
