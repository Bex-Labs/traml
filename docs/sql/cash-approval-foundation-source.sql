-- Cash posting foundation. Apply only after the current role and tenant data have
-- been reconciled; existing OVR vault rows remain historical and are not replayed.
alter table public.user_profiles drop constraint if exists user_profiles_role_check;
alter table public.user_profiles add constraint user_profiles_role_check
  check (role in ('compliance_officer','bank_manager','head_of_compliance',
                 'it_admin','system_admin','it_engineer','teller',
                 'sales_rep','branch_manager'));

create table public.cash_transaction_approvals (
  id uuid primary key default gen_random_uuid(),
  tenant_id text not null,
  account_id uuid not null references public.accounts(id),
  till_id uuid not null references public.tills(id),
  requested_by uuid not null references auth.users(id),
  reviewed_by uuid references auth.users(id),
  amount numeric(15,2) not null check (amount > 0),
  direction text not null check (direction in ('DEPOSIT','WITHDRAWAL')),
  narration text,
  status text not null default 'PENDING' check (status in ('PENDING','APPROVED','REJECTED')),
  request_reference text not null unique,
  transaction_id uuid unique references public.transactions(id),
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  check (reviewed_by is distinct from requested_by),
  check ((status = 'PENDING' and reviewed_by is null and reviewed_at is null and transaction_id is null)
      or (status = 'REJECTED' and reviewed_by is not null and reviewed_at is not null and transaction_id is null)
      or (status = 'APPROVED' and reviewed_by is not null and reviewed_at is not null and transaction_id is not null))
);
create index cash_approvals_tenant_status_created on public.cash_transaction_approvals(tenant_id,status,created_at);
alter table public.cash_transaction_approvals enable row level security;
revoke all on public.cash_transaction_approvals from public, anon, authenticated;
grant select on public.cash_transaction_approvals to authenticated;
create policy cash_approvals_read on public.cash_transaction_approvals
  for select to authenticated using (
    exists (select 1 from public.user_profiles p where p.id = (select auth.uid())
      and p.is_active and p.tenant_id = cash_transaction_approvals.tenant_id
      and p.role in ('teller','sales_rep','branch_manager'))
  );

-- A receipt is inserted in the same transaction as each new ledger posting.
-- It remains pending while the evaluation worker is not deployed; backlog is visible.
create table public.transaction_evaluation_outbox (
  transaction_id uuid primary key references public.transactions(id) on delete restrict,
  tenant_id text not null,
  status text not null default 'PENDING' check (status in ('PENDING','PROCESSING','DONE','FAILED')),
  attempts integer not null default 0,
  created_at timestamptz not null default now(),
  evaluated_at timestamptz,
  last_error text
);
create index evaluation_outbox_pending on public.transaction_evaluation_outbox(created_at) where status='PENDING';
alter table public.transaction_evaluation_outbox enable row level security;
revoke all on public.transaction_evaluation_outbox from public, anon, authenticated;
create policy evaluation_receipts_read on public.transaction_evaluation_outbox
  for select to authenticated using (
    exists (select 1 from public.user_profiles p where p.id = (select auth.uid())
      and p.is_active and p.tenant_id = transaction_evaluation_outbox.tenant_id
      and p.role in ('compliance_officer','head_of_compliance','bank_manager'))
  );
grant select on public.transaction_evaluation_outbox to authenticated;

create function public.enqueue_transaction_evaluation()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_tenant text;
begin
  select c.tenant_id into v_tenant from public.accounts a
    join public.customers c on c.id=a.customer_id where a.id=new.account_id;
  if v_tenant is null then raise exception 'Transaction has no customer tenant'; end if;
  insert into public.transaction_evaluation_outbox(transaction_id,tenant_id)
    values(new.id,v_tenant);
  return new;
end $$;
revoke all on function public.enqueue_transaction_evaluation() from public, anon, authenticated;
create trigger enqueue_transaction_evaluation after insert on public.transactions
  for each row execute function public.enqueue_transaction_evaluation();

-- Existing direct client inserts remain in use for transfers. Cash postings,
-- however, must pass through the checked RPC instead of bypassing approval.
create function public.guard_direct_cash_posting()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.channel = 'BRANCH_CASH'::public.transaction_channel
     and current_user = 'authenticated' then
    raise exception 'Use the cash posting endpoint';
  end if;
  return new;
end $$;
revoke all on function public.guard_direct_cash_posting() from public, anon, authenticated;
create trigger guard_direct_cash_posting before insert on public.transactions
  for each row execute function public.guard_direct_cash_posting();

drop policy if exists "Staff can manage vault transfers" on public.vault_transfers;
create policy vault_requests_read on public.vault_transfers for select to authenticated
  using (exists (select 1 from public.user_profiles p where p.id=(select auth.uid())
    and p.is_active and p.tenant_id=vault_transfers.tenant_id
    and p.role in ('teller','sales_rep','branch_manager')));
create policy vault_requests_insert on public.vault_transfers for insert to authenticated
  with check (status='PENDING' and manager_id is null and teller_id=(select auth.uid())
    and left(reference,4)<>'OVR-' and exists
    (select 1 from public.user_profiles p where p.id=(select auth.uid()) and p.is_active
     and p.tenant_id=vault_transfers.tenant_id and p.role in ('teller','sales_rep')));
create policy vault_requests_manager_update on public.vault_transfers for update to authenticated
  using (status='PENDING' and exists
    (select 1 from public.user_profiles p where p.id=(select auth.uid()) and p.is_active
     and p.tenant_id=vault_transfers.tenant_id and p.role='branch_manager'))
  with check (status in ('APPROVED','REJECTED') and manager_id=(select auth.uid())
    and exists (select 1 from public.user_profiles p where p.id=(select auth.uid())
      and p.is_active and p.tenant_id=vault_transfers.tenant_id and p.role='branch_manager'));

create function public.guard_vault_request_update()
returns trigger language plpgsql set search_path = '' as $$
begin
  if current_user='authenticated' and
     (old.tenant_id,old.till_id,old.teller_id,old.transfer_type,old.amount,old.reference)
     is distinct from
     (new.tenant_id,new.till_id,new.teller_id,new.transfer_type,new.amount,new.reference) then
    raise exception 'Vault request fields cannot be changed during review';
  end if;
  return new;
end $$;
revoke all on function public.guard_vault_request_update() from public, anon, authenticated;
create trigger guard_vault_request_update before update on public.vault_transfers
  for each row execute function public.guard_vault_request_update();

drop policy if exists "Managers can override tills" on public.tills;
create policy branch_managers_override_tills on public.tills for update to authenticated
  using (exists (select 1 from public.user_profiles p where p.id=(select auth.uid())
    and p.is_active and p.tenant_id=tills.tenant_id and p.role='branch_manager'))
  with check (exists (select 1 from public.user_profiles p where p.id=(select auth.uid())
    and p.is_active and p.tenant_id=tills.tenant_id and p.role='branch_manager'));
create function public.guard_direct_till_balance()
returns trigger language plpgsql set search_path = '' as $$
begin
  if current_user='authenticated' and
     (old.current_balance,old.opening_balance,old.tenant_id,old.teller_id)
     is distinct from
     (new.current_balance,new.opening_balance,new.tenant_id,new.teller_id) then
    raise exception 'Till balance and ownership are server managed';
  end if;
  return new;
end $$;
revoke all on function public.guard_direct_till_balance() from public, anon, authenticated;
create trigger guard_direct_till_balance before update on public.tills
  for each row execute function public.guard_direct_till_balance();

-- A single posting function handles both ordinary cash and approved requests.
-- Lock order: account then till. The existing till trigger adjusts physical cash.
create function public.post_cash_transaction(p_account_id uuid,p_till_id uuid,
  p_amount numeric,p_direction text,p_narration text,p_request_reference text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_actor uuid := auth.uid(); v_tenant text; v_role text; v_teller uuid;
        v_till_tenant text; v_till_status text; v_till_balance numeric;
        v_account_balance numeric; v_account_status public.account_status;
        v_account_currency text; v_id uuid; v_approval uuid;
begin
  select p.tenant_id,p.role into v_tenant,v_role from public.user_profiles p
    where p.id=v_actor and p.is_active;
  if v_tenant is null or v_role not in ('teller','sales_rep') then
    raise exception 'Cash posting is restricted to active tellers'; end if;
  if p_amount is null or p_amount <= 0 or p_amount > 9999999999999.99
     or p_amount <> round(p_amount,2) or p_direction not in ('DEPOSIT','WITHDRAWAL')
     or p_request_reference is null or length(p_request_reference) < 8 then
    raise exception 'Invalid cash transaction'; end if;
  select a.balance,a.status,a.currency into v_account_balance,v_account_status,v_account_currency
    from public.accounts a join public.customers c on c.id=a.customer_id
    where a.id=p_account_id and c.tenant_id=v_tenant for update of a;
  if not found or v_account_status <> 'ACTIVE' or v_account_currency <> 'NGN' then
    raise exception 'Account unavailable'; end if;
  select t.teller_id,t.tenant_id,t.status,t.current_balance
    into v_teller,v_till_tenant,v_till_status,v_till_balance
    from public.tills t where t.id=p_till_id for update;
  if not found or v_teller<>v_actor or v_till_tenant<>v_tenant or v_till_status<>'OPEN' then
    raise exception 'Till unavailable'; end if;
  if p_direction='WITHDRAWAL' and (v_account_balance<p_amount or v_till_balance<p_amount) then
    raise exception 'Insufficient funds'; end if;
  if p_amount >= 5000000 then
    insert into public.cash_transaction_approvals
      (tenant_id,account_id,till_id,requested_by,amount,direction,narration,request_reference)
      values(v_tenant,p_account_id,p_till_id,v_actor,p_amount,p_direction,p_narration,p_request_reference)
      returning id into v_approval;
    return jsonb_build_object('status','PENDING','approval_id',v_approval);
  end if;
  insert into public.transactions(transaction_reference,account_id,amount,transaction_type,
    channel,transaction_timestamp,narration,till_id)
    values(p_request_reference,p_account_id,p_amount,
      case when p_direction='DEPOSIT' then 'CREDIT'::public.transaction_type else 'DEBIT'::public.transaction_type end,
      'BRANCH_CASH'::public.transaction_channel,now(),p_narration,p_till_id)
    returning id into v_id;
  update public.accounts set balance=balance + case when p_direction='DEPOSIT' then p_amount else -p_amount end,
    updated_at=now() where id=p_account_id;
  return jsonb_build_object('status','POSTED','transaction_id',v_id);
end $$;
revoke all on function public.post_cash_transaction(uuid,uuid,numeric,text,text,text) from public, anon;
grant execute on function public.post_cash_transaction(uuid,uuid,numeric,text,text,text) to authenticated;

create function public.review_cash_transaction(p_approval_id uuid,p_approve boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_actor uuid := auth.uid(); v_tenant text; v_role text; v_request public.cash_transaction_approvals%rowtype;
        v_account_balance numeric; v_account_status public.account_status; v_till_balance numeric;
        v_till_status text; v_id uuid;
begin
  select p.tenant_id,p.role into v_tenant,v_role from public.user_profiles p
    where p.id=v_actor and p.is_active;
  if v_role <> 'branch_manager' or v_tenant is null then
    raise exception 'Branch manager approval required'; end if;
  if p_approve is null then raise exception 'Decision required'; end if;
  select * into v_request from public.cash_transaction_approvals where id=p_approval_id for update;
  if not found or v_request.tenant_id<>v_tenant or v_request.status<>'PENDING'
     or v_request.requested_by=v_actor then raise exception 'Approval unavailable'; end if;
  if not p_approve then
    update public.cash_transaction_approvals set status='REJECTED',reviewed_by=v_actor,reviewed_at=now()
      where id=p_approval_id;
    return jsonb_build_object('status','REJECTED');
  end if;
  select a.balance,a.status into v_account_balance,v_account_status from public.accounts a
    join public.customers c on c.id=a.customer_id
    where a.id=v_request.account_id and c.tenant_id=v_tenant for update of a;
  if not found or v_account_status<>'ACTIVE' then raise exception 'Account unavailable'; end if;
  select t.current_balance,t.status into v_till_balance,v_till_status from public.tills t
    where t.id=v_request.till_id and t.tenant_id=v_tenant for update;
  if not found or v_till_status<>'OPEN' then raise exception 'Till unavailable'; end if;
  if v_request.direction='WITHDRAWAL' and
     (v_account_balance<v_request.amount or v_till_balance<v_request.amount) then
    raise exception 'Insufficient funds'; end if;
  insert into public.transactions(transaction_reference,account_id,amount,transaction_type,
    channel,transaction_timestamp,narration,till_id)
    values(v_request.request_reference,v_request.account_id,v_request.amount,
      case when v_request.direction='DEPOSIT' then 'CREDIT'::public.transaction_type else 'DEBIT'::public.transaction_type end,
      'BRANCH_CASH'::public.transaction_channel,now(),v_request.narration,v_request.till_id)
    returning id into v_id;
  update public.accounts set balance=balance + case when v_request.direction='DEPOSIT'
    then v_request.amount else -v_request.amount end,updated_at=now() where id=v_request.account_id;
  update public.cash_transaction_approvals set status='APPROVED',reviewed_by=v_actor,
    reviewed_at=now(),transaction_id=v_id where id=p_approval_id;
  return jsonb_build_object('status','POSTED','transaction_id',v_id);
end $$;
revoke all on function public.review_cash_transaction(uuid,boolean) from public, anon;
grant execute on function public.review_cash_transaction(uuid,boolean) to authenticated;
