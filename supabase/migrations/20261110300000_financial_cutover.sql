-- Financial cutover is a separate, explicit owner/accountant action.
-- Historical ledger transactions are NEVER imported wholesale on top of posted
-- sales/purchase documents because that would double-count AR/AP and revenue.
alter table public.migration_records add column financial_posted boolean not null default false;
alter table public.migration_records add column posted_at timestamptz;
create index migration_records_financial_idx on public.migration_records(organization_id,batch_id,record_kind,financial_posted);

create or replace function public.review_migration_batch(p_org uuid,p_batch uuid)
returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare v_total bigint;v_unmatched bigint;v_invalid_docs bigint;v_raw_journals bigint;
 v_unmapped_credits bigint;v_source_total numeric;v_doc record;
begin
 if not public.has_org_access(p_org) then raise exception 'Not authorized';end if;
 if not exists(select 1 from public.migration_batches
 where organization_id=p_org and id=p_batch) then raise exception 'Batch not found';end if;
 select count(*) into v_total from public.migration_records
  where organization_id=p_org and batch_id=p_batch;
 select count(*) into v_unmatched from public.migration_records r
 where r.organization_id=p_org and r.batch_id=p_batch
 and r.record_kind in ('invoice','bill','credit_note','vendor_credit')
 and not exists(select 1 from public.migration_records c
   where c.organization_id=r.organization_id and c.batch_id=r.batch_id
   and c.record_kind=case when r.record_kind in ('invoice','credit_note') then 'customer' else 'vendor' end
   and c.source_id=r.payload->>'contact_source_id');
 select count(*) into v_invalid_docs from public.migration_records r
 where r.organization_id=p_org and r.batch_id=p_batch
  and r.record_kind in ('invoice','bill')
  and (jsonb_typeof(r.payload->'lines') is distinct from 'array'
   or jsonb_array_length(case when jsonb_typeof(r.payload->'lines')='array'
     then r.payload->'lines' else '[]'::jsonb end) not between 1 and 100
   or nullif(r.payload->>'total','') is null);
 select count(*) into v_raw_journals from public.migration_records
 where organization_id=p_org and batch_id=p_batch and record_kind='journal'
  and coalesce((payload->>'post_as_standalone')::boolean,false)=false;
 select count(*) into v_unmapped_credits from public.migration_records
 where organization_id=p_org and batch_id=p_batch
 and record_kind in ('credit_note','vendor_credit');
 return jsonb_build_object('total_records',v_total,'missing_contact_references',v_unmatched,
 'incomplete_document_rows',v_invalid_docs,'unmapped_historical_journals',v_raw_journals,
 'unallocated_credits_needing_review',v_unmapped_credits,
 'requires_accountant_signoff',true,'financial_cutover_automatic',false);
end $$;

create or replace function public.approve_migration_batch(p_org uuid,p_batch uuid)
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
  (v_review->>'incomplete_document_rows')::integer>0
 then raise exception 'Migration review has blockers';end if;
 update public.migration_batches set state='reviewed',approved_by=auth.uid(),approved_at=now()
 where organization_id=p_org and id=p_batch and state='staged';
 if not found then raise exception 'Migration batch cannot be approved';end if;
 perform private.write_audit(p_org,'migration.batch_approved','migration',p_batch,v_review);
end $$;

-- Call repeatedly until no documents/payments remain. Each call commits at
-- most 50 posted items atomically and refuses source/target amount differences.
create function public.post_approved_migration_financials(p_org uuid,p_batch uuid)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_batch public.migration_batches%rowtype;v_row public.migration_records%rowtype;
 v_doc public.financial_documents%rowtype;v_expected numeric(20,2);
 v_item jsonb;v_doc_link uuid;v_amt numeric(20,2);v_payment uuid;
 v_processed integer:=0;v_line_index integer;v_target_type text;
begin
 if not exists(select 1 from public.organization_members
 where organization_id=p_org and user_id=auth.uid() and role in ('owner','accountant'))
 then raise exception 'Owner or accountant required for financial cutover';end if;
 perform 1 from public.organizations where id=p_org for update;
 select * into v_batch from public.migration_batches where id=p_batch
 and organization_id=p_org for update;
 if not found or v_batch.state not in ('in_progress','completed') or v_batch.approved_at is null
 then raise exception 'Import reviewed draft documents before posting financials';end if;
 for v_row in select * from public.migration_records
  where organization_id=p_org and batch_id=p_batch and record_kind in ('invoice','bill')
  and status='imported' and not financial_posted
  order by created_at,id limit 50 loop
  select * into v_doc from public.financial_documents
  where organization_id=p_org and id=v_row.target_id for update;
  if not found or v_doc.status<>'draft' then raise exception 'Imported document must remain draft';end if;
  v_expected:=(v_row.payload->>'total')::numeric;
  if v_expected is null or abs(v_doc.total-v_expected)>0.01
  then raise exception 'Source/target document totals differ for %: expected %, got %',
   v_row.source_id,v_expected,v_doc.total;end if;
  perform public.post_financial_document(p_org,v_doc.id);
  update public.migration_records set financial_posted=true,posted_at=now()
   where id=v_row.id and organization_id=p_org;
  v_processed:=v_processed+1;
 end loop;
 -- Stage payment allocations to posted documents. A single source payment
 -- can settle multiple invoices. Source references are explicit, never guessed.
 if v_processed<50 then
  for v_row in select * from public.migration_records
   where organization_id=p_org and batch_id=p_batch
    and record_kind in ('payment','bill_payment') and status='staged'
    order by created_at,id limit (50-v_processed) loop
   if jsonb_typeof(v_row.payload->'allocations') is distinct from 'array' or
     jsonb_array_length(v_row.payload->'allocations')<1 then
      raise exception 'Payment % requires explicit invoice/bill allocations',v_row.source_id;end if;
   v_line_index:=0;
   for v_item in select value from jsonb_array_elements(v_row.payload->'allocations') loop
    v_line_index:=v_line_index+1;
    v_target_type:=case when v_row.record_kind='payment' then 'invoice' else 'bill' end;
    select target_id into v_doc_link from public.migration_records
      where organization_id=p_org and batch_id=p_batch and record_kind=v_target_type
      and source_id=v_item->>'source_document_id' and financial_posted;
    if v_doc_link is null then raise exception 'Payment % points to unposted or missing %',
     v_row.source_id,v_target_type;end if;
    v_amt:=(v_item->>'amount')::numeric;
    if v_amt is null or v_amt<=0 or scale(v_amt)>2 then
     raise exception 'Invalid payment allocation';end if;
    v_payment:=public.record_document_payment(p_org,v_doc_link,v_amt,
      (v_row.payload->>'payment_date')::date,
      left('Imported QuickBooks payment '||v_row.source_id,100),
      md5(v_row.id::text||'-'||v_line_index)::uuid);
   end loop;
   update public.migration_records set status='imported',target_id=v_payment,
    financial_posted=true,posted_at=now() where id=v_row.id and organization_id=p_org;
   v_processed:=v_processed+1;
  end loop;
 end if;
 perform private.write_audit(p_org,'migration.financial_cutover_posted','migration',p_batch,
  jsonb_build_object('records',v_processed));
 return jsonb_build_object('posted_this_batch',v_processed,'requires_trial_balance_signoff',true);
end $$;

-- Historical journal and other categories are kept as original source records,
-- unless explicitly reviewed and mapped in the accountant's journal importer.
-- No silent archive-as-import status and no unsupported auto-GL postings.
revoke all on function public.post_approved_migration_financials(uuid,uuid),
 public.review_migration_batch(uuid,uuid),public.approve_migration_batch(uuid,uuid)
 from public,anon;
grant execute on function public.post_approved_migration_financials(uuid,uuid),
 public.review_migration_batch(uuid,uuid),public.approve_migration_batch(uuid,uuid)
 to authenticated;
