-- Map explicitly authorized CAD bank feeds to the reconciliation staging model.
-- Foreign-currency bank transactions require a separate reviewed FX workflow.
create table public.bank_feed_import_links(
 organization_id uuid not null,
 feed_transaction_id uuid not null,
 bank_transaction_id uuid not null,
 imported_at timestamptz not null default now(),
 imported_by uuid not null references auth.users(id),
 primary key(organization_id,feed_transaction_id),
 unique(organization_id,bank_transaction_id),
 foreign key(organization_id,feed_transaction_id) references public.bank_feed_transactions(organization_id,id),
 foreign key(organization_id,bank_transaction_id) references public.bank_transactions(organization_id,id)
);
alter table public.bank_feed_import_links enable row level security;
create policy bank_feed_links_read on public.bank_feed_import_links for select to authenticated
 using(public.has_org_access(organization_id));
revoke all on public.bank_feed_import_links from public,anon,authenticated;
grant select on public.bank_feed_import_links to authenticated;

create or replace function public.map_bank_feed_account(p_org uuid,p_feed_account uuid,p_ledger_account uuid)
returns void language plpgsql security definer set search_path=''
as $$
declare v_feed public.bank_feed_accounts%rowtype;
begin
 if not exists(select 1 from public.organization_members
  where organization_id=p_org and user_id=auth.uid() and role in ('owner','administrator','accountant'))
 then raise exception 'Bank mapping requires accountant or administrator';end if;
 select * into v_feed from public.bank_feed_accounts where organization_id=p_org and id=p_feed_account;
 if not found then raise exception 'Bank feed account not found';end if;
 if p_ledger_account is not null and (v_feed.currency_code<>'CAD'
  or not exists(select 1 from public.accounts a where a.organization_id=p_org
   and a.id=p_ledger_account and a.is_bank_account and a.is_active))
 then raise exception 'Only CAD feeds can map to an active CAD ledger bank account';end if;
 perform 1 from public.organizations where id=p_org for update;
 update public.bank_feed_accounts set ledger_bank_account_id=p_ledger_account
 where organization_id=p_org and id=p_feed_account;
 perform private.write_audit(p_org,'bank.feed_account_mapped','bank_feed_account',p_feed_account,
  jsonb_build_object('ledger_account_id',p_ledger_account));
end $$;

create function public.promote_bank_feed_transactions(
 p_org uuid,p_statement uuid,p_feed_transaction_ids uuid[]
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_statement public.bank_statements%rowtype;v_feed public.bank_feed_transactions%rowtype;
 v_rows jsonb:='[]'::jsonb;v_current integer;v_line integer;v_id uuid;
 v_count integer:=0;v_imported integer;v_bt uuid;
begin
 if not public.has_org_write(p_org) then raise exception 'Not authorized';end if;
 if p_feed_transaction_ids is null or cardinality(p_feed_transaction_ids) not between 1 and 500
 then raise exception 'Select 1 to 500 feed transactions';end if;
 if cardinality(array(select distinct unnest(p_feed_transaction_ids)))<>cardinality(p_feed_transaction_ids)
 then raise exception 'Duplicate feed transaction selection';end if;
 perform 1 from public.organizations where id=p_org for update;
 select * into v_statement from public.bank_statements
  where organization_id=p_org and id=p_statement and status='open' for update;
 if not found then raise exception 'Select an open bank statement';end if;
 select coalesce(max(line_number),0) into v_current from public.bank_transactions
 where organization_id=p_org and statement_id=p_statement;
 for v_id in select unnest(p_feed_transaction_ids) loop
  select * into v_feed from public.bank_feed_transactions
   where organization_id=p_org and id=v_id for update;
  if not found or v_feed.pending or v_feed.removed then
   raise exception 'Only active posted bank transactions can be staged';end if;
  if v_feed.booking_date not between v_statement.start_date and v_statement.end_date
  then raise exception 'Bank feed date outside selected statement';end if;
  if not exists(select 1 from public.bank_feed_accounts a
    where a.organization_id=p_org and a.id=v_feed.feed_account_id
     and a.currency_code='CAD' and a.ledger_bank_account_id=v_statement.bank_account_id)
  then raise exception 'Feed account must be mapped to this CAD statement ledger account';end if;
  if exists(select 1 from public.bank_feed_import_links
    where organization_id=p_org and feed_transaction_id=v_id)
  then raise exception 'Feed transaction was already imported';end if;
  v_current:=v_current+1;
  if v_current>100000 then raise exception 'Statement line number capacity exceeded';end if;
  v_rows:=v_rows||jsonb_build_array(jsonb_build_object(
   'line_number',v_current,'date',v_feed.booking_date,'description',left(v_feed.description,500),
   'amount',v_feed.amount,'reference',left('plaid:'||v_feed.provider_transaction_id,200)));
  v_count:=v_count+1;
 end loop;
 v_imported:=public.import_bank_statement_rows(p_org,p_statement,v_rows);
 if v_imported<>v_count then raise exception 'Unexpected deduplication of new bank feed staging rows';end if;
 for v_line,v_id in select (v_current-v_count+item.ordinality)::integer,item.txn_id
  from unnest(p_feed_transaction_ids) with ordinality as item(txn_id,ordinality)
 loop
  select id into strict v_bt from public.bank_transactions
   where organization_id=p_org and statement_id=p_statement and line_number=v_line;
  insert into public.bank_feed_import_links(organization_id,feed_transaction_id,
   bank_transaction_id,imported_by)
  values(p_org,v_id,v_bt,auth.uid());
 end loop;
 perform private.write_audit(p_org,'bank.feed_transactions_staged','bank_statement',p_statement,
  jsonb_build_object('imported',v_count));
 return jsonb_build_object('imported',v_count);
end $$;
revoke all on function public.map_bank_feed_account(uuid,uuid,uuid),
 public.promote_bank_feed_transactions(uuid,uuid,uuid[]) from public,anon;
grant execute on function public.map_bank_feed_account(uuid,uuid,uuid),
 public.promote_bank_feed_transactions(uuid,uuid,uuid[]) to authenticated;
