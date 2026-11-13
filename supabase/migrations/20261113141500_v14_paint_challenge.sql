-- v14: the monthly painting challenge. The theme-setter rotates alphabetically; everyone is in unless they opted out
-- before the month began; uploading a photo before the end of the month (UK time) counts as done; anyone who
-- doesn't finish owes the group a round at the next meetup. Replaces the "pledges" from v13.
drop table if exists public.paint_pledges;

create table public.paint_challenges (
  month date primary key check (extract(day from month) = 1),
  setter uuid references public.profiles(id) on delete set null,
  theme text check (theme is null or length(trim(theme)) between 1 and 120),
  theme_set_at timestamptz,
  nagged boolean not null default false,      -- setter reminded to pick
  reminded boolean not null default false,    -- 5-day warning sent
  results_sent boolean not null default false
);
create table public.paint_challenge_entries (
  month date not null references public.paint_challenges(month) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  unit text not null default '' check (length(unit) <= 120),
  opted_out boolean not null default false,
  photo_path text check (photo_path is null or photo_path ~ ('^paint/[0-9]{4}/' || user_id || '/[0-9a-f-]{36}\.jpg$')),
  finished_at timestamptz,
  round_bought_at timestamptz,
  primary key (month, user_id)
);
do $$ declare t text; begin
  foreach t in array array['paint_challenges', 'paint_challenge_entries'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('create policy %I on public.%I for select to authenticated using (is_member())', t || '_sel', t);
  end loop;
end $$;

create or replace function public._london_today() returns date language sql stable as $$ select (now() at time zone 'Europe/London')::date $$;

-- Next person in alphabetical order after p_prev (wrapping round).
create or replace function public._next_setter(p_prev uuid) returns uuid
language sql stable security definer set search_path = public as $$
  with m as (select id, row_number() over (order by lower(display_name), id) rn, count(*) over () n from profiles),
       prev as (select rn from m where id = p_prev)
  select id from m where rn = coalesce((select rn from prev) % (select max(n) from m) + 1, 1);
$$;

-- Make sure a month exists, with the next setter in the rotation.
create or replace function public._challenge_ensure(p_month date) returns void
language plpgsql security definer set search_path = public as $$
declare prev uuid;
begin
  if exists (select 1 from paint_challenges where month = p_month) then return; end if;
  select setter into prev from paint_challenges where month < p_month order by month desc limit 1;
  insert into paint_challenges(month, setter) values (p_month, _next_setter(prev)) on conflict do nothing;
end $$;

-- Daily (Worker cron via ping) and on page load: create months, nag, remind, announce results.
create or replace function public.paint_challenge_tick() returns void
language plpgsql security definer set search_path = public as $$
declare today date := _london_today(); cur date := date_trunc('month', _london_today())::date; nxt date; c paint_challenges; losers uuid[];
begin
  nxt := (cur + interval '1 month')::date;
  perform _challenge_ensure(cur);
  if today >= nxt - 7 then perform _challenge_ensure(nxt); end if;   -- next month opens a week early so people can opt out / the setter can pick

  select * into c from paint_challenges where month = cur;
  if c.theme is null and not c.nagged and c.setter is not null then
    perform queue_email('challenge_pick', array[c.setter], 'Your turn: pick the ' || to_char(cur, 'FMMonth') || ' painting challenge',
      'It''s your turn to choose what everyone paints this month: a character, a vehicle, a tag, anything. Set it on the Painting page.', '#painting');
    update paint_challenges set nagged = true where month = cur;
  end if;
  if c.theme is not null and not c.reminded and today >= nxt - 5 then
    select array_agg(p.id) into losers from profiles p
      where not exists (select 1 from paint_challenge_entries e where e.month = cur and e.user_id = p.id and (e.opted_out or e.finished_at is not null));
    perform queue_email('challenge_remind', coalesce(losers, '{}'), (nxt - today) || ' days left: ' || c.theme,
      'The ' || to_char(cur, 'FMMonth') || ' challenge is "' || c.theme || '". Upload a photo of your finished unit before midnight on ' ||
      to_char(nxt - 1, 'FMDay FMDD FMMonth') || ', or you''re buying a round at the next meetup.', '#painting');
    update paint_challenges set reminded = true where month = cur;
  end if;

  -- results for any finished month not yet announced
  for c in select * from paint_challenges where month < cur and not results_sent and theme is not null loop
    select array_agg(p.display_name order by p.display_name) into losers from profiles p
      where not exists (select 1 from paint_challenge_entries e where e.month = c.month and e.user_id = p.id and (e.opted_out or e.finished_at is not null));
    perform queue_email('challenge_results', _everyone_except('{}'), to_char(c.month, 'FMMonth') || ' challenge results',
      case when coalesce(array_length(losers, 1), 0) = 0 then 'Everyone finished "' || c.theme || '". No rounds owed this time.'
           else 'Theme: "' || c.theme || '". Buying a round at the next meetup: ' || array_to_string(losers, ', ') || '.' end, '#painting');
    update paint_challenges set results_sent = true where month = c.month;
  end loop;
end $$;

create or replace function public.challenge_set_theme(p_month date, p_theme text) returns void
language plpgsql security definer set search_path = public as $$
declare c paint_challenges;
begin
  select * into c from paint_challenges where month = p_month;
  if not found then raise exception 'No challenge for that month yet'; end if;
  if c.setter is distinct from auth.uid() and not is_admin() then raise exception 'It''s %''s turn to pick', _name(c.setter); end if;
  if p_month < date_trunc('month', _london_today())::date then raise exception 'That month is over'; end if;
  if nullif(trim(p_theme), '') is null then raise exception 'Enter a theme'; end if;
  update paint_challenges set theme = left(trim(p_theme), 120), theme_set_at = now() where month = p_month;
  if c.theme is null then
    perform queue_email('challenge_theme', _everyone_except(array[auth.uid()]), to_char(p_month, 'FMMonth') || ' painting challenge: ' || trim(p_theme),
      _name(auth.uid()) || ' has picked the ' || to_char(p_month, 'FMMonth') || ' challenge: "' || trim(p_theme) || '". Upload a photo of your finished unit by the end of the month or buy a round.', '#painting');
  end if;
end $$;

-- Admin: give the turn to someone else (e.g. the setter is away).
create or replace function public.challenge_set_setter(p_month date, p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admins only'; end if;
  update paint_challenges set setter = p_user, nagged = false where month = p_month and theme is null;
  if not found then raise exception 'The theme is already set'; end if;
end $$;

-- Say what you're painting.
create or replace function public.challenge_declare(p_month date, p_unit text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_member() or not exists (select 1 from paint_challenges where month = p_month) then raise exception 'Not allowed'; end if;
  insert into paint_challenge_entries(month, user_id, unit) values (p_month, auth.uid(), left(coalesce(p_unit, ''), 120))
  on conflict (month, user_id) do update set unit = excluded.unit;
end $$;

-- Opting out only for a month that hasn't started.
create or replace function public.challenge_opt_out(p_month date, p_out boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_member() or not exists (select 1 from paint_challenges where month = p_month) then raise exception 'Not allowed'; end if;
  if p_month <= date_trunc('month', _london_today())::date then raise exception 'Too late: once the month has started, you''re in'; end if;
  insert into paint_challenge_entries(month, user_id, opted_out) values (p_month, auth.uid(), p_out)
  on conflict (month, user_id) do update set opted_out = excluded.opted_out;
end $$;

-- Finished! Photo required, before midnight UK time on the last day. Also logs it in the painting log.
create or replace function public.challenge_finish(p_month date, p_unit text, p_photo text, p_models int default 1) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_member() or not exists (select 1 from paint_challenges where month = p_month and theme is not null) then raise exception 'There''s no theme for that month yet'; end if;
  if _london_today() >= (p_month + interval '1 month')::date then raise exception 'Too late: the deadline was midnight on the last day of the month'; end if;
  if p_month > date_trunc('month', _london_today())::date then raise exception 'That month hasn''t started yet'; end if;
  if p_photo is null or p_photo !~ ('^paint/[0-9]{4}/' || auth.uid() || '/[0-9a-f-]{36}\.jpg$') then raise exception 'Add a photo of the finished unit'; end if;
  insert into paint_challenge_entries(month, user_id, unit, photo_path, finished_at, opted_out)
    values (p_month, auth.uid(), left(coalesce(p_unit, ''), 120), p_photo, now(), false)
  on conflict (month, user_id) do update set unit = coalesce(nullif(excluded.unit, ''), paint_challenge_entries.unit), photo_path = excluded.photo_path,
    finished_at = coalesce(paint_challenge_entries.finished_at, now()), opted_out = false;
  insert into paint_log(user_id, models, title, photo_path)
    values (auth.uid(), greatest(1, least(500, coalesce(p_models, 1))), coalesce(nullif(trim(p_unit), ''), 'Painting challenge') || ' (' || to_char(p_month, 'FMMonth') || ' challenge)', p_photo);
end $$;

-- Mark a round as bought (anyone can: it happened in front of everyone).
create or replace function public.challenge_round_bought(p_month date, p_user uuid, p_bought boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_member() then raise exception 'Not allowed'; end if;
  if p_month >= date_trunc('month', _london_today())::date then raise exception 'That month isn''t over yet'; end if;
  insert into paint_challenge_entries(month, user_id, round_bought_at) values (p_month, p_user, case when p_bought then now() end)
  on conflict (month, user_id) do update set round_bought_at = case when p_bought then now() end;
end $$;

create or replace function public.ping() returns text language plpgsql security definer set search_path = public as $$
begin perform open_gift_plans(); perform paint_challenge_tick(); return 'ok'; end $$;

revoke execute on function public._london_today(), public._next_setter(uuid), public._challenge_ensure(date) from public, anon, authenticated;
revoke execute on function public.paint_challenge_tick(), public.challenge_set_theme(date, text), public.challenge_set_setter(date, uuid), public.challenge_declare(date, text),
  public.challenge_opt_out(date, boolean), public.challenge_finish(date, text, text, int), public.challenge_round_bought(date, uuid, boolean) from public, anon;
grant execute on function public.paint_challenge_tick(), public.challenge_set_theme(date, text), public.challenge_set_setter(date, uuid), public.challenge_declare(date, text),
  public.challenge_opt_out(date, boolean), public.challenge_finish(date, text, text, int), public.challenge_round_bought(date, uuid, boolean) to authenticated;

select public.paint_challenge_tick();
