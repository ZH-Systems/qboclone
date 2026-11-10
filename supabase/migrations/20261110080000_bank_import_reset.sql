-- Allow a bank statement import to be restarted before it is reconciled.
-- This only deletes staging bank rows. No posted journal entry is removed.
create function public.reset_open_bank_statement(
 p_organization_id uuid,p_statement_id uuid
) returns integer language plpgsql security definer set search_path=''
as $$
declare v_count integer;
begin
 if not public.has_org_write(p_organization_id) then raise exception 'Not authorized'; end if;
 perform 1 from public.organizations where id=p_organization_id for update;
 if not exists(select 1 from public.bank_statements where organization_id=p_organization_id
   and id=p_statement_id and status='open' for update)
 then raise exception 'Only open statements can be reset'; end if;
 delete from public.bank_transactions where organization_id=p_organization_id and statement_id=p_statement_id;
 get diagnostics v_count=row_count;
 return v_count;
end $$;
revoke all on function public.reset_open_bank_statement(uuid,uuid) from public,anon;
grant execute on function public.reset_open_bank_statement(uuid,uuid) to authenticated;
