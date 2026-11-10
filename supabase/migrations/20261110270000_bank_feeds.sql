-- Milestone 8: Plaid-origin bank feeds are staged; NEVER auto-post journals.
-- Account authorization is explicit and access tokens are encrypted in the API.
create table public.bank_feed_connections (
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null references public.organizations(id) on delete restrict,
 provider text not null check(provider='plaid'),
 provider_item_id text not null,
 encrypted_token text not null,
 sync_cursor text,
 status text not null default 'active'
  check(status in ('active','requires_reauth','disconnected')),
 last_synced_at timestamptz,
 last_error_code text,
 created_by uuid not null references auth.users(id),
 created_at timestamptz not null default now(),
 unique(organization_id,id),
 unique(provider,provider_item_id)
);
create index bank_feeds_due_idx on public.bank_feed_connections(status,last_synced_at);
create table public.bank_feed_accounts(
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null,
 connection_id uuid not null,
 provider_account_id text not null,
 display_name text not null,
 mask_last4 text,
 currency_code text not null default 'CAD',
 ledger_bank_account_id uuid,
 created_at timestamptz not null default now(),
 unique(organization_id,id),unique(connection_id,provider_account_id),
 foreign key(organization_id,connection_id) references public.bank_feed_connections(organization_id,id),
 foreign key(organization_id,ledger_bank_account_id) references public.accounts(organization_id,id)
);
create table public.bank_feed_transactions(
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null,
 connection_id uuid not null,
 feed_account_id uuid not null,
 provider_transaction_id text not null,
 booking_date date not null,
 description text not null,
 amount numeric(20,2) not null,
 pending boolean not null default false,
 removed boolean not null default false,
 matched_journal_entry_id uuid,
 provider_updated_at timestamptz not null default now(),
 unique(organization_id,id),
 unique(connection_id,provider_transaction_id),
 foreign key(organization_id,connection_id) references public.bank_feed_connections(organization_id,id),
 foreign key(organization_id,feed_account_id) references public.bank_feed_accounts(organization_id,id),
 foreign key(organization_id,matched_journal_entry_id) references public.journal_entries(organization_id,id)
);
create index bank_feed_transactions_review on public.bank_feed_transactions(organization_id,feed_account_id,booking_date desc)
 where not removed and not pending;
create table public.bank_feed_link_sessions(
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null references public.organizations(id) on delete restrict,
 user_id uuid not null references auth.users(id),
 expires_at timestamptz not null,
 consumed_at timestamptz,
 unique(organization_id,id)
);
alter table public.bank_feed_connections enable row level security;
alter table public.bank_feed_accounts enable row level security;
alter table public.bank_feed_transactions enable row level security;
alter table public.bank_feed_link_sessions enable row level security;
create policy feed_connections_read on public.bank_feed_connections for select to authenticated
 using(public.has_org_access(organization_id));
create policy feed_accounts_read on public.bank_feed_accounts for select to authenticated
 using(public.has_org_access(organization_id));
create policy feed_transactions_read on public.bank_feed_transactions for select to authenticated
 using(public.has_org_access(organization_id));
-- Token and Link session tables have no client SELECT policy.
drop policy feed_connections_read on public.bank_feed_connections;
revoke all on public.bank_feed_connections,public.bank_feed_accounts,
 public.bank_feed_transactions,public.bank_feed_link_sessions from public,anon,authenticated;
grant select on public.bank_feed_accounts,public.bank_feed_transactions to authenticated;

create function public.map_bank_feed_account(p_org uuid,p_feed_account uuid,p_ledger_account uuid)
returns void language plpgsql security definer set search_path=''
as $$
begin
 if not exists(select 1 from public.organization_members
  where organization_id=p_org and user_id=auth.uid() and role in ('owner','administrator','accountant'))
 then raise exception 'Bank mapping requires accountant or administrator';end if;
 if p_ledger_account is not null and not exists(
  select 1 from public.accounts a where a.organization_id=p_org and a.id=p_ledger_account
  and a.is_bank_account and a.is_active) then raise exception 'Choose a designated bank ledger account';end if;
 perform 1 from public.organizations where id=p_org for update;
 update public.bank_feed_accounts set ledger_bank_account_id=p_ledger_account
 where organization_id=p_org and id=p_feed_account;
 if not found then raise exception 'Feed account not found';end if;
 perform private.write_audit(p_org,'bank.feed_account_mapped','bank_feed_account',p_feed_account,
  jsonb_build_object('ledger_account_id',p_ledger_account));
end $$;
revoke all on function public.map_bank_feed_account(uuid,uuid,uuid) from public,anon;
grant execute on function public.map_bank_feed_account(uuid,uuid,uuid) to authenticated;

-- Provider sync batches are applied atomically with the new cursor. A replay
-- updates existing IDs, never duplicates ledger or feed transactions.
create function public.apply_bank_feed_sync(
 p_connection uuid,p_expected_cursor text,p_next_cursor text,p_added jsonb,p_modified jsonb,p_removed jsonb
) returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_conn public.bank_feed_connections%rowtype;v_row jsonb;v_acc uuid;
 v_id text;v_amt numeric;v_date date;v_count int:=0;v_removed_count int:=0;
begin
 if jsonb_typeof(p_added) is distinct from 'array' or jsonb_typeof(p_modified) is distinct from 'array'
 or jsonb_typeof(p_removed) is distinct from 'array'
 or jsonb_array_length(p_added)+jsonb_array_length(p_modified)+jsonb_array_length(p_removed)>5000
 then raise exception 'Invalid feed sync batch';end if;
 select * into v_conn from public.bank_feed_connections where id=p_connection and status='active' for update;
 if not found then raise exception 'Feed connection unavailable';end if;
 if v_conn.sync_cursor is distinct from p_expected_cursor then raise exception 'Feed sync cursor conflict';end if;
 perform 1 from public.organizations where id=v_conn.organization_id for update;
 for v_row in select value from jsonb_array_elements(p_added||p_modified) loop
  v_id:=v_row->>'transaction_id';
  if length(coalesce(v_id,'')) not between 1 and 200 then raise exception 'Invalid provider transaction ID';end if;
  select id into v_acc from public.bank_feed_accounts where
   connection_id=p_connection and provider_account_id=v_row->>'account_id';
  if v_acc is null then raise exception 'Provider account must be registered before sync';end if;
  v_amt:=(v_row->>'amount')::numeric;
  v_date:=(v_row->>'date')::date;
  if v_amt is null or scale(v_amt)>2 or abs(v_amt)>999999999999
   or v_date is null or length(coalesce(v_row->>'name','')) not between 1 and 500
   then raise exception 'Invalid feed transaction';end if;
  insert into public.bank_feed_transactions(organization_id,connection_id,feed_account_id,
   provider_transaction_id,booking_date,description,amount,pending,removed)
  values(v_conn.organization_id,p_connection,v_acc,v_id,v_date,v_row->>'name',
   -v_amt,coalesce((v_row->>'pending')::boolean,false),false)
  on conflict(connection_id,provider_transaction_id) do update set
   booking_date=excluded.booking_date,description=excluded.description,
   amount=excluded.amount,pending=excluded.pending,removed=false,
   provider_updated_at=now();
  v_count:=v_count+1;
 end loop;
 for v_row in select value from jsonb_array_elements(p_removed) loop
  update public.bank_feed_transactions set removed=true,provider_updated_at=now()
   where connection_id=p_connection and provider_transaction_id=v_row->>'transaction_id';
  if found then v_removed_count:=v_removed_count+1;end if;
 end loop;
 update public.bank_feed_connections set sync_cursor=p_next_cursor,last_synced_at=now(),last_error_code=null
 where id=p_connection;
 perform private.write_audit(v_conn.organization_id,'bank.feed_synced','bank_feed',p_connection,
 jsonb_build_object('updated',v_count,'removed',v_removed_count));
 return jsonb_build_object('updated',v_count,'removed',v_removed_count);
end $$;
revoke all on function public.apply_bank_feed_sync(uuid,text,text,jsonb,jsonb,jsonb)
 from public,anon,authenticated;
grant execute on function public.apply_bank_feed_sync(uuid,text,text,jsonb,jsonb,jsonb)
 to service_role;

-- Client cannot obtain encrypted banking credentials even when its org membership is valid.
create function public.bank_feed_overview(p_org uuid)
returns table(connection_id uuid,status text,last_synced_at timestamptz,
 provider_account_id text,feed_account_id uuid,account_name text,ledger_account_id uuid)
language sql stable security definer set search_path=''
as $$
 select c.id,c.status,c.last_synced_at,a.provider_account_id,a.id,a.display_name,a.ledger_bank_account_id
 from public.bank_feed_connections c left join public.bank_feed_accounts a
 on a.connection_id=c.id and a.organization_id=c.organization_id
 where c.organization_id=p_org and public.has_org_access(c.organization_id)
$$;
revoke all on function public.bank_feed_overview(uuid) from public,anon;
grant execute on function public.bank_feed_overview(uuid) to authenticated;
