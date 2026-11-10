-- Milestone 3 bank statement imports, deduplication and controlled reconciliation.
-- Transactions are staging records and NEVER post to the ledger automatically.
create table public.bank_statements(
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null references public.organizations(id) on delete restrict,
 bank_account_id uuid not null,
 start_date date not null,
 end_date date not null,
 opening_balance numeric(20,2) not null,
 closing_balance numeric(20,2) not null,
 status text not null default 'open' check(status in ('open','reconciled')),
 reconciled_at timestamptz,
 reconciled_by uuid references auth.users(id),
 created_at timestamptz not null default now(),
 unique(organization_id,id),
 unique(organization_id,bank_account_id,start_date,end_date),
 foreign key(organization_id,bank_account_id) references public.accounts(organization_id,id),
 check(start_date<=end_date),
 check((status='open' and reconciled_at is null and reconciled_by is null)
    or (status='reconciled' and reconciled_at is not null and reconciled_by is not null))
);
create index bank_statement_org_dates_idx on public.bank_statements(organization_id,bank_account_id,start_date,end_date);

create table public.bank_transactions(
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null,
 statement_id uuid not null,
 line_number integer not null check(line_number between 1 and 100000),
 transaction_date date not null,
 description varchar(500) not null,
 reference varchar(200),
 signed_amount numeric(20,2) not null check(signed_amount<>0),
 matched_journal_entry_id uuid,
 created_at timestamptz not null default now(),
 unique(organization_id,statement_id,line_number),
 unique(organization_id,id),
 foreign key(organization_id,statement_id) references public.bank_statements(organization_id,id),
 foreign key(organization_id,matched_journal_entry_id) references public.journal_entries(organization_id,id)
);
create index bank_transaction_org_stmt_idx on public.bank_transactions(organization_id,statement_id);
create unique index bank_transaction_one_match_per_statement_idx
 on public.bank_transactions(organization_id,statement_id,matched_journal_entry_id)
 where matched_journal_entry_id is not null;
alter table public.bank_statements enable row level security;
alter table public.bank_transactions enable row level security;
create policy bank_statements_select on public.bank_statements for select to authenticated
 using(public.has_org_access(organization_id));
create policy bank_transactions_select on public.bank_transactions for select to authenticated
 using(public.has_org_access(organization_id));
revoke all on public.bank_statements,public.bank_transactions from public,anon,authenticated;
grant select on public.bank_statements,public.bank_transactions to authenticated;

create function public.create_bank_statement(
 p_organization_id uuid,p_bank_account_id uuid,p_start date,p_end date,
 p_opening numeric,p_closing numeric
) returns uuid language plpgsql security definer set search_path=''
as $$
declare v_id uuid;
begin
 if not public.has_org_write(p_organization_id) then raise exception 'Not authorized'; end if;
 if p_start is null or p_end is null or p_start>p_end or
   p_opening is null or p_closing is null or scale(p_opening)>2 or scale(p_closing)>2
 then raise exception 'Invalid statement dates or balances'; end if;
 if not exists(select 1 from public.accounts a where a.organization_id=p_organization_id
   and a.id=p_bank_account_id and a.account_type='asset' and a.is_active) then
   raise exception 'Select an active asset bank account'; end if;
 perform 1 from public.organizations where id=p_organization_id for update;
 if exists(select 1 from public.bank_statements where organization_id=p_organization_id
  and bank_account_id=p_bank_account_id and start_date<=p_end and end_date>=p_start)
 then raise exception 'Statement date ranges cannot overlap for one bank account'; end if;
 insert into public.bank_statements(organization_id,bank_account_id,start_date,end_date,opening_balance,closing_balance)
 values(p_organization_id,p_bank_account_id,p_start,p_end,p_opening,p_closing)
 returning id into v_id;
 return v_id;
end $$;

-- Import a file using stable CSV row numbers. Reimporting the same file is idempotent;
-- changing existing rows is rejected rather than silently mutating financial evidence.
create function public.import_bank_statement_rows(
 p_organization_id uuid,p_statement_id uuid,p_rows jsonb
) returns integer language plpgsql security definer set search_path=''
as $$
declare s public.bank_statements%rowtype; r jsonb; v_n integer:=0;
 v_date date; v_line integer; v_amt numeric; v_desc text; v_ref text;
 existing public.bank_transactions%rowtype;
begin
 if not public.has_org_write(p_organization_id) then raise exception 'Not authorized'; end if;
 if jsonb_typeof(p_rows) is distinct from 'array' or jsonb_array_length(p_rows) not between 1 and 500 then
   raise exception 'Import 1 to 500 rows per batch'; end if;
 perform 1 from public.organizations where id=p_organization_id for update;
 select * into s from public.bank_statements where organization_id=p_organization_id
 and id=p_statement_id and status='open' for update;
 if not found then raise exception 'Statement is not open'; end if;
 for r in select value from jsonb_array_elements(p_rows) loop
   v_line:=(r->>'line_number')::integer;
   v_date:=(r->>'date')::date;
   v_amt:=(r->>'amount')::numeric;
   v_desc:=trim(coalesce(r->>'description',''));
   v_ref:=nullif(trim(r->>'reference'),'');
   if v_line is null or v_line not between 1 and 100000 or
      v_date is null or v_date<s.start_date or v_date>s.end_date or
      v_amt is null or v_amt=0 or scale(v_amt)>2 or
      length(v_desc) not between 1 and 500 or length(coalesce(v_ref,''))>200
   then raise exception 'Invalid transaction at line %',v_line; end if;
   select * into existing from public.bank_transactions
    where organization_id=p_organization_id and statement_id=p_statement_id and line_number=v_line;
   if found then
     if existing.transaction_date<>v_date or existing.signed_amount<>v_amt or
       existing.description<>v_desc or existing.reference is distinct from v_ref
     then raise exception 'Existing statement row % has different content',v_line; end if;
   else
     insert into public.bank_transactions(organization_id,statement_id,line_number,
      transaction_date,description,reference,signed_amount)
     values(p_organization_id,p_statement_id,v_line,v_date,v_desc,v_ref,v_amt);
     v_n:=v_n+1;
   end if;
 end loop;
 return v_n;
end $$;

-- Match a bank transaction only to an existing journal containing precisely the
-- same net movement for the selected asset account. No automatic ledger posting.
create function public.match_bank_transaction(
 p_organization_id uuid,p_bank_transaction_id uuid,p_journal_entry_id uuid
) returns void language plpgsql security definer set search_path=''
as $$
declare tx public.bank_transactions%rowtype; s public.bank_statements%rowtype;
 v_bank_delta numeric; v_journal_date date;
begin
 if not public.has_org_write(p_organization_id) then raise exception 'Not authorized'; end if;
 perform 1 from public.organizations where id=p_organization_id for update;
 select * into tx from public.bank_transactions where organization_id=p_organization_id
 and id=p_bank_transaction_id for update;
 if not found then raise exception 'Bank transaction not found'; end if;
 select * into s from public.bank_statements where organization_id=p_organization_id
 and id=tx.statement_id and status='open' for update;
 if not found then raise exception 'Statement is not open'; end if;
 if tx.matched_journal_entry_id is not null then
   if tx.matched_journal_entry_id=p_journal_entry_id then return; end if;
   raise exception 'Transaction already matched'; end if;
 select j.entry_date,coalesce(sum(l.debit-l.credit),0)
 into v_journal_date,v_bank_delta
 from public.journal_entries j join public.journal_lines l
 on l.organization_id=j.organization_id and l.journal_entry_id=j.id
 where j.organization_id=p_organization_id and j.id=p_journal_entry_id
 and l.account_id=s.bank_account_id
 group by j.entry_date;
 if v_journal_date is null or v_journal_date<s.start_date or v_journal_date>s.end_date
   or v_bank_delta<>tx.signed_amount
 then raise exception 'Journal must contain an equal signed bank movement'; end if;
 if exists(
  select 1 from public.bank_transactions t
  join public.bank_statements x on x.organization_id=t.organization_id and x.id=t.statement_id
  where t.organization_id=p_organization_id and t.matched_journal_entry_id=p_journal_entry_id
    and x.bank_account_id=s.bank_account_id
 ) then raise exception 'Journal already matched for this bank account'; end if;
 update public.bank_transactions set matched_journal_entry_id=p_journal_entry_id
 where organization_id=p_organization_id and id=p_bank_transaction_id;
end $$;

create function public.unmatch_bank_transaction(
 p_organization_id uuid,p_transaction_id uuid
) returns void language plpgsql security definer set search_path=''
as $$
declare v_statement uuid;
begin
 if not public.has_org_write(p_organization_id) then raise exception 'Not authorized'; end if;
 perform 1 from public.organizations where id=p_organization_id for update;
 select statement_id into v_statement from public.bank_transactions
 where id=p_transaction_id and organization_id=p_organization_id for update;
 if not found then raise exception 'Transaction not found'; end if;
 if not exists(select 1 from public.bank_statements where id=v_statement
 and organization_id=p_organization_id and status='open')
 then raise exception 'Reconciled statements cannot be changed'; end if;
 update public.bank_transactions set matched_journal_entry_id=null
 where id=p_transaction_id and organization_id=p_organization_id;
end $$;

create function public.reconcile_bank_statement(
 p_organization_id uuid,p_statement_id uuid
) returns void language plpgsql security definer set search_path=''
as $$
declare s public.bank_statements%rowtype; v_sum numeric; v_total integer;
 v_unmatched integer; v_ledger_open numeric; v_ledger_close numeric;
begin
 if not public.has_org_write(p_organization_id) then raise exception 'Not authorized'; end if;
 perform 1 from public.organizations where id=p_organization_id for update;
 select * into s from public.bank_statements where organization_id=p_organization_id
 and id=p_statement_id for update;
 if not found then raise exception 'Statement not found'; end if;
 if s.status='reconciled' then return; end if;
 select coalesce(sum(signed_amount),0),count(*),
 count(*) filter(where matched_journal_entry_id is null)
 into v_sum,v_total,v_unmatched from public.bank_transactions
 where organization_id=p_organization_id and statement_id=p_statement_id;
 if v_total=0 or v_unmatched<>0 then raise exception 'All statement transactions must be matched'; end if;
 if s.opening_balance+v_sum<>s.closing_balance then
  raise exception 'Statement transactions do not reconcile to closing balance'; end if;
 select coalesce(sum(l.debit-l.credit),0) into v_ledger_open
 from public.journal_lines l join public.journal_entries j
 on j.organization_id=l.organization_id and j.id=l.journal_entry_id
 where l.organization_id=p_organization_id and l.account_id=s.bank_account_id
 and j.entry_date<s.start_date;
 select coalesce(sum(l.debit-l.credit),0) into v_ledger_close
 from public.journal_lines l join public.journal_entries j
 on j.organization_id=l.organization_id and j.id=l.journal_entry_id
 where l.organization_id=p_organization_id and l.account_id=s.bank_account_id
 and j.entry_date<=s.end_date;
 if v_ledger_open<>s.opening_balance or v_ledger_close<>s.closing_balance then
  raise exception 'Ledger bank balances do not agree with statement opening and closing balances'; end if;
 update public.bank_statements set status='reconciled',reconciled_at=now(),reconciled_by=auth.uid()
 where id=p_statement_id and organization_id=p_organization_id;
end $$;

do $grants$
declare r record;
begin
 for r in select p.oid::regprocedure signature from pg_proc p
 join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname in
 ('create_bank_statement','import_bank_statement_rows','match_bank_transaction',
 'unmatch_bank_transaction','reconcile_bank_statement')
 loop
  execute format('revoke all on function %s from public,anon',r.signature);
  execute format('grant execute on function %s to authenticated',r.signature);
 end loop;
end $grants$;
