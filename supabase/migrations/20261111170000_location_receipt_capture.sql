-- Principal-controlled, tenant-scoped receipt location reminders.
-- Geofence configuration is available to members, but writable only by the owner.
create table public.receipt_geofences (
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null references public.organizations(id) on delete cascade,
 name text not null check (length(trim(name)) between 1 and 120),
 latitude double precision not null check (latitude between -90 and 90),
 longitude double precision not null check (longitude between -180 and 180),
 radius_m integer not null default 150 check (radius_m between 100 and 1000),
 dwell_seconds integer not null default 300 check (dwell_seconds between 60 and 3600),
 enabled boolean not null default true,
 created_by uuid not null references auth.users(id),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 unique(organization_id,id)
);
create index receipt_geofences_org_idx on public.receipt_geofences (organization_id) where enabled;
alter table public.receipt_geofences enable row level security;
create policy receipt_geofences_read on public.receipt_geofences for select to authenticated
 using (public.has_org_access(organization_id));
revoke all on public.receipt_geofences from public,anon,authenticated;
grant select on public.receipt_geofences to authenticated;

create function public.save_receipt_geofence(
 p_org uuid,p_id uuid,p_name text,p_latitude double precision,p_longitude double precision,
 p_radius_m integer,p_dwell_seconds integer,p_enabled boolean
) returns uuid language plpgsql security definer set search_path=''
as $$
declare v_id uuid; v_role text;
begin
 select role into v_role from public.organization_members
 where organization_id=p_org and user_id=auth.uid();
 if v_role is distinct from 'owner' then raise exception 'Owner role required';end if;
 if p_name is null or length(trim(p_name)) not between 1 and 120
 or p_latitude is null or p_latitude not between -90 and 90
 or p_longitude is null or p_longitude not between -180 and 180
 or p_radius_m is null or p_radius_m not between 100 and 1000
 or p_dwell_seconds is null or p_dwell_seconds not between 60 and 3600
 or p_enabled is null then raise exception 'Invalid geofence';end if;
 if p_id is null then
  if (select count(*) from public.receipt_geofences where organization_id=p_org)>=100
   then raise exception 'Organization geofence limit reached';end if;
  insert into public.receipt_geofences(organization_id,name,latitude,longitude,radius_m,dwell_seconds,enabled,created_by)
  values(p_org,trim(p_name),p_latitude,p_longitude,p_radius_m,p_dwell_seconds,p_enabled)
  returning id into v_id;
 else
  update public.receipt_geofences set name=trim(p_name),latitude=p_latitude,
  longitude=p_longitude,radius_m=p_radius_m,dwell_seconds=p_dwell_seconds,
  enabled=p_enabled,updated_at=now()
  where organization_id=p_org and id=p_id returning id into v_id;
  if v_id is null then raise exception 'Geofence not found';end if;
 end if;
 perform private.write_audit(p_org,'receipt.geofence_saved','receipt_geofence',v_id,
  jsonb_build_object('name',trim(p_name),'enabled',p_enabled));
 return v_id;
end $$;
create function public.delete_receipt_geofence(p_org uuid,p_id uuid)
returns void language plpgsql security definer set search_path=''
as $$
begin
 if not exists(select 1 from public.organization_members
  where organization_id=p_org and user_id=auth.uid() and role='owner')
 then raise exception 'Owner role required';end if;
 delete from public.receipt_geofences where organization_id=p_org and id=p_id;
 if not found then raise exception 'Geofence not found';end if;
 perform private.write_audit(p_org,'receipt.geofence_deleted','receipt_geofence',p_id,'{}'::jsonb);
end $$;

-- OCR intake is explicitly an unposted review candidate, never a journal entry.
create table public.receipt_intake_reviews (
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null,
 receipt_id uuid not null,
 submitted_by uuid not null references auth.users(id),
 classification text not null check(classification in ('expense','incoming_payment')),
 status text not null default 'needs_review' check(status in ('needs_review','reviewed','rejected')),
 geofence_id uuid,
 merchant_candidate text,
 total_candidate numeric(18,2) check (total_candidate is null or total_candidate>=0),
 reviewed_by uuid references auth.users(id),
 reviewed_at timestamptz,
 created_at timestamptz not null default now(),
 unique(organization_id,receipt_id),
 foreign key(organization_id,receipt_id) references public.receipt_documents(organization_id,id),
 foreign key(organization_id,geofence_id) references public.receipt_geofences(organization_id,id)
);
create index receipt_intake_reviews_org_status on public.receipt_intake_reviews(organization_id,status,created_at desc);
alter table public.receipt_intake_reviews enable row level security;
create policy receipt_intake_reviews_read on public.receipt_intake_reviews for select to authenticated
 using (public.has_org_access(organization_id));
revoke all on public.receipt_intake_reviews from public,anon,authenticated;
grant select on public.receipt_intake_reviews to authenticated;

create function public.submit_receipt_intake(
 p_org uuid,p_receipt uuid,p_kind text,p_geofence uuid default null
) returns uuid language plpgsql security definer set search_path=''
as $$
declare v_id uuid;v_data jsonb;v_total text;v_vendor text;
begin
 if not public.has_org_write(p_org) then raise exception 'Not authorized';end if;
 if p_kind not in ('expense','incoming_payment') then raise exception 'Invalid receipt classification';end if;
 if p_geofence is not null and not exists(
  select 1 from public.receipt_geofences where organization_id=p_org and id=p_geofence)
 then raise exception 'Invalid geofence';end if;
 select extraction_data into v_data from public.receipt_documents
 where organization_id=p_org and id=p_receipt and extraction_status='completed';
 if not found then raise exception 'Receipt must complete OCR before review submission';end if;
 v_total:=v_data#>>'{suggestions,total_candidate}';
 v_vendor:=v_data#>>'{suggestions,vendor_candidate}';
 insert into public.receipt_intake_reviews(organization_id,receipt_id,submitted_by,
  classification,geofence_id,merchant_candidate,total_candidate)
 values(p_org,p_receipt,auth.uid(),p_kind,p_geofence,left(v_vendor,150),
  case when v_total ~ '^[0-9]{1,15}(\\.[0-9]{2})$' then v_total::numeric else null end)
 on conflict(organization_id,receipt_id) do nothing returning id into v_id;
 if v_id is null then
  select id into v_id from public.receipt_intake_reviews
   where organization_id=p_org and receipt_id=p_receipt;
 end if;
 perform private.write_audit(p_org,'receipt.intake_submitted','receipt',p_receipt,
  jsonb_build_object('classification',p_kind,'review_id',v_id));
 return v_id;
end $$;
create function public.set_receipt_intake_status(p_org uuid,p_review uuid,p_status text)
returns void language plpgsql security definer set search_path=''
as $$
begin
 if not public.has_org_write(p_org) then raise exception 'Not authorized';end if;
 if p_status not in ('reviewed','rejected') then raise exception 'Invalid review status';end if;
 update public.receipt_intake_reviews set status=p_status,reviewed_by=auth.uid(),reviewed_at=now()
 where organization_id=p_org and id=p_review and status='needs_review';
 if not found then raise exception 'Review not found or already processed';end if;
 perform private.write_audit(p_org,'receipt.intake_reviewed','receipt_intake',p_review,
  jsonb_build_object('status',p_status));
end $$;
revoke all on function public.save_receipt_geofence(uuid,uuid,text,double precision,double precision,integer,integer,boolean),
 public.delete_receipt_geofence(uuid,uuid),
 public.submit_receipt_intake(uuid,uuid,text,uuid),
 public.set_receipt_intake_status(uuid,uuid,text) from public,anon;
grant execute on function public.save_receipt_geofence(uuid,uuid,text,double precision,double precision,integer,integer,boolean),
 public.delete_receipt_geofence(uuid,uuid),
 public.submit_receipt_intake(uuid,uuid,text,uuid),
 public.set_receipt_intake_status(uuid,uuid,text) to authenticated;
