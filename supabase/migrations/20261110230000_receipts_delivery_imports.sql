-- Milestone 7: receipt intake, import review, outbound delivery and automation history.
-- Source files are stored in an existing private Supabase Storage bucket, by API only.
create table public.receipt_documents(
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null references public.organizations(id) on delete restrict,
 uploaded_by uuid not null references auth.users(id),
 storage_path text not null unique,
 original_filename varchar(255) not null,
 mime_type text not null check(mime_type in ('application/pdf','image/png','image/jpeg')),
 content_sha256 char(64) not null check(content_sha256 ~ '^[a-f0-9]{64}$'),
 content_size integer not null check(content_size between 1 and 8388608),
 extraction_status text not null default 'not_requested'
 check(extraction_status in ('not_requested','pending','completed','failed')),
 extraction_data jsonb not null default '{}'::jsonb check(jsonb_typeof(extraction_data)='object'),
 created_at timestamptz not null default now(),
 unique(organization_id,id)
);
create index receipt_docs_org_created on public.receipt_documents(organization_id,created_at desc);
create table public.receipt_document_links(
 organization_id uuid not null,
 receipt_id uuid not null,
 financial_document_id uuid not null,
 linked_by uuid not null references auth.users(id),
 linked_at timestamptz not null default now(),
 primary key(organization_id,receipt_id,financial_document_id),
 foreign key(organization_id,receipt_id) references public.receipt_documents(organization_id,id),
 foreign key(organization_id,financial_document_id)
  references public.financial_documents(organization_id,id)
);
create table public.document_deliveries(
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null,
 document_id uuid not null,
 recipient_email text not null,
 delivery_kind text not null check(delivery_kind in ('invoice','payment_reminder')),
 message_id text,
 status text not null check(status in ('sent','failed','not_configured')),
 sent_at timestamptz not null default now(),
 sent_by uuid not null references auth.users(id),
 unique(organization_id,id),
 foreign key(organization_id,document_id)
  references public.financial_documents(organization_id,id)
);
create index document_deliveries_org_doc on public.document_deliveries(organization_id,document_id,sent_at desc);
create table public.import_review_batches(
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null references public.organizations(id) on delete restrict,
 source_system text not null check(source_system in ('quickbooks_csv','generic_csv')),
 entity_kind text not null check(entity_kind in ('customers','vendors')),
 source_filename text not null,
 rows_previewed integer not null check(rows_previewed between 0 and 5000),
 rows_imported integer not null default 0 check(rows_imported>=0),
 created_by uuid not null references auth.users(id),
 created_at timestamptz not null default now(),
 unique(organization_id,id)
);
alter table public.receipt_documents enable row level security;
alter table public.receipt_document_links enable row level security;
alter table public.document_deliveries enable row level security;
alter table public.import_review_batches enable row level security;
create policy receipt_docs_org_read on public.receipt_documents
 for select to authenticated using(public.has_org_access(organization_id));
create policy receipt_links_org_read on public.receipt_document_links
 for select to authenticated using(public.has_org_access(organization_id));
create policy deliveries_org_read on public.document_deliveries
 for select to authenticated using(public.has_org_access(organization_id));
create policy import_batches_org_read on public.import_review_batches
 for select to authenticated using(public.has_org_access(organization_id));
revoke all on public.receipt_documents,public.receipt_document_links,public.document_deliveries,
 public.import_review_batches from public,anon,authenticated;
grant select on public.receipt_documents,public.receipt_document_links,
 public.document_deliveries,public.import_review_batches to authenticated;

create function public.register_receipt_document(p_org uuid,p_receipt_id uuid,p_path text,
 p_filename text,p_mime text,p_sha256 text,p_size integer)
returns uuid language plpgsql security definer set search_path=''
as $$
begin
 if not public.has_org_write(p_org) then raise exception 'Not authorized';end if;
 if p_receipt_id is null or p_path is null or p_path<>'organizations/'||p_org::text||'/'||p_receipt_id::text
  or length(coalesce(p_filename,'')) not between 1 and 255 or
  p_mime not in ('application/pdf','image/png','image/jpeg') or
  p_sha256 is null or p_sha256 !~ '^[a-f0-9]{64}$' or
  p_size is null or p_size not between 1 and 8388608
 then raise exception 'Invalid receipt metadata';end if;
 insert into public.receipt_documents(id,organization_id,storage_path,original_filename,
   mime_type,content_sha256,content_size,uploaded_by)
 values(p_receipt_id,p_org,p_path,p_filename,p_mime,p_sha256,p_size,auth.uid());
 perform private.write_audit(p_org,'receipt.uploaded','receipt',p_receipt_id,
  jsonb_build_object('mime',p_mime,'size',p_size));
 return p_receipt_id;
end $$;

create function public.link_receipt_document(p_org uuid,p_receipt uuid,p_document uuid)
returns void language plpgsql security definer set search_path=''
as $$
begin
 if not public.has_org_write(p_org) then raise exception 'Not authorized';end if;
 if not exists(select 1 from public.receipt_documents
  where organization_id=p_org and id=p_receipt)
 or not exists(select 1 from public.financial_documents
  where organization_id=p_org and id=p_document)
 then raise exception 'Receipt and financial document must belong to same organization';end if;
 insert into public.receipt_document_links(organization_id,receipt_id,financial_document_id,linked_by)
 values(p_org,p_receipt,p_document,auth.uid())
 on conflict do nothing;
 perform private.write_audit(p_org,'receipt.linked','receipt',p_receipt,
  jsonb_build_object('financial_document_id',p_document));
end $$;

create function public.record_document_delivery(p_org uuid,p_document uuid,p_email text,
 p_kind text,p_status text,p_message_id text default null)
returns uuid language plpgsql security definer set search_path=''
as $$
declare v_id uuid;
begin
 if not public.has_org_write(p_org) then raise exception 'Not authorized';end if;
 if p_email is null or length(trim(p_email)) not between 3 and 255
 or p_kind not in ('invoice','payment_reminder')
 or p_status not in ('sent','failed','not_configured') then raise exception 'Invalid delivery';end if;
 if not exists(select 1 from public.financial_documents where organization_id=p_org
  and id=p_document and document_type='invoice' and status='posted')
 then raise exception 'Only posted customer invoices can be delivered';end if;
 insert into public.document_deliveries(organization_id,document_id,recipient_email,
  delivery_kind,status,message_id,sent_by)
 values(p_org,p_document,lower(trim(p_email)),p_kind,p_status,p_message_id,auth.uid())
 returning id into v_id;
 perform private.write_audit(p_org,'document.delivery_attempt','delivery',v_id,
   jsonb_build_object('document_id',p_document,'status',p_status,'kind',p_kind));
 return v_id;
end $$;

create function public.import_contact_review_rows(p_org uuid,p_source text,p_kind text,
 p_filename text,p_rows jsonb)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_batch uuid;v_row jsonb;v_name text;v_email text;v_count int:=0;v_seen int:=0;
begin
 if not public.has_org_write(p_org) then raise exception 'Not authorized';end if;
 if p_source not in ('quickbooks_csv','generic_csv') or
   p_kind not in ('customers','vendors') or
   length(coalesce(p_filename,'')) not between 1 and 255 or
   jsonb_typeof(p_rows) is distinct from 'array' or
   jsonb_array_length(p_rows)>5000 then raise exception 'Invalid contact import';end if;
 perform 1 from public.organizations where id=p_org for update;
 insert into public.import_review_batches(organization_id,source_system,entity_kind,
  source_filename,rows_previewed,created_by)
 values(p_org,p_source,p_kind,p_filename,jsonb_array_length(p_rows),auth.uid())
 returning id into v_batch;
 for v_row in select value from jsonb_array_elements(p_rows) loop
  v_seen:=v_seen+1;v_name:=trim(coalesce(v_row->>'name',''));
  v_email:=nullif(trim(coalesce(v_row->>'email','')),'');
  if length(v_name) not between 1 and 150 or
   (v_email is not null and (length(v_email)>255 or v_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'))
  then raise exception 'Invalid contact in row %',v_seen;end if;
  -- Duplicate detection is intentionally conservative; do not merge contacts
  -- solely by name. Exact name + email duplicates are skipped.
  if exists(select 1 from public.contacts c where c.organization_id=p_org
     and c.contact_kind=(case when p_kind='customers' then 'customer' else 'vendor' end)
     and lower(c.display_name)=lower(v_name)
     and lower(coalesce(c.email,''))=lower(coalesce(v_email,''))) then continue;end if;
  insert into public.contacts(organization_id,contact_kind,display_name,email)
  values(p_org,case when p_kind='customers' then 'customer' else 'vendor' end,v_name,v_email);
  v_count:=v_count+1;
 end loop;
 update public.import_review_batches set rows_imported=v_count where id=v_batch;
 perform private.write_audit(p_org,'integration.contacts_imported','import_batch',v_batch,
   jsonb_build_object('source',p_source,'kind',p_kind,'processed',v_seen,'imported',v_count));
 return jsonb_build_object('batch_id',v_batch,'processed',v_seen,'imported',v_count);
end $$;

revoke all on function public.register_receipt_document(uuid,uuid,text,text,text,text,integer),
 public.link_receipt_document(uuid,uuid,uuid),
 public.record_document_delivery(uuid,uuid,text,text,text,text),
 public.import_contact_review_rows(uuid,text,text,text,jsonb) from public,anon;
grant execute on function public.register_receipt_document(uuid,uuid,text,text,text,text,integer),
 public.link_receipt_document(uuid,uuid,uuid),
 public.record_document_delivery(uuid,uuid,text,text,text,text),
 public.import_contact_review_rows(uuid,text,text,text,jsonb) to authenticated;
