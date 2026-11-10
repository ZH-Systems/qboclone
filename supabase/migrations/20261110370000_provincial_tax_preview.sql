-- Canadian provincial indirect tax reference estimates, taxable goods/services
-- at standard rates only. DOES NOT automatically assign tax codes or file returns.
-- Place of supply, registration, exemptions and recoverability remain user inputs.
create table public.canadian_provincial_tax_reference(
 id bigint generated always as identity primary key,
 province_code char(2) not null check(province_code in ('BC','MB','SK','QC')),
 component_code text not null check(component_code in ('PST','RST','QST')),
 rate_percent numeric(8,4) not null check(rate_percent between 0 and 100),
 effective_from date not null,
 effective_until date,
 source_authority text not null,
 unique(province_code,component_code,effective_from),
 check(effective_until is null or effective_until>=effective_from)
);
insert into public.canadian_provincial_tax_reference(
 province_code,component_code,rate_percent,effective_from,source_authority)
values
('BC','PST',7.0000,'2020-01-01','CRA GST/HST calculator, BC provincial schedule'),
('MB','RST',7.0000,'2020-01-01','CRA GST/HST calculator, Manitoba provincial schedule'),
('SK','PST',6.0000,'2020-01-01','CRA GST/HST calculator, Saskatchewan provincial schedule'),
('QC','QST',9.9750,'2020-01-01','Revenu Quebec QST rate schedule');
revoke all on public.canadian_provincial_tax_reference from public,anon;
grant select on public.canadian_provincial_tax_reference to authenticated;
-- A selectable, non-authoritative estimate rather than an automatic tax engine.
create function public.preview_canadian_indirect_taxes(
 p_province text,p_date date,p_base numeric,p_federal_classification text,
 p_apply_provincial boolean
) returns table(component text,rate_percent numeric,amount numeric)
language plpgsql stable security definer set search_path=''
as $$
declare v_federal_rate integer;v_row public.canadian_provincial_tax_reference%rowtype;
begin
 if p_date is null or p_province is null or
 p_province not in ('AB','BC','MB','NB','NL','NT','NS','NU','ON','PE','QC','SK','YT')
 or p_federal_classification not in ('taxable','zero_rated','exempt','out_of_scope')
 or p_apply_provincial is null or p_base is null or p_base<0 or scale(p_base)>2
 then raise exception 'Invalid tax estimate details';end if;
 v_federal_rate:=public.canadian_gst_hst_rate(p_province,p_date,p_federal_classification);
 component:=case when p_province in ('NB','NL','NS','ON','PE') then 'HST' else 'GST' end;
 rate_percent:=v_federal_rate::numeric/100;
 amount:=round(p_base*rate_percent/100,2);
 return next;
 if p_apply_provincial then
  select * into v_row from public.canadian_provincial_tax_reference
  where province_code=p_province and p_date between effective_from
  and coalesce(effective_until,'infinity'::date);
  if found then
   component:=v_row.component_code;
   rate_percent:=v_row.rate_percent;
   amount:=round(p_base*v_row.rate_percent/100,2);
   return next;
  end if;
 end if;
end $$;
revoke all on function public.preview_canadian_indirect_taxes(text,date,numeric,text,boolean)
 from public,anon;
grant execute on function public.preview_canadian_indirect_taxes(text,date,numeric,text,boolean)
 to authenticated;
