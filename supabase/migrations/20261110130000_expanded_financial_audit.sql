-- Extend immutable audit coverage to account, fiscal-period and bank matching changes.
create function private.audit_account_insert() returns trigger
language plpgsql security definer set search_path=''
as $$
begin
 perform private.write_audit(new.organization_id,'ledger.account_created','account',new.id,
   jsonb_build_object('code',new.code,'type',new.account_type));
 return new;
end $$;
create trigger ledger_account_audit after insert on public.accounts
 for each row execute function private.audit_account_insert();

create function private.audit_fiscal_period() returns trigger
language plpgsql security definer set search_path=''
as $$
begin
 if tg_op='INSERT' then
   perform private.write_audit(new.organization_id,'ledger.period_created','fiscal_period',new.id,
     jsonb_build_object('start',new.start_date,'end',new.end_date));
 elsif new.is_locked is distinct from old.is_locked then
   perform private.write_audit(new.organization_id,'ledger.period_lock_changed','fiscal_period',new.id,
     jsonb_build_object('locked',new.is_locked));
 end if;
 return new;
end $$;
create trigger ledger_period_created_audit after insert on public.fiscal_periods
 for each row execute function private.audit_fiscal_period();
create trigger ledger_period_lock_audit after update of is_locked on public.fiscal_periods
 for each row execute function private.audit_fiscal_period();

create function private.audit_bank_match() returns trigger
language plpgsql security definer set search_path=''
as $$
begin
 if new.matched_journal_entry_id is distinct from old.matched_journal_entry_id then
  perform private.write_audit(new.organization_id,'bank.match_changed','bank_transaction',new.id,
   jsonb_build_object('journal_entry_id',new.matched_journal_entry_id,
      'previous_journal_entry_id',old.matched_journal_entry_id));
 end if;
 return new;
end $$;
create trigger bank_transaction_match_audit after update of matched_journal_entry_id
 on public.bank_transactions for each row execute function private.audit_bank_match();
revoke all on function private.audit_account_insert(),
 private.audit_fiscal_period(),private.audit_bank_match() from public,anon,authenticated;
