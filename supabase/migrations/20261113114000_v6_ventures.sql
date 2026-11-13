-- Ventures: idea -> proposal -> chartering -> active -> closed (or declined).
-- Ideas/proposals are visible to every member. From chartering on, only the venture's members see inside.
create table public.ventures (
  id uuid primary key default gen_random_uuid(),
  stage text not null default 'idea' check (stage in ('idea','proposal','declined','chartering','active','closed')),
  title text not null check (length(trim(title)) between 1 and 100),
  summary text not null default '' check (length(summary) <= 1000),
  problem text not null default '' check (length(problem) <= 3000),
  idea text not null default '' check (length(idea) <= 3000),
  audience text not null default '' check (length(audience) <= 1000),
  time_needed text not null default '' check (length(time_needed) <= 500),
  money_needed text not null default '' check (length(money_needed) <= 500),
  skills text not null default '' check (length(skills) <= 1000),
  first_milestone text not null default '' check (length(first_milestone) <= 1000),
  success text not null default '' check (length(success) <= 1000),
  risks text not null default '' check (length(risks) <= 2000),
  decide_by date,
  health text not null default 'on_track' check (health in ('on_track','at_risk','off_track')),
  status_note text not null default '' check (length(status_note) <= 1000),
  next_milestone text not null default '' check (length(next_milestone) <= 500),
  outcome text check (outcome in ('shipped','sold','shelved','merged')),
  learned text not null default '' check (length(learned) <= 3000),
  created_by uuid not null default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  launched_at timestamptz, closed_at timestamptz
);
create table public.venture_members (
  venture_id uuid not null references public.ventures(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role text not null default 'member' check (role in ('lead','member')),
  share_pct numeric(5,2) not null default 0 check (share_pct between 0 and 100),
  joined_at timestamptz not null default now(),
  primary key (venture_id, user_id)
);
create table public.venture_responses (
  venture_id uuid not null references public.ventures(id) on delete cascade,
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  response text not null check (response in ('in','support','concern')),
  note text not null default '' check (length(note) <= 1000),
  updated_at timestamptz not null default now(),
  primary key (venture_id, user_id)
);
create table public.venture_comments (
  id uuid primary key default gen_random_uuid(),
  venture_id uuid not null references public.ventures(id) on delete cascade,
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  body text not null check (length(trim(body)) between 1 and 3000),
  created_at timestamptz not null default now()
);
create table public.venture_charters (
  venture_id uuid primary key references public.ventures(id) on delete cascade,
  version int not null default 1,
  time_commitment text not null default '' check (length(time_commitment) <= 1000),
  money_commitment text not null default '' check (length(money_commitment) <= 1000),
  decision_rule text not null default 'Big decisions (spending over £100, pivots, new members) need everyone to agree. Day-to-day calls are the lead''s.' check (length(decision_rule) <= 1000),
  leaving_rule text not null default 'Anyone can leave with a month''s notice. Money put in is repaid from future profit before shares are split; their share returns to the remaining members.' check (length(leaving_rule) <= 1000),
  ip_rule text not null default 'Everything made for the venture (code, designs, brand) belongs to the venture, split by share.' check (length(ip_rule) <= 1000),
  wind_up_rule text not null default 'If we wind it up, sell what can be sold, repay money put in first, then split anything left by share.' check (length(wind_up_rule) <= 1000),
  updated_at timestamptz not null default now()
);
create table public.venture_charter_agreements (
  venture_id uuid not null references public.ventures(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  version int not null,
  agreed_at timestamptz not null default now(),
  primary key (venture_id, user_id)
);
create table public.venture_features (
  id uuid primary key default gen_random_uuid(),
  venture_id uuid not null references public.ventures(id) on delete cascade,
  title text not null check (length(trim(title)) between 1 and 160),
  detail text not null default '' check (length(detail) <= 3000),
  status text not null default 'idea' check (status in ('idea','planned','building','shipped')),
  priority int not null default 2 check (priority between 1 and 3),
  owner_id uuid references public.profiles(id) on delete set null,
  created_by uuid not null default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
create table public.venture_tasks (
  id uuid primary key default gen_random_uuid(),
  venture_id uuid not null references public.ventures(id) on delete cascade,
  title text not null check (length(trim(title)) between 1 and 200),
  status text not null default 'todo' check (status in ('todo','doing','done')),
  owner_id uuid references public.profiles(id) on delete set null,
  due_on date,
  feature_id uuid references public.venture_features(id) on delete set null,
  created_by uuid not null default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
create table public.venture_decisions (
  id uuid primary key default gen_random_uuid(),
  venture_id uuid not null references public.ventures(id) on delete cascade,
  decided_on date not null default current_date,
  title text not null check (length(trim(title)) between 1 and 200),
  detail text not null default '' check (length(detail) <= 3000),
  created_by uuid not null default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
-- Real money. contribution = a member puts money in; expense = spent for the venture (by member_id, or from the pot if null);
-- revenue = money earned (received by member_id, or into the pot if null); payout = paid out to member_id from the pot.
create table public.venture_money (
  id uuid primary key default gen_random_uuid(),
  venture_id uuid not null references public.ventures(id) on delete cascade,
  kind text not null check (kind in ('contribution','expense','revenue','payout')),
  amount numeric(12,2) not null check (amount > 0),
  member_id uuid references public.profiles(id) on delete set null,
  occurred_on date not null default current_date,
  note text not null default '' check (length(note) <= 500),
  created_by uuid not null default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  check (kind in ('expense','revenue') or member_id is not null)
);
create table public.venture_updates (
  id uuid primary key default gen_random_uuid(),
  venture_id uuid not null references public.ventures(id) on delete cascade,
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  did text not null default '' check (length(did) <= 2000),
  next text not null default '' check (length(next) <= 2000),
  blockers text not null default '' check (length(blockers) <= 2000),
  created_by uuid not null default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
create table public.venture_links (
  id uuid primary key default gen_random_uuid(),
  venture_id uuid not null references public.ventures(id) on delete cascade,
  label text not null check (length(trim(label)) between 1 and 120),
  url text not null check (url ~ '^https?://'),
  created_by uuid not null default auth.uid() references public.profiles(id) on delete set null,
  created_at timestamptz not null default now()
);

create or replace function public.is_venture_member(p_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from venture_members where venture_id = p_id and user_id = auth.uid());
$$;
-- open (idea/proposal/declined): every member sees; otherwise only the venture's members
create or replace function public.venture_visible(p_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select is_member() and exists (select 1 from ventures v where v.id = p_id
    and (v.stage in ('idea','proposal','declined') or is_venture_member(v.id)));
$$;
create or replace function public.venture_workspace(p_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select is_venture_member(p_id) and exists (select 1 from ventures where id = p_id and stage in ('chartering','active','closed'));
$$;

do $$ declare t text; begin
  foreach t in array array['ventures','venture_members','venture_responses','venture_comments','venture_charters','venture_charter_agreements',
                           'venture_features','venture_tasks','venture_decisions','venture_money','venture_updates','venture_links'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
  end loop;
end $$;

-- ventures
create policy v_sel on public.ventures for select to authenticated using (venture_visible(id));
create policy v_ins on public.ventures for insert to authenticated with check (is_member() and created_by = auth.uid() and stage in ('idea','proposal'));
create policy v_upd on public.ventures for update to authenticated
  using ((stage in ('idea','proposal') and (created_by = auth.uid() or is_admin())) or (stage in ('chartering','active') and is_venture_member(id)))
  with check ((stage in ('idea','proposal') and (created_by = auth.uid() or is_admin())) or (stage in ('chartering','active') and is_venture_member(id)));
create policy v_del on public.ventures for delete to authenticated using ((stage in ('idea','proposal','declined') and created_by = auth.uid()) or is_admin());
grant insert on public.ventures to authenticated;
grant update (title, summary, problem, idea, audience, time_needed, money_needed, skills, first_milestone, success, risks, decide_by,
  health, status_note, next_milestone) on public.ventures to authenticated;
grant delete on public.ventures to authenticated;

create policy vm_sel on public.venture_members for select to authenticated using (venture_visible(venture_id));

-- responses (only while a proposal is open)
create policy vr_sel on public.venture_responses for select to authenticated using (venture_visible(venture_id));
create policy vr_ins on public.venture_responses for insert to authenticated with check (user_id = auth.uid()
  and exists (select 1 from ventures v where v.id = venture_id and v.stage = 'proposal'));
create policy vr_upd on public.venture_responses for update to authenticated using (user_id = auth.uid()
  and exists (select 1 from ventures v where v.id = venture_id and v.stage = 'proposal')) with check (user_id = auth.uid());
create policy vr_del on public.venture_responses for delete to authenticated using (user_id = auth.uid()
  and exists (select 1 from ventures v where v.id = venture_id and v.stage = 'proposal'));
grant insert, update, delete on public.venture_responses to authenticated;

-- comments follow venture visibility
create policy vc_sel on public.venture_comments for select to authenticated using (venture_visible(venture_id));
create policy vc_ins on public.venture_comments for insert to authenticated with check (user_id = auth.uid() and venture_visible(venture_id));
create policy vc_del on public.venture_comments for delete to authenticated using (user_id = auth.uid());
grant insert, delete on public.venture_comments to authenticated;

-- charter + agreements: members only; edits go through venture_save_charter() so the version bumps
create policy ch_sel on public.venture_charters for select to authenticated using (venture_workspace(venture_id));
create policy ca_sel on public.venture_charter_agreements for select to authenticated using (venture_workspace(venture_id));

-- workspace tables: members of the venture do everything
do $$ declare t text; begin
  foreach t in array array['venture_features','venture_tasks','venture_decisions','venture_money','venture_updates','venture_links'] loop
    execute format('create policy ws_sel on public.%I for select to authenticated using (venture_workspace(venture_id))', t);
    execute format('create policy ws_ins on public.%I for insert to authenticated with check (venture_workspace(venture_id) and created_by = auth.uid())', t);
    execute format('create policy ws_upd on public.%I for update to authenticated using (venture_workspace(venture_id)) with check (venture_workspace(venture_id))', t);
    execute format('create policy ws_del on public.%I for delete to authenticated using (venture_workspace(venture_id))', t);
    execute format('grant insert, update, delete on public.%I to authenticated', t);
  end loop;
end $$;
-- weekly updates: you post and edit only your own
drop policy ws_ins on public.venture_updates;
create policy ws_ins on public.venture_updates for insert to authenticated with check (venture_workspace(venture_id) and user_id = auth.uid() and created_by = auth.uid());
drop policy ws_upd on public.venture_updates;
create policy ws_upd on public.venture_updates for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy ws_del on public.venture_updates;
create policy ws_del on public.venture_updates for delete to authenticated using (user_id = auth.uid());
-- money: anyone in the venture records; only who recorded it (or admin) can change/delete it
drop policy ws_upd on public.venture_money;
create policy ws_upd on public.venture_money for update to authenticated using (venture_workspace(venture_id) and (created_by = auth.uid() or is_admin())) with check (venture_workspace(venture_id));
drop policy ws_del on public.venture_money;
create policy ws_del on public.venture_money for delete to authenticated using (venture_workspace(venture_id) and (created_by = auth.uid() or is_admin()));

-- ---------- functions ----------
-- What everyone may know about every venture, including private ones: name, stage, members.
create or replace function public.ventures_directory()
returns table(id uuid, title text, stage text, summary text, created_by uuid, created_at timestamptz, decide_by date,
              members text[], ins int, supports int, concerns int, my_response text, i_am_member boolean)
language sql stable security definer set search_path = public as $$
  select v.id, v.title, v.stage,
         case when v.stage in ('idea','proposal','declined') or is_venture_member(v.id) then v.summary else '' end,
         v.created_by, v.created_at, v.decide_by,
         coalesce((select array_agg(p.display_name order by vm.role, p.display_name) from venture_members vm join profiles p on p.id = vm.user_id where vm.venture_id = v.id), '{}'),
         (select count(*)::int from venture_responses r where r.venture_id = v.id and r.response = 'in'),
         (select count(*)::int from venture_responses r where r.venture_id = v.id and r.response = 'support'),
         (select count(*)::int from venture_responses r where r.venture_id = v.id and r.response = 'concern'),
         (select r.response from venture_responses r where r.venture_id = v.id and r.user_id = auth.uid()),
         is_venture_member(v.id)
  from ventures v where is_member() order by v.created_at desc;
$$;

-- idea <-> proposal, or decline/withdraw (proposer or admin)
create or replace function public.venture_set_stage(p_id uuid, p_stage text) returns void
language plpgsql security definer set search_path = public as $$
declare v ventures;
begin
  select * into v from ventures where id = p_id;
  if v.id is null or not (v.created_by = auth.uid() or is_admin()) then raise exception 'Only the proposer can do this'; end if;
  if v.stage not in ('idea','proposal','declined') or p_stage not in ('idea','proposal','declined') then raise exception 'Not allowed at this stage'; end if;
  update ventures set stage = p_stage where id = p_id;
end $$;

-- Launch: needs 2+ "I'm in". The people who are in become the members, with equal shares to start.
create or replace function public.venture_launch(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare n int; lead uuid;
begin
  if not exists (select 1 from ventures where id = p_id and stage = 'proposal') then raise exception 'Only an open proposal can launch'; end if;
  if not exists (select 1 from venture_responses where venture_id = p_id and user_id = auth.uid() and response = 'in') then
    raise exception 'Only someone who is in can launch it'; end if;
  select count(*) into n from venture_responses where venture_id = p_id and response = 'in';
  if n < 2 then raise exception 'Needs at least 2 people in (has %)', n; end if;
  select case when exists (select 1 from venture_responses r join ventures v on v.id = r.venture_id where r.venture_id = p_id and r.user_id = v.created_by and r.response = 'in')
              then (select created_by from ventures where id = p_id) else auth.uid() end into lead;
  insert into venture_members(venture_id, user_id, role, share_pct)
    select p_id, user_id, case when user_id = lead then 'lead' else 'member' end, round(100.0 / n, 2)
    from venture_responses where venture_id = p_id and response = 'in';
  insert into venture_charters(venture_id) values (p_id);
  update ventures set stage = 'chartering', launched_at = now() where id = p_id;
end $$;

-- Any charter change bumps the version, so everyone has to agree again.
create or replace function public.venture_save_charter(p_id uuid, p_time text, p_money text, p_decision text, p_leaving text, p_ip text, p_windup text, p_shares jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare total numeric;
begin
  if not venture_workspace(p_id) or not exists (select 1 from ventures where id = p_id and stage in ('chartering','active')) then raise exception 'Members only'; end if;
  if p_shares is not null then
    select sum((value)::numeric) into total from jsonb_each_text(p_shares);
    if abs(total - 100) > 0.05 then raise exception 'Shares must add up to 100%% (they add up to %)', total; end if;
    update venture_members m set share_pct = (p_shares->>m.user_id::text)::numeric
     where m.venture_id = p_id and p_shares ? m.user_id::text;
  end if;
  update venture_charters set time_commitment = left(p_time, 1000), money_commitment = left(p_money, 1000), decision_rule = left(p_decision, 1000),
    leaving_rule = left(p_leaving, 1000), ip_rule = left(p_ip, 1000), wind_up_rule = left(p_windup, 1000), version = version + 1, updated_at = now()
   where venture_id = p_id;
end $$;

-- Agree to the current version. When every member has agreed, a chartering venture goes active.
create or replace function public.venture_agree_charter(p_id uuid) returns text
language plpgsql security definer set search_path = public as $$
declare ver int;
begin
  if not venture_workspace(p_id) then raise exception 'Members only'; end if;
  select version into ver from venture_charters where venture_id = p_id;
  insert into venture_charter_agreements(venture_id, user_id, version) values (p_id, auth.uid(), ver)
    on conflict (venture_id, user_id) do update set version = excluded.version, agreed_at = now();
  if not exists (select 1 from venture_members m where m.venture_id = p_id and not exists
      (select 1 from venture_charter_agreements a where a.venture_id = p_id and a.user_id = m.user_id and a.version = ver)) then
    update ventures set stage = 'active' where id = p_id and stage = 'chartering';
  end if;
  return (select stage from ventures where id = p_id);
end $$;

-- Add someone later (any member can). Their share starts at 0 and the charter version bumps.
create or replace function public.venture_add_member(p_id uuid, p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not venture_workspace(p_id) then raise exception 'Members only'; end if;
  if not exists (select 1 from profiles where id = p_user) then raise exception 'Unknown member'; end if;
  insert into venture_members(venture_id, user_id, role, share_pct) values (p_id, p_user, 'member', 0) on conflict do nothing;
  update venture_charters set version = version + 1, updated_at = now() where venture_id = p_id;
end $$;

create or replace function public.venture_leave(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not venture_workspace(p_id) then raise exception 'Members only'; end if;
  if (select count(*) from venture_members where venture_id = p_id) <= 1 then raise exception 'You are the last member: close the venture instead'; end if;
  delete from venture_members where venture_id = p_id and user_id = auth.uid();
  update venture_charters set version = version + 1, updated_at = now() where venture_id = p_id;
end $$;

create or replace function public.venture_close(p_id uuid, p_outcome text, p_learned text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not venture_workspace(p_id) then raise exception 'Members only'; end if;
  update ventures set stage = 'closed', outcome = p_outcome, learned = left(coalesce(p_learned, ''), 3000), closed_at = now()
   where id = p_id and stage in ('chartering','active');
end $$;

revoke execute on function public.is_venture_member(uuid), public.venture_visible(uuid), public.venture_workspace(uuid), public.ventures_directory(),
  public.venture_set_stage(uuid,text), public.venture_launch(uuid), public.venture_save_charter(uuid,text,text,text,text,text,text,jsonb),
  public.venture_agree_charter(uuid), public.venture_add_member(uuid,uuid), public.venture_leave(uuid), public.venture_close(uuid,text,text) from public, anon;
grant execute on function public.is_venture_member(uuid), public.venture_visible(uuid), public.venture_workspace(uuid), public.ventures_directory(),
  public.venture_set_stage(uuid,text), public.venture_launch(uuid), public.venture_save_charter(uuid,text,text,text,text,text,text,jsonb),
  public.venture_agree_charter(uuid), public.venture_add_member(uuid,uuid), public.venture_leave(uuid), public.venture_close(uuid,text,text) to authenticated;

create index on public.venture_tasks(venture_id);
create index on public.venture_features(venture_id);
create index on public.venture_money(venture_id);
create index on public.venture_comments(venture_id);
