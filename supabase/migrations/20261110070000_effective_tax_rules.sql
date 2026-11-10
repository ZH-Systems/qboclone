-- Effective-period validation for tax-code selection.
-- Do not recompute posted document tax snapshots when a tax code is retired.
create function private.validate_document_line_tax_period()
returns trigger language plpgsql security definer set search_path=''
as $$
declare v_issue date; v_tc public.tax_codes%rowtype;
begin
 if new.tax_code_id is null then return new; end if;
 select issue_date into v_issue from public.financial_documents
 where id=new.document_id and organization_id=new.organization_id;
 select * into v_tc from public.tax_codes
 where id=new.tax_code_id and organization_id=new.organization_id;
 if not found or v_issue is null or not v_tc.active
   or v_issue<v_tc.effective_from
   or (v_tc.effective_until is not null and v_issue>v_tc.effective_until)
 then raise exception 'Tax code is not valid on the document issue date'; end if;
 return new;
end $$;
create trigger validate_doc_line_tax_period
 before insert or update of tax_code_id on public.financial_document_lines
 for each row execute function private.validate_document_line_tax_period();

create function public.create_tax_code_with_dates(
 p_organization_id uuid,p_code text,p_label text,p_kind text,p_classification text,
 p_rate_bps integer,p_recoverable_bps integer,p_effective_from date,p_effective_until date
) returns uuid language plpgsql security definer set search_path=''
as $$
declare v_id uuid;
begin
 if not public.has_org_write(p_organization_id) then raise exception 'Not authorized'; end if;
 if p_effective_from is null or
   (p_effective_until is not null and p_effective_until<p_effective_from)
 then raise exception 'Invalid effective dates'; end if;
 if p_code is null or p_code !~ '^[A-Za-z0-9_-]{1,24}$' or
  p_label is null or length(trim(p_label)) not between 1 and 120 then
  raise exception 'Invalid tax code or label'; end if;
 if p_kind not in ('sale','purchase') or
  p_classification not in ('taxable','zero_rated','exempt','out_of_scope') or
  p_rate_bps is null or p_rate_bps not between 0 and 2500 or
  p_recoverable_bps is null or p_recoverable_bps not between 0 and 10000 or
  (p_classification<>'taxable' and p_rate_bps<>0) or
  (p_kind='sale' and p_recoverable_bps<>0)
 then raise exception 'Invalid tax classification, rate or recovery'; end if;
 insert into public.tax_codes(organization_id,code,label,transaction_kind,
  classification,rate_bps,recoverable_bps,effective_from,effective_until)
 values(p_organization_id,p_code,trim(p_label),p_kind,
  p_classification,p_rate_bps,p_recoverable_bps,p_effective_from,p_effective_until)
 returning id into v_id;
 return v_id;
end $$;
revoke all on function public.create_tax_code_with_dates(uuid,text,text,text,text,integer,integer,date,date)
 from public,anon;
grant execute on function public.create_tax_code_with_dates(uuid,text,text,text,text,integer,integer,date,date)
 to authenticated;
revoke all on function private.validate_document_line_tax_period() from public,anon,authenticated;
