-- v13: army registry, game log (Elo is computed in the browser), painting log + pledges, hall of fame.

-- ---------- army registry ----------
create table public.collection_items (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  system text not null check (system in ('40k', 'aos')),
  faction text not null default '' check (length(faction) <= 60),
  unit_name text not null check (length(trim(unit_name)) between 1 and 120),
  models int not null default 1 check (models between 0 and 999),
  notes text not null default '' check (length(notes) <= 300),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index collection_unique on public.collection_items (user_id, system, lower(faction), lower(unit_name));
alter table public.collection_items enable row level security;
revoke all on public.collection_items from anon, authenticated;
grant select, insert, update, delete on public.collection_items to authenticated;
create policy ci_sel on public.collection_items for select to authenticated using (is_member());
create policy ci_ins on public.collection_items for insert to authenticated with check (user_id = auth.uid() and is_member());
create policy ci_upd on public.collection_items for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy ci_del on public.collection_items for delete to authenticated using (user_id = auth.uid());

-- Upload an army list: it REPLACES everything you have for that game + army.
-- p_items: [{"unit_name","models"}]. The same unit twice in one list (e.g. two squads of 20) is added together.
create or replace function public.collection_replace(p_system text, p_faction text, p_items jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare n int; f text := left(trim(coalesce(p_faction, '')), 60);
begin
  if not is_member() then raise exception 'Not allowed'; end if;
  if p_system not in ('40k', 'aos') then raise exception 'Pick a game'; end if;
  if f = '' then raise exception 'Say which army this list is for'; end if;
  delete from collection_items where user_id = auth.uid() and system = p_system and lower(faction) = lower(f);
  insert into collection_items (user_id, system, faction, unit_name, models)
  select auth.uid(), p_system, f, min(left(trim(x->>'unit_name'), 120)), least(999, sum(greatest(0, coalesce((x->>'models')::int, 1))))
  from jsonb_array_elements(coalesce(p_items, '[]')) x
  where length(trim(coalesce(x->>'unit_name', ''))) > 0
  group by lower(trim(x->>'unit_name'));
  get diagnostics n = row_count; return n;
end $$;

-- Remove a whole army from your collection.
create or replace function public.collection_drop(p_system text, p_faction text) returns void
language sql security definer set search_path = public as $$
  delete from collection_items where user_id = auth.uid() and system = p_system and lower(faction) = lower(trim(p_faction));
$$;

-- ---------- games ----------
create table public.games (
  id uuid primary key default gen_random_uuid(),
  played_on date not null default current_date,
  system text not null check (system in ('40k', 'aos')),
  points int check (points is null or points between 0 and 10000),
  mission text not null default '' check (length(mission) <= 120),
  meetup_id uuid references public.meetups(id) on delete set null,
  notes text not null default '' check (length(notes) <= 1000),
  photo_path text check (photo_path is null or photo_path ~ '^games/[0-9]{4}/[0-9a-f-]{36}/[0-9a-f-]{36}\.jpg$'),
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now()
);
create table public.game_players (
  game_id uuid not null references public.games(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  faction text not null default '' check (length(faction) <= 60),
  score int check (score is null or score between 0 and 999),
  result text not null check (result in ('win', 'loss', 'draw')),
  primary key (game_id, user_id)
);
create index on public.game_players(user_id);
alter table public.games enable row level security;
alter table public.game_players enable row level security;
revoke all on public.games, public.game_players from anon, authenticated;
grant select on public.games, public.game_players to authenticated;
create policy g_sel on public.games for select to authenticated using (is_member());
create policy gp_sel on public.game_players for select to authenticated using (is_member());

-- Save a 1v1 game. p_players: [{"user_id","faction","score"}, {...}] ; p_winner: a user_id, or null for a draw.
create or replace function public.game_save(p_id uuid, p_played_on date, p_system text, p_points int, p_mission text,
  p_players jsonb, p_winner uuid, p_meetup uuid default null, p_notes text default '', p_photo text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare gid uuid; a uuid := (p_players->0->>'user_id')::uuid; b uuid := (p_players->1->>'user_id')::uuid;
begin
  if not is_member() then raise exception 'Not allowed'; end if;
  if jsonb_array_length(coalesce(p_players, '[]')) <> 2 or a is null or b is null or a = b then raise exception 'Pick two different players'; end if;
  if (select count(*) from profiles where id in (a, b)) <> 2 then raise exception 'Unknown player'; end if;
  if p_winner is not null and p_winner not in (a, b) then raise exception 'The winner has to be one of the players'; end if;
  if p_meetup is not null and not meetup_visible(p_meetup) then raise exception 'Not allowed'; end if;
  if p_photo is not null and p_photo !~ ('^games/[0-9]{4}/' || auth.uid() || '/[0-9a-f-]{36}\.jpg$') then raise exception 'Bad photo path'; end if;
  if p_id is null then
    insert into games (played_on, system, points, mission, meetup_id, notes, photo_path, created_by)
    values (coalesce(p_played_on, current_date), p_system, p_points, coalesce(p_mission, ''), p_meetup, coalesce(p_notes, ''), p_photo, auth.uid())
    returning id into gid;
  else
    if not exists (select 1 from games where id = p_id and (created_by = auth.uid() or is_admin()
        or exists (select 1 from game_players where game_id = p_id and user_id = auth.uid()))) then
      raise exception 'Only the players or whoever logged it can change this game';
    end if;
    gid := p_id;
    update games set played_on = coalesce(p_played_on, played_on), system = p_system, points = p_points, mission = coalesce(p_mission, ''),
      meetup_id = p_meetup, notes = coalesce(p_notes, ''), photo_path = coalesce(p_photo, photo_path) where id = gid;
    delete from game_players where game_id = gid;
  end if;
  insert into game_players (game_id, user_id, faction, score, result)
  select gid, (x->>'user_id')::uuid, left(coalesce(x->>'faction', ''), 60), nullif(x->>'score', '')::int,
         case when p_winner is null then 'draw' when (x->>'user_id')::uuid = p_winner then 'win' else 'loss' end
  from jsonb_array_elements(p_players) x;
  return gid;
end $$;

create or replace function public.game_delete(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  delete from games where id = p_id and (created_by = auth.uid() or is_admin()
    or exists (select 1 from game_players where game_id = p_id and user_id = auth.uid()));
  if not found then raise exception 'Only the players or whoever logged it can delete this game'; end if;
end $$;

-- ---------- painting ----------
create table public.paint_log (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  painted_on date not null default current_date,
  models int not null check (models between 1 and 500),
  title text not null check (length(trim(title)) between 1 and 120),
  faction text not null default '' check (length(faction) <= 60),
  photo_path text check (photo_path is null or photo_path ~ ('^paint/[0-9]{4}/' || user_id || '/[0-9a-f-]{36}\.jpg$')),
  created_at timestamptz not null default now()
);
create table public.paint_pledges (
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  month date not null check (extract(day from month) = 1),
  target int not null check (target between 1 and 500),
  primary key (user_id, month)
);
do $$ declare t text; begin
  foreach t in array array['paint_log', 'paint_pledges'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
    execute format('create policy %I on public.%I for select to authenticated using (is_member())', t || '_sel', t);
    execute format('create policy %I on public.%I for insert to authenticated with check (user_id = auth.uid() and is_member())', t || '_ins', t);
    execute format('create policy %I on public.%I for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid())', t || '_upd', t);
    execute format('create policy %I on public.%I for delete to authenticated using (user_id = auth.uid())', t || '_del', t);
  end loop;
end $$;

-- ---------- hall of fame ----------
create table public.quotes (
  id uuid primary key default gen_random_uuid(),
  quote text not null check (length(trim(quote)) between 1 and 500),
  said_by uuid references public.profiles(id) on delete set null,
  context text not null default '' check (length(context) <= 200),
  meetup_id uuid references public.meetups(id) on delete set null,
  said_on date,
  added_by uuid not null default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
create table public.quote_laughs (
  quote_id uuid not null references public.quotes(id) on delete cascade,
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  primary key (quote_id, user_id)
);
create table public.meetup_awards (
  meetup_id uuid not null references public.meetups(id) on delete cascade,
  award text not null check (award in ('mvp', 'lucky', 'cursed', 'heretic', 'legend')),
  voter uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  nominee uuid not null references public.profiles(id) on delete cascade,
  primary key (meetup_id, award, voter),
  check (nominee <> voter)
);
do $$ declare t text; begin
  foreach t in array array['quotes', 'quote_laughs', 'meetup_awards'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select, insert, delete on public.%I to authenticated', t);
  end loop;
end $$;
grant update (nominee) on public.meetup_awards to authenticated;
create policy q_sel on public.quotes for select to authenticated using (is_member());
create policy q_ins on public.quotes for insert to authenticated with check (added_by = auth.uid() and is_member());
create policy q_del on public.quotes for delete to authenticated using (added_by = auth.uid() or is_admin());
create policy ql_sel on public.quote_laughs for select to authenticated using (is_member());
create policy ql_ins on public.quote_laughs for insert to authenticated with check (user_id = auth.uid() and is_member());
create policy ql_del on public.quote_laughs for delete to authenticated using (user_id = auth.uid());
create policy ma_sel on public.meetup_awards for select to authenticated using (meetup_visible(meetup_id));
create policy ma_ins on public.meetup_awards for insert to authenticated with check (voter = auth.uid() and meetup_visible(meetup_id));
create policy ma_upd on public.meetup_awards for update to authenticated using (voter = auth.uid()) with check (voter = auth.uid());
create policy ma_del on public.meetup_awards for delete to authenticated using (voter = auth.uid());

-- ---------- photos: allow game and painting photos ----------
drop policy if exists "members upload own photos" on storage.objects;
create policy "members upload own photos" on storage.objects for insert to authenticated
  with check (bucket_id = 'models' and public.is_member()
    and name ~ ('^(santa|meetups|gifts|games|paint)/[0-9]{4}/' || auth.uid() || '/[0-9a-f-]{36}\.jpg$'));

-- ---------- gallery: add game and painting photos ----------
create or replace function public.gallery_all()
returns table(kind text, year int, title text, subtitle text, photo_path text, link text, taken_at timestamptz)
language sql stable security definer set search_path = public as $$
  select 'santa', a.year, coalesce(a.model_name, 'Secret Santa model'), g.display_name || ' → ' || r.display_name,
         a.photo_path, '#santa', coalesce(a.completed_at, d.drawn_at)
  from ss_assignments a join ss_draws d on d.year = a.year and d.revealed
  join profiles g on g.id = a.giver_id join profiles r on r.id = a.receiver_id
  where is_member() and a.photo_path is not null
  union all
  select 'meetup', extract(year from coalesce(m.start_date, p.created_at::date))::int, coalesce(nullif(p.caption, ''), m.title),
         m.title || ' · ' || u.display_name, p.path, '#meetup/' || m.id, p.created_at
  from meetup_photos p join meetups m on m.id = p.meetup_id join profiles u on u.id = p.user_id
  where can_see(m.hidden_from)
  union all
  select 'gift', extract(year from g.birthday_on)::int, coalesce(g.gift_title, 'Birthday present'), 'for ' || r.display_name,
         g.photo_path, '#gift/' || g.id, g.birthday_on::timestamptz
  from gifts g join profiles r on r.id = g.recipient_id
  where g.status = 'given' and g.photo_path is not null and can_see(g.hidden_from)
  union all
  select 'paint', extract(year from pl.painted_on)::int, pl.title, u.display_name || ' · ' || pl.models || ' model' || case when pl.models = 1 then '' else 's' end,
         pl.photo_path, '#painting', pl.created_at
  from paint_log pl join profiles u on u.id = pl.user_id
  where is_member() and pl.photo_path is not null
  union all
  select 'game', extract(year from ga.played_on)::int,
         (select string_agg(p.display_name || case when gp.score is not null then ' ' || gp.score else '' end, ' vs ' order by gp.result desc, p.display_name) from game_players gp join profiles p on p.id = gp.user_id where gp.game_id = ga.id),
         case ga.system when '40k' then 'Warhammer 40K' else 'Age of Sigmar' end || case when ga.mission <> '' then ' · ' || ga.mission else '' end,
         ga.photo_path, '#games', ga.played_on::timestamptz
  from games ga where is_member() and ga.photo_path is not null
  order by 7 desc;
$$;

revoke execute on function public.collection_replace(text, text, jsonb), public.collection_drop(text, text), public.game_save(uuid, date, text, int, text, jsonb, uuid, uuid, text, text), public.game_delete(uuid) from public, anon;
grant execute on function public.collection_replace(text, text, jsonb), public.collection_drop(text, text), public.game_save(uuid, date, text, int, text, jsonb, uuid, uuid, text, text), public.game_delete(uuid) to authenticated;
