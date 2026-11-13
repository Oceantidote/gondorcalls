create table public.gifts (
  id uuid primary key default gen_random_uuid(),
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  birthday_on date not null,
  status text not null default 'planning' check (status in ('planning','bought','given')),
  per_person numeric(8,2) not null default 25 check (per_person >= 0),
  buyer_id uuid references public.profiles(id) on delete set null,
  gift_title text, gift_url text check (gift_url is null or gift_url ~ '^https?://'),
  total_cost numeric(10,2) check (total_cost is null or total_cost >= 0),
  photo_path text check (photo_path is null or photo_path ~ '^gifts/[0-9]{4}/[0-9a-f-]{36}/[0-9a-f-]{36}\.jpg$'),
  notes text not null default '' check (length(notes) <= 2000),
  hidden_from uuid[] not null,
  created_at timestamptz not null default now(),
  unique (recipient_id, birthday_on)
);
create table public.gift_ideas (
  id uuid primary key default gen_random_uuid(),
  gift_id uuid not null references public.gifts(id) on delete cascade,
  title text not null check (length(trim(title)) between 1 and 160),
  url text check (url is null or url ~ '^https?://'),
  price numeric(10,2) check (price is null or price >= 0),
  added_by uuid not null default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
create table public.gift_idea_votes (
  idea_id uuid not null references public.gift_ideas(id) on delete cascade,
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  primary key (idea_id, user_id)
);
create table public.gift_contributions (
  gift_id uuid not null references public.gifts(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  amount numeric(8,2) not null,
  paid boolean not null default false,
  primary key (gift_id, user_id)
);

create or replace function public.gift_visible(p_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from gifts g where g.id = p_id and can_see(g.hidden_from));
$$;
create or replace function public.gift_open(p_id uuid) returns boolean   -- still being planned/bought: recipient excluded
language sql stable security definer set search_path = public as $$
  select exists (select 1 from gifts g where g.id = p_id and g.status <> 'given' and can_see(g.hidden_from));
$$;

do $$ declare t text; begin
  foreach t in array array['gifts','gift_ideas','gift_idea_votes','gift_contributions'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
  end loop;
end $$;
grant insert, delete on public.gift_ideas, public.gift_idea_votes to authenticated;
grant update (per_person, notes, gift_title, gift_url) on public.gifts to authenticated;
grant update (paid) on public.gift_contributions to authenticated;

create policy g_sel on public.gifts for select to authenticated using (can_see(hidden_from));
create policy g_upd on public.gifts for update to authenticated using (gift_open(id)) with check (gift_open(id));
create policy gi_sel on public.gift_ideas for select to authenticated using (gift_visible(gift_id));
create policy gi_ins on public.gift_ideas for insert to authenticated with check (gift_open(gift_id) and added_by = auth.uid());
create policy gi_del on public.gift_ideas for delete to authenticated using (gift_open(gift_id) and (added_by = auth.uid() or is_admin()));
create policy gv_sel on public.gift_idea_votes for select to authenticated using (exists (select 1 from gift_ideas i where i.id = idea_id and gift_visible(i.gift_id)));
create policy gv_ins on public.gift_idea_votes for insert to authenticated with check (user_id = auth.uid() and exists (select 1 from gift_ideas i where i.id = idea_id and gift_open(i.gift_id)));
create policy gv_del on public.gift_idea_votes for delete to authenticated using (user_id = auth.uid());
create policy gc_sel on public.gift_contributions for select to authenticated using (gift_visible(gift_id));
-- you mark your own payment; the buyer can confirm anyone's
create policy gc_upd on public.gift_contributions for update to authenticated
  using (gift_visible(gift_id) and (user_id = auth.uid() or exists (select 1 from gifts g where g.id = gift_id and g.buyer_id = auth.uid())))
  with check (gift_visible(gift_id));

-- next birthday on/after a date (29 Feb -> 28 Feb in other years)
create or replace function public.next_birthday(p_bday date, p_from date default current_date) returns date
language sql immutable as $$
  select case when d >= p_from then d else (p_bday + make_interval(years => extract(year from p_from)::int + 1 - extract(year from p_bday)::int))::date end
  from (select (p_bday + make_interval(years => extract(year from p_from)::int - extract(year from p_bday)::int))::date d) x;
$$;

-- Opens a gift plan 28 days before each birthday. Runs daily (Worker cron) and on page load.
create or replace function public.open_gift_plans() returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  insert into gifts(recipient_id, birthday_on, hidden_from)
  select p.id, next_birthday(p.birthday), array[p.id] from profiles p
  where p.birthday is not null and next_birthday(p.birthday) <= current_date + 28
  on conflict (recipient_id, birthday_on) do nothing;
  get diagnostics n = row_count; return n;
end $$;

-- start one early (anyone except the birthday person)
create or replace function public.start_gift_plan(p_recipient uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare b date; gid uuid;
begin
  if not is_member() or p_recipient = auth.uid() then raise exception 'Not allowed'; end if;
  select next_birthday(birthday) into b from profiles where id = p_recipient;
  if b is null then raise exception 'They have not added their birthday yet'; end if;
  insert into gifts(recipient_id, birthday_on, hidden_from) values (p_recipient, b, array[p_recipient])
    on conflict (recipient_id, birthday_on) do update set recipient_id = excluded.recipient_id returning id into gid;
  return gid;
end $$;

create or replace function public.gift_claim_buyer(p_gift uuid, p_claim boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not gift_open(p_gift) then raise exception 'Not allowed'; end if;
  if p_claim then update gifts set buyer_id = auth.uid() where id = p_gift and status = 'planning' and buyer_id is null;
  else update gifts set buyer_id = null where id = p_gift and status = 'planning' and buyer_id = auth.uid(); end if;
  if not found then raise exception 'Someone else is already buying it'; end if;
end $$;

-- buyer records the purchase; everyone except the birthday person owes per_person
create or replace function public.gift_mark_bought(p_gift uuid, p_title text, p_url text, p_cost numeric) returns void
language plpgsql security definer set search_path = public as $$
declare g gifts;
begin
  select * into g from gifts where id = p_gift;
  if g.buyer_id is distinct from auth.uid() or g.status <> 'planning' then raise exception 'Only the buyer can do this'; end if;
  update gifts set status = 'bought', gift_title = left(p_title, 160), gift_url = nullif(p_url, ''), total_cost = p_cost where id = p_gift;
  insert into gift_contributions(gift_id, user_id, amount, paid)
    select p_gift, p.id, g.per_person, p.id = auth.uid() from profiles p where p.id <> g.recipient_id
    on conflict do nothing;
end $$;

create or replace function public.gift_undo_bought(p_gift uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from gifts where id = p_gift and buyer_id = auth.uid() and status = 'bought') then raise exception 'Only the buyer can do this'; end if;
  delete from gift_contributions where gift_id = p_gift;
  update gifts set status = 'planning' where id = p_gift;
end $$;

-- handed over: reveal the page to the birthday person
create or replace function public.gift_mark_given(p_gift uuid, p_photo text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not gift_open(p_gift) or not exists (select 1 from gifts where id = p_gift and status = 'bought') then raise exception 'Mark it bought first'; end if;
  if p_photo is not null and p_photo !~ ('^gifts/[0-9]{4}/' || auth.uid() || '/[0-9a-f-]{36}\.jpg$') then raise exception 'Bad photo path'; end if;
  update gifts set status = 'given', photo_path = coalesce(p_photo, photo_path), hidden_from = '{}' where id = p_gift;
end $$;

create or replace function public.ping() returns text language plpgsql security definer set search_path = public as $$
begin perform open_gift_plans(); return 'ok'; end $$;

revoke execute on function public.open_gift_plans(), public.start_gift_plan(uuid), public.gift_claim_buyer(uuid,boolean),
  public.gift_mark_bought(uuid,text,text,numeric), public.gift_undo_bought(uuid), public.gift_mark_given(uuid,text),
  public.gift_visible(uuid), public.gift_open(uuid), public.next_birthday(date,date) from public, anon;
grant execute on function public.open_gift_plans(), public.start_gift_plan(uuid), public.gift_claim_buyer(uuid,boolean),
  public.gift_mark_bought(uuid,text,text,numeric), public.gift_undo_bought(uuid), public.gift_mark_given(uuid,text),
  public.gift_visible(uuid), public.gift_open(uuid), public.next_birthday(date,date) to authenticated;
grant execute on function public.ping() to anon, authenticated;
create index on public.gift_ideas(gift_id);
