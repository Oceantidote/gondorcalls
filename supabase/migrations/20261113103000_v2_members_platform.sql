-- v1 had no real data (verified empty); replace it.
drop function if exists public.join_exchange(text,text), public.list_participants(), public.list_draws(), public.get_me(uuid),
  public.update_notes(uuid,text), public.submit_model(uuid,int,text,text), public.gallery(), public.admin_overview(text),
  public.admin_set_active(text,uuid,boolean), public.admin_reset_link(text,uuid), public.admin_set_revealed(text,int,boolean),
  public.admin_delete_draw(text,int), public.admin_run_draw(text,int), public._draw_report(int), public._check_admin(text), public._me(uuid);
drop table if exists public.assignments, public.draws, public.participants, public.settings cascade;
drop policy if exists "anyone can upload model photos" on storage.objects;

-- ---------- members ----------
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null unique check (length(trim(display_name)) between 1 and 40),
  birthday date,
  armies text not null default '' check (length(armies) <= 500),
  wishlist text not null default '' check (length(wishlist) <= 2000),
  is_admin boolean not null default false,
  santa_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.invites (
  token uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('join','reset')),
  display_name text,
  user_id uuid references public.profiles(id) on delete cascade,
  make_admin boolean not null default false,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '14 days',
  claimed_email text,
  used_at timestamptz
);

-- site pages served by the Cloudflare Worker
create table public.site_files (
  path text primary key,
  body text not null,
  updated_at timestamptz not null default now()
);

alter table public.profiles enable row level security;
alter table public.invites enable row level security;
alter table public.site_files enable row level security;

create or replace function public.is_member() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid());
$$;
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin from profiles where id = auth.uid()), false);
$$;
-- The "hidden from" rule used by birthdays and surprises: members can see a row
-- unless their id is in its hidden_from list.
create or replace function public.can_see(hidden_from uuid[]) returns boolean
language sql stable security definer set search_path = public as $$
  select is_member() and not (auth.uid() = any(coalesce(hidden_from, '{}')));
$$;

create policy "members read profiles" on public.profiles for select to authenticated using (is_member());
create policy "members edit own profile" on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());
revoke all on public.profiles from anon, authenticated;
grant select on public.profiles to authenticated;
grant update (display_name, birthday, armies, wishlist) on public.profiles to authenticated;
revoke all on public.invites, public.site_files from anon, authenticated;

-- Only invited emails can become users. The invite edge function writes
-- claimed_email just before creating the account.
create or replace function public.gate_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare inv invites;
begin
  select * into inv from invites
   where token = (new.raw_user_meta_data->>'invite')::uuid
     and kind = 'join' and used_at is null and expires_at > now()
     and lower(claimed_email) = lower(new.email);
  if not found then raise exception 'Sign-up is by invitation only'; end if;
  return new;
end $$;
create trigger gate_new_user before insert on auth.users for each row execute function public.gate_new_user();

create or replace function public.create_profile() returns trigger
language plpgsql security definer set search_path = public as $$
declare inv invites;
begin
  select * into inv from invites where token = (new.raw_user_meta_data->>'invite')::uuid;
  insert into profiles(id, display_name, is_admin)
    values (new.id, coalesce(nullif(trim(new.raw_user_meta_data->>'display_name'), ''), inv.display_name, split_part(new.email, '@', 1)), inv.make_admin);
  update invites set used_at = now() where token = inv.token;
  return new;
end $$;
create trigger create_profile after insert on auth.users for each row execute function public.create_profile();

-- ---------- Secret Santa ----------
create table public.ss_draws (
  year int primary key check (year between 2000 and 2200),
  revealed boolean not null default false,
  drawn_at timestamptz not null default now()
);
create table public.ss_assignments (
  year int not null references public.ss_draws(year) on delete cascade,
  giver_id uuid not null references public.profiles(id) on delete cascade,
  receiver_id uuid not null references public.profiles(id) on delete cascade,
  model_name text,
  photo_path text,
  completed_at timestamptz,
  primary key (year, giver_id),
  unique (year, receiver_id),
  check (giver_id <> receiver_id)
);
alter table public.ss_draws enable row level security;
alter table public.ss_assignments enable row level security;
create policy "members read draws" on public.ss_draws for select to authenticated using (is_member());
create policy "giver reads own assignment" on public.ss_assignments for select to authenticated using (giver_id = auth.uid());
revoke all on public.ss_draws, public.ss_assignments from anon, authenticated;
grant select on public.ss_draws, public.ss_assignments to authenticated;

create or replace function public.ss_submit_model(p_year int, p_model_name text, p_photo_path text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_photo_path is not null and p_photo_path !~ ('^santa/[0-9]{4}/' || auth.uid() || '/[0-9a-f-]{36}\.jpg$') then
    raise exception 'Bad photo path';
  end if;
  update ss_assignments set model_name = left(p_model_name, 120), photo_path = coalesce(p_photo_path, photo_path), completed_at = now()
   where year = p_year and giver_id = auth.uid();
  if not found then raise exception 'You have no Secret Santa assignment for %', p_year; end if;
end $$;

create or replace function public.ss_progress()
returns table(year int, revealed boolean, people int, finished int)
language sql security definer set search_path = public as $$
  select d.year, d.revealed, count(a.*)::int, count(a.photo_path)::int
  from ss_draws d left join ss_assignments a on a.year = d.year
  where is_member() group by d.year, d.revealed order by d.year desc;
$$;

create or replace function public.ss_gallery()
returns table(year int, giver text, receiver text, model_name text, photo_path text)
language sql security definer set search_path = public as $$
  select a.year, g.display_name, r.display_name, a.model_name, a.photo_path
  from ss_assignments a join ss_draws d on d.year = a.year and d.revealed
  join profiles g on g.id = a.giver_id join profiles r on r.id = a.receiver_id
  where is_member() and a.photo_path is not null order by a.year desc, g.display_name;
$$;

create or replace function public._require_admin() returns void
language plpgsql security definer set search_path = public as $$
begin if not is_admin() then raise exception 'Organiser only'; end if; end $$;

create or replace function public.ss_set_revealed(p_year int, p_revealed boolean) returns void
language plpgsql security definer set search_path = public as $$
begin perform _require_admin(); update ss_draws set revealed = p_revealed where year = p_year; end $$;

create or replace function public.ss_delete_draw(p_year int) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _require_admin();
  if exists (select 1 from ss_assignments where year = p_year and photo_path is not null) then
    raise exception 'Photos already uploaded for % - not deleting', p_year;
  end if;
  delete from ss_draws where year = p_year;
end $$;

create or replace function public.admin_set_santa_active(p_user uuid, p_active boolean) returns void
language plpgsql security definer set search_path = public as $$
begin perform _require_admin(); update profiles set santa_active = p_active where id = p_user; end $$;

create or replace function public.admin_create_invite(p_kind text, p_display_name text, p_user uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare t uuid;
begin
  perform _require_admin();
  insert into invites(kind, display_name, user_id, created_by)
    values (p_kind, nullif(trim(p_display_name), ''), p_user, auth.uid()) returning token into t;
  return t;
end $$;

create or replace function public.admin_list_invites()
returns table(token uuid, kind text, display_name text, target text, created_at timestamptz, expires_at timestamptz)
language sql security definer set search_path = public as $$
  select i.token, i.kind, i.display_name, p.display_name, i.created_at, i.expires_at
  from invites i left join profiles p on p.id = i.user_id
  where is_admin() and i.used_at is null and i.expires_at > now() order by i.created_at desc;
$$;

create or replace function public.admin_revoke_invite(p_token uuid) returns void
language plpgsql security definer set search_path = public as $$
begin perform _require_admin(); delete from invites where token = p_token and used_at is null; end $$;

-- (ss_run_draw and the function grants are in 20261113103001_v2b_draw_and_grants.sql)
create or replace function public.get_page(p_path text) returns text
language sql stable security definer set search_path = public as $$
  select body from site_files where path = p_path;
$$;
create or replace function public.ping() returns text language sql as $$ select 'ok'::text $$;

-- photos: members only, each in their own folder
update storage.buckets set allowed_mime_types = array['image/jpeg'] where id = 'models';
create policy "members upload own photos" on storage.objects for insert to authenticated
  with check (bucket_id = 'models' and public.is_member()
    and name ~ ('^(santa|meetups|gifts)/[0-9]{4}/' || auth.uid() || '/[0-9a-f-]{36}\.jpg$'));
