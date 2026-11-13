create table public.meetups (
  id uuid primary key default gen_random_uuid(),
  title text not null check (length(trim(title)) between 1 and 80),
  description text not null default '' check (length(description) <= 3000),
  status text not null default 'planning' check (status in ('planning','confirmed','done','cancelled')),
  start_date date, end_date date,
  venue_id uuid,
  details text not null default '' check (length(details) <= 3000), -- address, check-in, door codes
  hidden_from uuid[] not null default '{}',
  created_by uuid not null default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  check (end_date is null or start_date is null or end_date >= start_date)
);
create table public.meetup_date_options (
  id uuid primary key default gen_random_uuid(),
  meetup_id uuid not null references public.meetups(id) on delete cascade,
  start_date date not null, end_date date not null check (end_date >= start_date),
  added_by uuid not null default auth.uid() references public.profiles(id) on delete set null,
  unique (meetup_id, start_date, end_date)
);
create table public.meetup_date_votes (
  option_id uuid not null references public.meetup_date_options(id) on delete cascade,
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  answer text not null check (answer in ('yes','maybe','no')),
  primary key (option_id, user_id)
);
create table public.meetup_venues (
  id uuid primary key default gen_random_uuid(),
  meetup_id uuid not null references public.meetups(id) on delete cascade,
  name text not null check (length(trim(name)) between 1 and 120),
  url text check (url is null or url ~ '^https?://'),
  total_price numeric(10,2) check (total_price is null or total_price >= 0),
  sleeps int check (sleeps is null or sleeps > 0),
  notes text not null default '' check (length(notes) <= 1000),
  added_by uuid not null default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
alter table public.meetups add constraint meetups_venue_fk foreign key (venue_id) references public.meetup_venues(id) on delete set null;
create table public.meetup_venue_votes (
  venue_id uuid not null references public.meetup_venues(id) on delete cascade,
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  primary key (venue_id, user_id)
);
create table public.meetup_rsvps (
  meetup_id uuid not null references public.meetups(id) on delete cascade,
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  status text not null check (status in ('going','maybe','not')),
  primary key (meetup_id, user_id)
);
create table public.meetup_items (
  id uuid primary key default gen_random_uuid(),
  meetup_id uuid not null references public.meetups(id) on delete cascade,
  label text not null check (length(trim(label)) between 1 and 120),
  claimed_by uuid references public.profiles(id) on delete set null,
  added_by uuid not null default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
create table public.meetup_photos (
  id uuid primary key default gen_random_uuid(),
  meetup_id uuid not null references public.meetups(id) on delete cascade,
  path text not null,
  caption text not null default '' check (length(caption) <= 200),
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  check (path ~ ('^meetups/[0-9]{4}/' || user_id || '/[0-9a-f-]{36}\.jpg$'))
);

create or replace function public.meetup_visible(p_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from meetups m where m.id = p_id and can_see(m.hidden_from));
$$;
create or replace function public.meetup_manager(p_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select is_admin() or exists (select 1 from meetups m where m.id = p_id and m.created_by = auth.uid());
$$;
grant execute on function public.meetup_visible(uuid), public.meetup_manager(uuid) to authenticated;

do $$
declare t text;
begin
  foreach t in array array['meetups','meetup_date_options','meetup_date_votes','meetup_venues','meetup_venue_votes','meetup_rsvps','meetup_items','meetup_photos'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
  end loop;
end $$;

-- meetups: everyone sees unless hidden from them; any member creates; creator/admin manage
create policy m_sel on public.meetups for select to authenticated using (can_see(hidden_from));
create policy m_ins on public.meetups for insert to authenticated with check (is_member() and created_by = auth.uid());
create policy m_upd on public.meetups for update to authenticated using (meetup_manager(id)) with check (meetup_manager(id));
create policy m_del on public.meetups for delete to authenticated using (meetup_manager(id));

-- children: visible with the meetup; anyone can add; you edit your own; managers can remove anything
create policy do_sel on public.meetup_date_options for select to authenticated using (meetup_visible(meetup_id));
create policy do_ins on public.meetup_date_options for insert to authenticated with check (meetup_visible(meetup_id) and added_by = auth.uid());
create policy do_del on public.meetup_date_options for delete to authenticated using (added_by = auth.uid() or meetup_manager(meetup_id));

create policy dv_sel on public.meetup_date_votes for select to authenticated
  using (exists (select 1 from meetup_date_options o where o.id = option_id and meetup_visible(o.meetup_id)));
create policy dv_ins on public.meetup_date_votes for insert to authenticated with check (user_id = auth.uid()
  and exists (select 1 from meetup_date_options o where o.id = option_id and meetup_visible(o.meetup_id)));
create policy dv_upd on public.meetup_date_votes for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy dv_del on public.meetup_date_votes for delete to authenticated using (user_id = auth.uid());

create policy v_sel on public.meetup_venues for select to authenticated using (meetup_visible(meetup_id));
create policy v_ins on public.meetup_venues for insert to authenticated with check (meetup_visible(meetup_id) and added_by = auth.uid());
create policy v_upd on public.meetup_venues for update to authenticated using (added_by = auth.uid() or meetup_manager(meetup_id));
create policy v_del on public.meetup_venues for delete to authenticated using (added_by = auth.uid() or meetup_manager(meetup_id));

create policy vv_sel on public.meetup_venue_votes for select to authenticated
  using (exists (select 1 from meetup_venues v where v.id = venue_id and meetup_visible(v.meetup_id)));
create policy vv_ins on public.meetup_venue_votes for insert to authenticated with check (user_id = auth.uid()
  and exists (select 1 from meetup_venues v where v.id = venue_id and meetup_visible(v.meetup_id)));
create policy vv_del on public.meetup_venue_votes for delete to authenticated using (user_id = auth.uid());

create policy r_sel on public.meetup_rsvps for select to authenticated using (meetup_visible(meetup_id));
create policy r_ins on public.meetup_rsvps for insert to authenticated with check (user_id = auth.uid() and meetup_visible(meetup_id));
create policy r_upd on public.meetup_rsvps for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy r_del on public.meetup_rsvps for delete to authenticated using (user_id = auth.uid());

create policy i_sel on public.meetup_items for select to authenticated using (meetup_visible(meetup_id));
create policy i_ins on public.meetup_items for insert to authenticated with check (meetup_visible(meetup_id) and added_by = auth.uid());
-- claim/unclaim: tightened in 20261113104001_v3b_claim_self_only.sql
create policy i_upd on public.meetup_items for update to authenticated using (meetup_visible(meetup_id)) with check (meetup_visible(meetup_id));
create policy i_del on public.meetup_items for delete to authenticated using (added_by = auth.uid() or meetup_manager(meetup_id));

create policy p_sel on public.meetup_photos for select to authenticated using (meetup_visible(meetup_id));
create policy p_ins on public.meetup_photos for insert to authenticated with check (user_id = auth.uid() and meetup_visible(meetup_id));
create policy p_del on public.meetup_photos for delete to authenticated using (user_id = auth.uid() or meetup_manager(meetup_id));

-- lock the columns people shouldn't rewrite
revoke update on public.meetups, public.meetup_items, public.meetup_venues from authenticated;
grant update (title, description, status, start_date, end_date, venue_id, details, hidden_from) on public.meetups to authenticated;
grant update (claimed_by) on public.meetup_items to authenticated;
grant update (name, url, total_price, sleeps, notes) on public.meetup_venues to authenticated;
revoke update on public.meetup_date_options, public.meetup_photos from authenticated;

create index on public.meetup_date_options(meetup_id);
create index on public.meetup_venues(meetup_id);
create index on public.meetup_items(meetup_id);
create index on public.meetup_photos(meetup_id);
