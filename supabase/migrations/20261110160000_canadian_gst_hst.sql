-- Milestone 6: Canadian GST/HST base rates, explicit place-of-supply selection,
-- tax classification snapshots and accrual-basis tax reconciliation reporting.
-- Authoritative rate reference: CRA GST/HST published rates as reviewed Nov 2026.
-- Province code is USER-SELECTED; automated place-of-supply determination is NOT implemented.
-- This covers GST and HST only. Provincial PST, QST and special supplies are excluded.
create table public.canadian_gst_hst_rates(
 province_code char(2) not null,
 effective_from date not null,
 effective_until date,
 rate_bps integer not null check(rate_bps between 0 and 2500),
 primary key(province_code,effective_from),
 check(province_code in ('AB','BC','MB','NB','NL','NT','NS','NU','ON','PE','QC','SK','YT')),
 check(effective_until is null or effective_until>=effective_from)
);
insert into public.canadian_gst_hst_rates(province_code,effective_from,effective_until,rate_bps) values
 ('AB','2020-01-01',null,500),('BC','2020-01-01',null,500),
 ('MB','2020-01-01',null,500),('NB','2020-01-01',null,1500),
 ('NL','2020-01-01',null,1500),('NT','2020-01-01',null,500),
 ('NS','2020-01-01','2025-03-31',1500),
 ('NS','2025-04-01',null,1400),('NU','2020-01-01',null,500),
 ('ON','2020-01-01',null,1300),('PE','2020-01-01',null,1500),
 ('QC','2020-01-01',null,500),('SK','2020-01-01',null,500),
 ('YT','2020-01-01',null,500);
alter table public.canadian_gst_hst_rates enable row level security;
create policy canadian_gst_hst_rates_read on public.canadian_gst_hst_rates
 for select to authenticated using(true);
revoke all on public.canadian_gst_hst_rates from public,anon,authenticated;
grant select on public.canadian_gst_hst_rates to authenticated;

alter table public.tax_codes add column province_code char(2);
alter table public.financial_document_lines add column province_code char(2);

create function public.canadian_gst_hst_rate(
 p_province text,p_supply_date date,p_classification text default 'taxable'
) returns integer language plpgsql stable security definer set search_path=''
as $$
declare v_rate integer;
begin
 if p_supply_date is null or p_province is null or
  p_classification not in ('taxable','zero_rated','exempt','out_of_scope')
 then raise exception 'Invalid Canadian GST/HST rate lookup';end if;
 if p_classification<>'taxable' then return 0;end if;
 select rate_bps into v_rate from public.canadian_gst_hst_rates
 where province_code=upper(p_province) and p_supply_date between effective_from
   and coalesce(effective_until,'infinity'::date);
 if v_rate is null then raise exception 'No configured GST/HST rate for province and date';end if;
 return v_rate;
end $$;

-- Explicitly configure a tax code using a user-selected place-of-supply province.
-- Purchase recoverability is an accountant-configured input, never auto-assumed.
create function public.create_canadian_tax_code(
 p_organization_id uuid,p_code text,p_label text,p_kind text,
 p_province text,p_classification text,p_supply_date date,p_recoverable_bps integer default 0
) returns uuid language plpgsql security definer set search_path=''
as $$
declare v_rate integer;v_from date;v_until date;v_id uuid;
begin
 if not public.has_org_write(p_organization_id) then raise exception 'Not authorized';end if;
 v_rate:=public.canadian_gst_hst_rate(p_province,p_supply_date,p_classification);
 if p_kind not in ('sale','purchase') then raise exception 'Invalid tax direction';end if;
 if p_kind='sale' and p_recoverable_bps<>0 then raise exception 'Sale tax is not an ITC';end if;
 if p_recoverable_bps is null or p_recoverable_bps not between 0 and 10000
 then raise exception 'Invalid recoverability';end if;
 select effective_from,effective_until into v_from,v_until
 from public.canadian_gst_hst_rates
 where province_code=upper(p_province) and p_supply_date between effective_from
  and coalesce(effective_until,'infinity'::date);
 if not found then raise exception 'Rate jurisdiction not configured';end if;
 v_id:=public.create_tax_code_with_dates(p_organization_id,p_code,p_label,p_kind,
   p_classification,v_rate,p_recoverable_bps,v_from,v_until);
 update public.tax_codes set province_code=upper(p_province)
  where organization_id=p_organization_id and id=v_id;
 return v_id;
end $$;

-- Snapshot jurisdiction from chosen effective-dated tax code at document line creation.
create function private.snapshot_document_tax_province() returns trigger
language plpgsql security definer set search_path=''
as $$
begin
 if new.tax_code_id is null then
  new.province_code:=null;
 else
  select province_code into new.province_code from public.tax_codes
  where id=new.tax_code_id and organization_id=new.organization_id;
 end if;
 return new;
end $$;
create trigger document_line_tax_province before insert or update of tax_code_id
 on public.financial_document_lines for each row
 execute function private.snapshot_document_tax_province();
update public.financial_document_lines l set province_code=t.province_code
 from public.tax_codes t where t.id=l.tax_code_id and t.organization_id=l.organization_id;

-- Full tax reconciliation by invoice/bill tax snapshot. Accrual-basis reporting
-- deliberately excludes draft documents and combines credits with negative sign.
create function public.gst_hst_tax_summary(p_organization_id uuid,p_start date,p_end date)
returns table(province_code text,classification text,transaction_kind text,
 taxable_base numeric,tax_amount numeric,recoverable_itc numeric,
 document_count bigint,unclassified_lines bigint)
language plpgsql stable security definer set search_path=''
as $$
begin
 if not public.has_org_access(p_organization_id) then raise exception 'Not authorized';end if;
 if p_start is null or p_end is null or p_start>p_end then raise exception 'Invalid reporting range';end if;
 return query
 select coalesce(l.province_code::text,'UNSPECIFIED'),
  coalesce(l.tax_classification,'manual'),
  case when d.document_type in ('invoice','credit_note') then 'sale' else 'purchase' end::text,
  coalesce(sum((case when d.document_type in ('credit_note','vendor_credit') then -1 else 1 end)*l.amount),0)::numeric,
  coalesce(sum((case when d.document_type in ('credit_note','vendor_credit') then -1 else 1 end)*l.tax_amount),0)::numeric,
  coalesce(sum((case when d.document_type in ('vendor_credit') then -1 else 1 end)*
    case when d.document_type in ('bill','vendor_credit') then l.recoverable_tax else 0 end),0)::numeric,
  count(distinct d.id)::bigint,
  count(*) filter(where l.province_code is null or l.tax_code_id is null)::bigint
 from public.financial_documents d join public.financial_document_lines l
  on l.organization_id=d.organization_id and l.document_id=d.id
 where d.organization_id=p_organization_id and d.status='posted'
  and d.issue_date between p_start and p_end
 group by 1,2,3 order by 1,2,3;
end $$;

revoke all on function public.canadian_gst_hst_rate(text,date,text),
 public.create_canadian_tax_code(uuid,text,text,text,text,text,date,integer),
 public.gst_hst_tax_summary(uuid,date,date) from public,anon;
grant execute on function public.canadian_gst_hst_rate(text,date,text),
 public.create_canadian_tax_code(uuid,text,text,text,text,text,date,integer),
 public.gst_hst_tax_summary(uuid,date,date) to authenticated;
revoke all on function private.snapshot_document_tax_province()
 from public,anon,authenticated;
