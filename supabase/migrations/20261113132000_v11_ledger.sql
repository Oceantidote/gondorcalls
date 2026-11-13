-- Built-in expense sharing (replaces the Splitwise idea). One running balance between every pair of members.
-- Balances count everything for everyone; only the details of a birthday expense are hidden from the
-- birthday person until the gift is given. Writes go through RPCs so splits are always penny-correct.
drop function if exists public.splitwise_link_get(text, uuid), public.splitwise_link_set(text, uuid, text),
  public.splitwise_people(text, uuid), public._sw_can_set(text, uuid), public._sw_can_see(text, uuid);
drop trigger if exists sw_meetup_deleted on public.meetups;
drop function if exists public._sw_meetup_deleted();
drop table if exists public.splitwise_links;

create table public.expenses (
  id uuid primary key default gen_random_uuid(),
  description text not null check (length(trim(description)) between 1 and 120),
  amount numeric(10,2) not null check (amount > 0 and amount < 100000),
  paid_by uuid not null references public.profiles(id),
  spent_on date not null default current_date,
  split_mode text not null check (split_mode in ('equal', 'shares', 'exact')),
  meetup_id uuid references public.meetups(id) on delete set null,
  gift_id uuid references public.gifts(id) on delete set null,
  notes text not null default '' check (length(notes) <= 1000),
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  check (meetup_id is null or gift_id is null)
);
create table public.expense_shares (
  expense_id uuid not null references public.expenses(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  owed numeric(10,2) not null check (owed >= 0),
  weight numeric(10,2),            -- shares mode: the share count; exact mode: the amount typed
  primary key (expense_id, user_id)
);
create table public.settlements (
  id uuid primary key default gen_random_uuid(),
  from_user uuid not null references public.profiles(id),   -- who paid
  to_user uuid not null references public.profiles(id),     -- who received it
  amount numeric(10,2) not null check (amount > 0 and amount < 100000),
  paid_on date not null default current_date,
  note text not null default '' check (length(note) <= 200),
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  confirmed_at timestamptz,   -- set when the receiver confirms (immediately if they recorded it)
  deleted_at timestamptz,
  check (from_user <> to_user)
);
create table public.money_history (
  id bigserial primary key,
  kind text not null check (kind in ('expense', 'settlement')),
  ref_id uuid not null,
  action text not null check (action in ('added', 'edited', 'deleted', 'confirmed')),
  actor uuid references public.profiles(id),
  snapshot jsonb not null,
  at timestamptz not null default now()
);
create index on public.expenses(meetup_id) where deleted_at is null;
create index on public.expenses(gift_id) where deleted_at is null;
create index on public.expense_shares(user_id);
create index on public.money_history(ref_id);

do $$ declare t text; begin
  foreach t in array array['expenses', 'expense_shares', 'settlements', 'money_history'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $$;
-- settlements and history carry no secrets: members read them directly. Expenses go through ledger_feed.
grant select on public.settlements, public.money_history to authenticated;
create policy s_sel on public.settlements for select to authenticated using (is_member());
create policy h_sel on public.money_history for select to authenticated using (is_member());

-- Can the caller see an expense's details? (Birthday person can't until the gift is given.)
create or replace function public._expense_detail_visible(p_gift uuid, p_meetup uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select case when p_gift is not null then gift_visible(p_gift)
              when p_meetup is not null then meetup_visible(p_meetup)
              else is_member() end;
$$;

create or replace function public._expense_snapshot(p_id uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select to_jsonb(e) || jsonb_build_object('shares',
    (select coalesce(jsonb_agg(jsonb_build_object('user_id', s.user_id, 'owed', s.owed, 'weight', s.weight) order by s.user_id), '[]') from expense_shares s where s.expense_id = e.id))
  from expenses e where e.id = p_id;
$$;

-- Create (p_id null) or edit an expense. p_people: [{"user_id": "...", "value": n}]
--   equal: value ignored · shares: value = share count · exact: value = amount owed (must total the amount)
create or replace function public.expense_save(p_id uuid, p_description text, p_amount numeric, p_paid_by uuid, p_spent_on date,
  p_mode text, p_people jsonb, p_meetup uuid default null, p_gift uuid default null, p_notes text default '')
returns uuid language plpgsql security definer set search_path = public as $$
declare
  old expenses; eid uuid; pence bigint := round(p_amount * 100); total_w numeric := 0; given bigint := 0;
  r record; n int; hidden uuid[] := '{}';
begin
  if not is_member() then raise exception 'Not allowed'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Enter an amount'; end if;
  if p_mode not in ('equal', 'shares', 'exact') then raise exception 'Bad split'; end if;
  if p_meetup is not null and p_gift is not null then raise exception 'Pick a meetup or a present, not both'; end if;
  if p_meetup is not null and not meetup_visible(p_meetup) then raise exception 'Not allowed'; end if;
  if p_gift is not null and not gift_visible(p_gift) then raise exception 'Not allowed'; end if;
  if p_id is not null then
    select * into old from expenses where id = p_id and deleted_at is null;
    if not found then raise exception 'Expense not found'; end if;
    if auth.uid() not in (old.created_by, old.paid_by) and not is_admin() then raise exception 'Only whoever added or paid for this can change it'; end if;
    if not _expense_detail_visible(old.gift_id, old.meetup_id) then raise exception 'Not allowed'; end if;
  end if;
  if p_gift is not null then select g.hidden_from into hidden from gifts g where g.id = p_gift; end if;
  if p_meetup is not null then select m.hidden_from into hidden from meetups m where m.id = p_meetup; end if;

  drop table if exists _p;
  create temp table _p (user_id uuid primary key, val numeric, owed_p bigint, frac numeric) on commit drop;
  insert into _p(user_id, val)
    select (x->>'user_id')::uuid, coalesce((x->>'value')::numeric, 1) from jsonb_array_elements(coalesce(p_people, '[]')) x
    on conflict (user_id) do nothing;
  select count(*) into n from _p;
  if n = 0 then raise exception 'Pick who this was for'; end if;
  if exists (select 1 from _p where user_id not in (select id from profiles)) or p_paid_by not in (select id from profiles) then raise exception 'Unknown member'; end if;
  if exists (select 1 from _p where user_id = any(hidden)) or p_paid_by = any(hidden) then raise exception 'Someone in this split can''t see it (birthday person?)'; end if;

  if p_mode = 'exact' then
    if exists (select 1 from _p where val < 0) then raise exception 'Amounts can''t be negative'; end if;
    update _p set owed_p = round(val * 100);
    if (select sum(owed_p) from _p) <> pence then
      raise exception 'The amounts add up to £% but the expense is £%', (select sum(owed_p) from _p) / 100.0, pence / 100.0;
    end if;
  else
    if p_mode = 'equal' then update _p set val = 1; end if;
    if exists (select 1 from _p where val <= 0) then raise exception 'Shares must be more than zero'; end if;
    select sum(val) into total_w from _p;
    update _p set owed_p = floor(pence * val / total_w), frac = (pence * val / total_w) - floor(pence * val / total_w);
    select sum(owed_p) into given from _p;
    -- hand out leftover pennies to the biggest remainders (ties: payer first, then by id) so it always adds up
    for r in select user_id from _p order by frac desc, (user_id = p_paid_by) desc, user_id limit (pence - given) loop
      update _p set owed_p = owed_p + 1 where user_id = r.user_id;
    end loop;
  end if;

  if p_id is null then
    insert into expenses(description, amount, paid_by, spent_on, split_mode, meetup_id, gift_id, notes, created_by)
    values (trim(p_description), pence / 100.0, p_paid_by, coalesce(p_spent_on, current_date), p_mode, p_meetup, p_gift, coalesce(p_notes, ''), auth.uid())
    returning id into eid;
  else
    eid := p_id;
    update expenses set description = trim(p_description), amount = pence / 100.0, paid_by = p_paid_by, spent_on = coalesce(p_spent_on, spent_on),
      split_mode = p_mode, meetup_id = p_meetup, gift_id = p_gift, notes = coalesce(p_notes, ''), updated_at = now() where id = eid;
    delete from expense_shares where expense_id = eid;
  end if;
  insert into expense_shares(expense_id, user_id, owed, weight)
    select eid, user_id, owed_p / 100.0, case when p_mode = 'equal' then null else val end from _p;
  insert into money_history(kind, ref_id, action, actor, snapshot)
    values ('expense', eid, case when p_id is null then 'added' else 'edited' end, auth.uid(), _expense_snapshot(eid));

  if p_id is null then
    perform queue_email('expense_added',
      array(select user_id from _p where user_id <> auth.uid() and owed_p > 0),
      _name(p_paid_by) || ' paid £' || trim(to_char(pence / 100.0, 'FM999990.00')) || ' for ' ||
        case when p_gift is not null then 'a birthday present' else trim(p_description) end,
      _name(auth.uid()) || ' added an expense' || case when p_gift is not null then ' for a birthday present' else ': ' || trim(p_description) end ||
        '. Your balances on Gondor Calls have been updated.',
      '#money');
  end if;
  return eid;
end $$;

create or replace function public.expense_delete(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare e expenses;
begin
  select * into e from expenses where id = p_id and deleted_at is null;
  if not found then raise exception 'Expense not found'; end if;
  if auth.uid() not in (e.created_by, e.paid_by) and not is_admin() then raise exception 'Only whoever added or paid for this can delete it'; end if;
  if not _expense_detail_visible(e.gift_id, e.meetup_id) then raise exception 'Not allowed'; end if;
  update expenses set deleted_at = now() where id = p_id;
  insert into money_history(kind, ref_id, action, actor, snapshot) values ('expense', p_id, 'deleted', auth.uid(), _expense_snapshot(p_id));
end $$;

-- Expenses with details redacted for anyone they're hidden from.
create or replace function public.ledger_feed(p_meetup uuid default null, p_gift uuid default null, p_limit int default 200)
returns table(id uuid, description text, amount numeric, paid_by uuid, spent_on date, split_mode text, meetup_id uuid, gift_id uuid,
  notes text, created_by uuid, created_at timestamptz, updated_at timestamptz, hidden boolean, shares jsonb)
language sql stable security definer set search_path = public as $$
  select e.id,
    case when v then e.description else '🎁 A birthday present' end, e.amount, e.paid_by, e.spent_on, e.split_mode,
    case when v then e.meetup_id end, case when v then e.gift_id end, case when v then e.notes else '' end,
    e.created_by, e.created_at, e.updated_at, not v,
    (select coalesce(jsonb_agg(jsonb_build_object('user_id', s.user_id, 'owed', s.owed, 'weight', s.weight)), '[]') from expense_shares s where s.expense_id = e.id)
  from expenses e cross join lateral (select _expense_detail_visible(e.gift_id, e.meetup_id) v) x
  where is_member() and e.deleted_at is null
    and (p_meetup is null or (e.meetup_id = p_meetup and v)) and (p_gift is null or (e.gift_id = p_gift and v))
  order by e.spent_on desc, e.created_at desc limit least(coalesce(p_limit, 200), 1000);
$$;

-- Net balance for every pair: amount > 0 means debtor owes creditor. Unconfirmed settlements count too.
create or replace function public.ledger_balances()
returns table(debtor uuid, creditor uuid, amount numeric)
language sql stable security definer set search_path = public as $$
  with flows as (   -- x owes y
    select s.user_id x, e.paid_by y, s.owed amt from expenses e join expense_shares s on s.expense_id = e.id
      where e.deleted_at is null and s.user_id <> e.paid_by
    union all
    select to_user, from_user, amount from settlements where deleted_at is null   -- paying back reduces your debt
  ), pair as (
    select least(x, y) a, greatest(x, y) b, sum(case when x < y then amt else -amt end) net from flows group by 1, 2
  )
  select case when net > 0 then a else b end, case when net > 0 then b else a end, abs(net)
  from pair where is_member() and net <> 0;
$$;

-- Record a payment between two people. Either of them can record it; the receiver confirms.
create or replace function public.settlement_add(p_from uuid, p_to uuid, p_amount numeric, p_paid_on date default current_date, p_note text default '')
returns uuid language plpgsql security definer set search_path = public as $$
declare sid uuid;
begin
  if not is_member() or auth.uid() not in (p_from, p_to) then raise exception 'You can only record payments you made or received'; end if;
  if p_from = p_to then raise exception 'Pick someone else'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Enter an amount'; end if;
  insert into settlements(from_user, to_user, amount, paid_on, note, created_by, confirmed_at)
    values (p_from, p_to, round(p_amount, 2), coalesce(p_paid_on, current_date), coalesce(p_note, ''), auth.uid(), case when auth.uid() = p_to then now() end)
    returning id into sid;
  insert into money_history(kind, ref_id, action, actor, snapshot) select 'settlement', sid, 'added', auth.uid(), to_jsonb(s) from settlements s where s.id = sid;
  perform queue_email('settlement', array[case when auth.uid() = p_from then p_to else p_from end],
    case when auth.uid() = p_from then _name(p_from) || ' says they paid you £' else _name(p_to) || ' recorded that you paid them £' end
      || trim(to_char(round(p_amount, 2), 'FM999990.00')),
    case when auth.uid() = p_from then 'Check it arrived, then confirm it on the Money page.' else 'Your balance has been updated.' end, '#money');
  return sid;
end $$;

create or replace function public.settlement_confirm(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update settlements set confirmed_at = now() where id = p_id and to_user = auth.uid() and confirmed_at is null and deleted_at is null;
  if not found then raise exception 'Only the person who received it can confirm'; end if;
  insert into money_history(kind, ref_id, action, actor, snapshot) select 'settlement', p_id, 'confirmed', auth.uid(), to_jsonb(s) from settlements s where s.id = p_id;
end $$;

create or replace function public.settlement_delete(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update settlements set deleted_at = now() where id = p_id and deleted_at is null
    and (is_admin() or (created_by = auth.uid() and confirmed_at is null) or (to_user = auth.uid()));
  if not found then raise exception 'Can''t remove that one'; end if;
  insert into money_history(kind, ref_id, action, actor, snapshot) select 'settlement', p_id, 'deleted', auth.uid(), to_jsonb(s) from settlements s where s.id = p_id;
end $$;

-- Presents: buying one now books an expense (everyone but the birthday person owes the agreed amount each).
create or replace function public.gift_mark_bought(p_gift uuid, p_title text, p_url text, p_cost numeric) returns void
language plpgsql security definer set search_path = public as $$
declare g gifts; ppl jsonb;
begin
  select * into g from gifts where id = p_gift;
  if g.buyer_id is distinct from auth.uid() or g.status <> 'planning' then raise exception 'Only the buyer can do this'; end if;
  update gifts set status = 'bought', gift_title = left(p_title, 160), gift_url = nullif(p_url, ''), total_cost = p_cost where id = p_gift;
  select jsonb_agg(jsonb_build_object('user_id', p.id, 'value', g.per_person)) into ppl from profiles p where p.id <> g.recipient_id;
  perform expense_save(null, 'Present for ' || _name(g.recipient_id) || ': ' || left(p_title, 80),
    g.per_person * jsonb_array_length(ppl), auth.uid(), current_date, 'exact', ppl, null, p_gift, '');
end $$;

create or replace function public.gift_undo_bought(p_gift uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from gifts where id = p_gift and buyer_id = auth.uid() and status = 'bought') then raise exception 'Only the buyer can do this'; end if;
  update expenses set deleted_at = now() where gift_id = p_gift and deleted_at is null;
  update gifts set status = 'planning' where id = p_gift;
end $$;

create or replace function public.trg_email_gifts() returns trigger
language plpgsql security definer set search_path = public as $$
declare who text := _name(new.recipient_id);
begin
  if tg_op = 'INSERT' then
    perform queue_email('gift_open', _everyone_except(array[new.recipient_id] || new.hidden_from),
      'Present planning: ' || who || ' on ' || to_char(new.birthday_on, 'FMDD FMMonth'),
      who || '''s birthday is on ' || to_char(new.birthday_on, 'FMDay FMDD FMMonth') || '. A gift plan is open (hidden from ' || who ||
      '). Add ideas, vote, and someone volunteer to buy it. Don''t mention it in the group chat!',
      '#gift/' || new.id);
  end if;   -- "bought" is announced by the expense email instead
  return new;
end $$;

drop table if exists public.gift_contributions;

revoke execute on function public._expense_detail_visible(uuid, uuid), public._expense_snapshot(uuid) from public, anon, authenticated;
revoke execute on function public.expense_save(uuid, text, numeric, uuid, date, text, jsonb, uuid, uuid, text), public.expense_delete(uuid),
  public.ledger_feed(uuid, uuid, int), public.ledger_balances(), public.settlement_add(uuid, uuid, numeric, date, text),
  public.settlement_confirm(uuid), public.settlement_delete(uuid) from public, anon;
grant execute on function public.expense_save(uuid, text, numeric, uuid, date, text, jsonb, uuid, uuid, text), public.expense_delete(uuid),
  public.ledger_feed(uuid, uuid, int), public.ledger_balances(), public.settlement_add(uuid, uuid, numeric, date, text),
  public.settlement_confirm(uuid), public.settlement_delete(uuid) to authenticated;
