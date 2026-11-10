-- Protect reconciled bank account histories against backdated changes.
-- Fingerprint requests to reject mismatched replays with an existing idempotency key.
alter table public.journal_entries add column if not exists posting_fingerprint text;
-- Replaces private posting routine while keeping public API signature unchanged.
create or replace function private.post_accounting_journal_internal(
 p_source_kind text,p_organization_id uuid,p_entry_date date,p_memo text,
 p_reference text,p_idempotency_key uuid,p_lines jsonb
) returns uuid language plpgsql security definer set search_path=''
as $$
declare v_id uuid; v_line jsonb; v_debit numeric; v_credit numeric;
 v_debits numeric(20,2):=0; v_credits numeric(20,2):=0;
 v_account uuid; v_count integer:=0; v_period uuid;
 v_fingerprint text; v_stored_fingerprint text;
begin
 if p_source_kind not in ('manual','document','payment','reversal') then
  raise exception 'Invalid posting origin'; end if;
 if not public.has_org_write(p_organization_id) then raise exception 'Not authorized to post'; end if;
 if p_entry_date is null or p_memo is null or char_length(trim(p_memo)) not between 3 and 500
 then raise exception 'Invalid journal header'; end if;
 if p_idempotency_key is null then raise exception 'Idempotency key required'; end if;
 if jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines)<2 or
   jsonb_array_length(p_lines)>(case when p_source_kind='document' then 202 else 100 end)
 then raise exception 'Invalid number of journal lines for posting origin'; end if;
 v_fingerprint:=md5(p_source_kind||'|'||p_entry_date::text||'|'||trim(p_memo)||'|'||
  coalesce(nullif(trim(p_reference),''),'')||'|'||p_lines::text);
 perform 1 from public.organizations where id=p_organization_id for update;
 select id,posting_fingerprint into v_id,v_stored_fingerprint from public.journal_entries
 where organization_id=p_organization_id and source_kind=p_source_kind and idempotency_key=p_idempotency_key;
 if found then
  if v_stored_fingerprint is not null and v_stored_fingerprint<>v_fingerprint then
   raise exception 'Idempotency key reused with different posting details'; end if;
  return v_id;
 end if;
 select id into v_period from public.fiscal_periods
 where organization_id=p_organization_id and p_entry_date between start_date and end_date and not is_locked
 for update;
 if v_period is null then raise exception 'Accounting period is closed or missing'; end if;
 for v_line in select value from jsonb_array_elements(p_lines) loop
  if (v_line->>'account_id') is null then raise exception 'Missing account'; end if;
  v_account:=(v_line->>'account_id')::uuid;
  if not exists(select 1 from public.accounts where id=v_account and organization_id=p_organization_id and is_active)
  then raise exception 'Inactive or cross-tenant account'; end if;
  if exists(select 1 from public.bank_statements s where s.organization_id=p_organization_id
    and s.bank_account_id=v_account and s.status='reconciled' and p_entry_date<=s.end_date)
  then raise exception 'Posting would change a reconciled bank account history'; end if;
  v_debit:=(v_line->>'debit')::numeric;
  v_credit:=(v_line->>'credit')::numeric;
  if v_debit is null or v_credit is null or v_debit<0 or v_credit<0
   or (v_debit>0)=(v_credit>0) or round(v_debit,2)<>v_debit
   or round(v_credit,2)<>v_credit then
   raise exception 'Each line requires one positive debit or credit with cent precision';
  end if;
  v_debits:=v_debits+v_debit;v_credits:=v_credits+v_credit;v_count:=v_count+1;
 end loop;
 if v_count<2 or v_debits<=0 or v_debits<>v_credits then raise exception 'Journal must balance'; end if;
 insert into public.journal_entries(
 organization_id,entry_date,memo,reference,idempotency_key,source_kind,created_by,posting_fingerprint)
 values(p_organization_id,p_entry_date,trim(p_memo),nullif(trim(p_reference),''),
 p_idempotency_key,p_source_kind,auth.uid(),v_fingerprint) returning id into v_id;
 for v_line in select value from jsonb_array_elements(p_lines) loop
  insert into public.journal_lines(organization_id,journal_entry_id,account_id,debit,credit)
  values(p_organization_id,v_id,(v_line->>'account_id')::uuid,
   (v_line->>'debit')::numeric,(v_line->>'credit')::numeric);
 end loop;
 return v_id;
end $$;
revoke all on function private.post_accounting_journal_internal(text,uuid,date,text,text,uuid,jsonb)
 from public,anon,authenticated;
