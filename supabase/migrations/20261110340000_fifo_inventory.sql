-- Milestone 9: Perpetual FIFO inventory for CAD-only invoice/bill workflows.
-- Bills retain their normal expense posting, receipt reclassifies that expense
-- to inventory. Invoice dispatch creates COGS only after the invoice is posted.
-- No direct client writes. All transitions lock the organization and source lines.
alter table public.financial_document_lines add constraint financial_document_lines_org_id_unique unique(organization_id,id);

create table public.inventory_products(
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null references public.organizations(id) on delete restrict,
 sku varchar(80) not null,
 name varchar(180) not null,
 active boolean not null default true,
 created_by uuid not null references auth.users(id),
 created_at timestamptz not null default now(),
 unique(organization_id,id),unique(organization_id,sku)
);
create table public.inventory_receipts(
 id uuid primary key default gen_random_uuid(),
 fifo_sequence bigint generated always as identity unique,
 receipt_sequence bigint generated always as identity,
 organization_id uuid not null,
 product_id uuid not null,
 bill_line_id uuid not null,
 quantity numeric(12,3) not null check(quantity>0),
 initial_cost numeric(20,2) not null check(initial_cost>=0),
 remaining_quantity numeric(12,3) not null check(remaining_quantity>=0),
 remaining_cost numeric(20,2) not null check(remaining_cost>=0),
 received_on date not null,
 journal_entry_id uuid not null,
 idempotency_key uuid not null,
 created_by uuid not null references auth.users(id),
 created_at timestamptz not null default now(),
 unique(organization_id,id),unique(organization_id,bill_line_id),
 unique(organization_id,idempotency_key),
 foreign key(organization_id,product_id) references public.inventory_products(organization_id,id),
 foreign key(organization_id,bill_line_id) references public.financial_document_lines(organization_id,id),
 foreign key(organization_id,journal_entry_id) references public.journal_entries(organization_id,id),
 check(remaining_quantity<=quantity),
 check(remaining_cost<=initial_cost)
);
create table public.inventory_issues(
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null,
 product_id uuid not null,
 invoice_line_id uuid not null,
 quantity numeric(12,3) not null check(quantity>0),
 total_cost numeric(20,2) not null check(total_cost>=0),
 issued_on date not null,
 journal_entry_id uuid not null,
 idempotency_key uuid not null,
 created_by uuid not null references auth.users(id),
 created_at timestamptz not null default now(),
 unique(organization_id,id),unique(organization_id,invoice_line_id),
 unique(organization_id,idempotency_key),
 foreign key(organization_id,product_id) references public.inventory_products(organization_id,id),
 foreign key(organization_id,invoice_line_id) references public.financial_document_lines(organization_id,id),
 foreign key(organization_id,journal_entry_id) references public.journal_entries(organization_id,id)
);
create table public.inventory_issue_lots(
 organization_id uuid not null,
 issue_id uuid not null,
 receipt_id uuid not null,
 quantity numeric(12,3) not null check(quantity>0),
 cost numeric(20,2) not null check(cost>=0),
 primary key(organization_id,issue_id,receipt_id),
 foreign key(organization_id,issue_id) references public.inventory_issues(organization_id,id),
 foreign key(organization_id,receipt_id) references public.inventory_receipts(organization_id,id)
);
create index inventory_fifo_idx on public.inventory_receipts(organization_id,product_id,received_on,fifo_sequence)
 where remaining_quantity>0;
create index inventory_issues_product_idx on public.inventory_issues(organization_id,product_id,issued_on);
alter table public.inventory_products enable row level security;
alter table public.inventory_receipts enable row level security;
alter table public.inventory_issues enable row level security;
alter table public.inventory_issue_lots enable row level security;
create policy inventory_products_read on public.inventory_products for select to authenticated using(public.has_org_access(organization_id));
create policy inventory_receipts_read on public.inventory_receipts for select to authenticated using(public.has_org_access(organization_id));
create policy inventory_issues_read on public.inventory_issues for select to authenticated using(public.has_org_access(organization_id));
create policy inventory_issue_lots_read on public.inventory_issue_lots for select to authenticated using(public.has_org_access(organization_id));
revoke all on public.inventory_products,public.inventory_receipts,public.inventory_issues,public.inventory_issue_lots
 from public,anon,authenticated;
grant select on public.inventory_products,public.inventory_receipts,public.inventory_issues,public.inventory_issue_lots
 to authenticated;

insert into public.accounts(organization_id,code,name,account_type,normal_balance)
select o.id,'1400','Inventory Asset','asset','debit' from public.organizations o
where not exists(select 1 from public.accounts a where a.organization_id=o.id and a.code='1400');
insert into public.accounts(organization_id,code,name,account_type,normal_balance)
select o.id,'5200','Cost of Goods Sold','expense','debit' from public.organizations o
where not exists(select 1 from public.accounts a where a.organization_id=o.id and a.code='5200');

create function private.seed_inventory_accounts() returns trigger
 language plpgsql set search_path=''
as $$
begin
 if new.code='5000' and new.account_type='expense' then
  insert into public.accounts(organization_id,code,name,account_type,normal_balance)
  values(new.organization_id,'1400','Inventory Asset','asset','debit'),
        (new.organization_id,'5200','Cost of Goods Sold','expense','debit')
  on conflict(organization_id,code) do nothing;
 end if;
 return new;
end $$;
create trigger seed_inventory_accounts after insert on public.accounts
 for each row execute function private.seed_inventory_accounts();
revoke all on function private.seed_inventory_accounts() from public,anon,authenticated;

create function public.create_inventory_product(p_org uuid,p_sku text,p_name text)
returns uuid language plpgsql security definer set search_path=''
as $$
declare v_id uuid;
begin
 if not public.has_org_write(p_org) then raise exception 'Not authorized';end if;
 if p_sku is null or p_sku !~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$'
 or p_name is null or length(trim(p_name)) not between 2 and 180
 then raise exception 'Invalid inventory product';end if;
 insert into public.inventory_products(organization_id,sku,name,created_by)
 values(p_org,upper(trim(p_sku)),trim(p_name),auth.uid()) returning id into v_id;
 perform private.write_audit(p_org,'inventory.product_created','inventory_product',v_id,
 jsonb_build_object('sku',upper(trim(p_sku))));
 return v_id;
end $$;

create function public.receive_inventory_bill_line(
 p_org uuid,p_product uuid,p_line uuid,p_date date,p_key uuid
) returns uuid language plpgsql security definer set search_path=''
as $$
declare v_doc public.financial_documents%rowtype;
 v_line public.financial_document_lines%rowtype;v_inventory uuid;
 v_id uuid;v_journal uuid;v_cost numeric(20,2);
begin
 if not public.has_org_write(p_org) then raise exception 'Not authorized';end if;
 if p_date is null or p_key is null then raise exception 'Receipt date and idempotency key required';end if;
 perform 1 from public.organizations where id=p_org for update;
 select id into v_id from public.inventory_receipts where organization_id=p_org and idempotency_key=p_key;
 if found then
  if not exists(select 1 from public.inventory_receipts where id=v_id and organization_id=p_org
    and product_id=p_product and bill_line_id=p_line and received_on=p_date)
  then raise exception 'Receipt idempotency key reused with different source';end if;
  return v_id;
 end if;
 if not exists(select 1 from public.inventory_products
  where organization_id=p_org and id=p_product and active)
 then raise exception 'Product not found or inactive';end if;
 select * into v_line from public.financial_document_lines
 where organization_id=p_org and id=p_line for update;
 if not found then raise exception 'Bill line not found';end if;
 select * into v_doc from public.financial_documents where organization_id=p_org and
  id=v_line.document_id and status='posted' and document_type='bill';
 if not found or p_date<v_doc.issue_date then raise exception 'Receipt needs posted supplier bill and valid date';end if;
 if exists(select 1 from public.inventory_receipts where organization_id=p_org and bill_line_id=p_line)
 then raise exception 'Bill line already received into inventory';end if;
 if exists(select 1 from public.inventory_issues where organization_id=p_org
  and product_id=p_product and issued_on>p_date)
 then raise exception 'Backdated inventory receipt requires an accountant-led FIFO restatement';end if;
 -- Reclassify all bill line costs including nonrecoverable sales tax out of
 -- the expense account recognized by posting the bill.
 v_cost:=v_line.amount+v_line.tax_amount-v_line.recoverable_tax;
 if v_cost<=0 or v_line.quantity<=0 then raise exception 'Bill line must have positive cost and quantity';end if;
 if not exists(select 1 from public.accounts where organization_id=p_org
  and id=v_line.account_id and account_type='expense' and is_active)
 then raise exception 'Inventory bill line must initially post to an expense account';end if;
 select id into v_inventory from public.accounts where organization_id=p_org
  and code='1400' and account_type='asset' and is_active;
 if v_inventory is null then raise exception 'Inventory asset account is unavailable';end if;
 v_journal:=private.post_accounting_journal_internal('manual',p_org,p_date,
   'Inventory receipt for posted bill line','INVENTORY-RECEIPT',p_key,jsonb_build_array(
    jsonb_build_object('account_id',v_inventory,'debit',v_cost,'credit',0),
    jsonb_build_object('account_id',v_line.account_id,'debit',0,'credit',v_cost)));
 insert into public.inventory_receipts(organization_id,product_id,bill_line_id,quantity,
 initial_cost,remaining_quantity,remaining_cost,received_on,journal_entry_id,
 idempotency_key,created_by)
 values(p_org,p_product,p_line,v_line.quantity,v_cost,v_line.quantity,v_cost,p_date,
 v_journal,p_key,auth.uid()) returning id into v_id;
 perform private.write_audit(p_org,'inventory.received','inventory_receipt',v_id,
 jsonb_build_object('quantity',v_line.quantity,'cost',v_cost,'bill_line_id',p_line));
 return v_id;
end $$;

create function public.issue_inventory_invoice_line(
 p_org uuid,p_product uuid,p_line uuid,p_date date,p_key uuid
) returns uuid language plpgsql security definer set search_path=''
as $$
declare v_doc public.financial_documents%rowtype;
 v_line public.financial_document_lines%rowtype;
 v_lot public.inventory_receipts%rowtype;v_id uuid;v_journal uuid;
 v_available numeric;v_remaining numeric;v_take numeric;v_cost numeric;
 v_total numeric(20,2):=0;v_stock uuid;v_cogs uuid;v_consumptions jsonb:='[]'::jsonb;
 v_consumption jsonb;
begin
 if not public.has_org_write(p_org) then raise exception 'Not authorized';end if;
 if p_key is null or p_date is null then raise exception 'Issue key/date required';end if;
 perform 1 from public.organizations where id=p_org for update;
 select id into v_id from public.inventory_issues where organization_id=p_org and idempotency_key=p_key;
 if found then
  if not exists(select 1 from public.inventory_issues where id=v_id and organization_id=p_org
   and product_id=p_product and invoice_line_id=p_line and issued_on=p_date)
  then raise exception 'Inventory issue key conflict';end if;
  return v_id;
 end if;
 if not exists(select 1 from public.inventory_products
  where organization_id=p_org and id=p_product and active)
 then raise exception 'Product not found or inactive';end if;
 select * into v_line from public.financial_document_lines
 where organization_id=p_org and id=p_line for update;
 if not found then raise exception 'Invoice line missing';end if;
 select * into v_doc from public.financial_documents where organization_id=p_org
 and id=v_line.document_id and status='posted' and document_type='invoice';
 if not found or p_date<v_doc.issue_date then raise exception 'Issue requires posted invoice and valid date';end if;
 if exists(select 1 from public.inventory_issues where organization_id=p_org and invoice_line_id=p_line)
 then raise exception 'Invoice line has already been issued';end if;
 if exists(select 1 from public.inventory_issues where organization_id=p_org and
  product_id=p_product and issued_on>p_date) then
  raise exception 'Backdated FIFO dispatch requires an accountant-led stock restatement';end if;
 select coalesce(sum(remaining_quantity),0) into v_available
 from public.inventory_receipts where organization_id=p_org and product_id=p_product
 and received_on<=p_date;
 if v_available<v_line.quantity then raise exception 'Insufficient inventory on hand';end if;
 v_remaining:=v_line.quantity;
 for v_lot in select * from public.inventory_receipts
  where organization_id=p_org and product_id=p_product and received_on<=p_date
  and remaining_quantity>0 order by received_on,receipt_sequence for update loop
  exit when v_remaining=0;
  v_take:=least(v_lot.remaining_quantity,v_remaining);
  v_cost:=case when v_take=v_lot.remaining_quantity then v_lot.remaining_cost
   else round(v_lot.remaining_cost*v_take/v_lot.remaining_quantity,2) end;
  v_total:=v_total+v_cost;
  v_consumptions:=v_consumptions||jsonb_build_array(jsonb_build_object(
   'receipt_id',v_lot.id,'quantity',v_take,'cost',v_cost));
  update public.inventory_receipts set
    remaining_quantity=remaining_quantity-v_take,remaining_cost=remaining_cost-v_cost
   where id=v_lot.id;
  v_remaining:=v_remaining-v_take;
 end loop;
 if v_remaining<>0 or v_total<0 then raise exception 'Inventory allocation could not complete';end if;
 if v_total=0 then raise exception 'Zero-cost inventory must be reviewed manually before dispatch';end if;
 select id into v_stock from public.accounts where organization_id=p_org and code='1400'
  and account_type='asset' and is_active;
 select id into v_cogs from public.accounts where organization_id=p_org and code='5200'
  and account_type='expense' and is_active;
 if v_stock is null or v_cogs is null then raise exception 'Inventory accounting accounts unavailable';end if;
 v_journal:=private.post_accounting_journal_internal('manual',p_org,p_date,
   'FIFO inventory cost for posted invoice','INVENTORY-COGS',p_key,
   jsonb_build_array(
    jsonb_build_object('account_id',v_cogs,'debit',v_total,'credit',0),
    jsonb_build_object('account_id',v_stock,'debit',0,'credit',v_total)));
 insert into public.inventory_issues(organization_id,product_id,invoice_line_id,quantity,
 total_cost,issued_on,journal_entry_id,idempotency_key,created_by)
 values(p_org,p_product,p_line,v_line.quantity,v_total,p_date,v_journal,p_key,auth.uid())
 returning id into v_id;
 for v_consumption in select value from jsonb_array_elements(v_consumptions) loop
  insert into public.inventory_issue_lots(organization_id,issue_id,receipt_id,quantity,cost)
  values(p_org,v_id,(v_consumption->>'receipt_id')::uuid,
    (v_consumption->>'quantity')::numeric,(v_consumption->>'cost')::numeric);
 end loop;
 perform private.write_audit(p_org,'inventory.issued','inventory_issue',v_id,
 jsonb_build_object('quantity',v_line.quantity,'cost',v_total,'invoice_line_id',p_line));
 return v_id;
end $$;

create function public.inventory_stock_summary(p_org uuid)
returns table(product_id uuid,sku text,name text,quantity numeric,cost numeric)
language sql stable security definer set search_path=''
as $$
 select p.id,p.sku::text,p.name::text,
  coalesce(sum(r.remaining_quantity),0)::numeric,
  coalesce(sum(r.remaining_cost),0)::numeric
 from public.inventory_products p left join public.inventory_receipts r
  on r.organization_id=p.organization_id and r.product_id=p.id
 where p.organization_id=p_org and public.has_org_access(p_org)
 group by p.id,p.sku,p.name order by p.sku
$$;
revoke all on function public.create_inventory_product(uuid,text,text),
 public.receive_inventory_bill_line(uuid,uuid,uuid,date,uuid),
 public.issue_inventory_invoice_line(uuid,uuid,uuid,date,uuid),
 public.inventory_stock_summary(uuid) from public,anon;
grant execute on function public.create_inventory_product(uuid,text,text),
 public.receive_inventory_bill_line(uuid,uuid,uuid,date,uuid),
 public.issue_inventory_invoice_line(uuid,uuid,uuid,date,uuid),
 public.inventory_stock_summary(uuid) to authenticated;
