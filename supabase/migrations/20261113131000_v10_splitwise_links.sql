-- Splitwise without the API: the site says who should be in a group, a member creates it in the
-- Splitwise app, and pastes its link back here. One link per meetup; one per birthday person,
-- reused every year and never shown to that person.
create table public.splitwise_links (
  kind text not null check (kind in ('meetup', 'birthday')),
  ref_id uuid not null,   -- meetups.id, or profiles.id of the birthday person
  url text not null check (length(url) <= 300 and url ~ '^https://([a-z0-9-]+\.)*splitwise\.com/'),
  set_by uuid references public.profiles(id) on delete set null,
  set_at timestamptz not null default now(),
  primary key (kind, ref_id)
);
alter table public.splitwise_links enable row level security;
revoke all on public.splitwise_links from anon, authenticated;   -- RPC access only

create or replace function public._sw_can_see(p_kind text, p_ref uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select case p_kind
    when 'meetup' then meetup_visible(p_ref)
    when 'birthday' then is_member() and p_ref <> auth.uid() and exists (select 1 from profiles where id = p_ref)
    else false end;
$$;

create or replace function public._sw_can_set(p_kind text, p_ref uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select _sw_can_see(p_kind, p_ref) and (p_kind = 'birthday' or meetup_manager(p_ref)
    or exists (select 1 from meetup_rsvps r where r.meetup_id = p_ref and r.user_id = auth.uid() and r.status = 'going'));
$$;

create or replace function public.splitwise_link_get(p_kind text, p_ref uuid)
returns table(url text, set_by_name text, set_at timestamptz, can_set boolean)
language sql stable security definer set search_path = public as $$
  select l.url, p.display_name, l.set_at, _sw_can_set(p_kind, p_ref)
  from (select 1) x left join splitwise_links l on l.kind = p_kind and l.ref_id = p_ref
  left join profiles p on p.id = l.set_by
  where _sw_can_see(p_kind, p_ref);
$$;

create or replace function public.splitwise_link_set(p_kind text, p_ref uuid, p_url text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not _sw_can_set(p_kind, p_ref) then raise exception 'Only people going can set the Splitwise group'; end if;
  if nullif(trim(p_url), '') is null then
    delete from splitwise_links where kind = p_kind and ref_id = p_ref;
  else
    insert into splitwise_links (kind, ref_id, url, set_by) values (p_kind, p_ref, trim(p_url), auth.uid())
    on conflict (kind, ref_id) do update set url = excluded.url, set_by = excluded.set_by, set_at = now();
  end if;
end $$;

-- Who should be in the group, with the email Splitwise needs to add them.
create or replace function public.splitwise_people(p_kind text, p_ref uuid)
returns table(display_name text, email text)
language sql stable security definer set search_path = public, auth as $$
  select p.display_name, u.email::text
  from profiles p join auth.users u on u.id = p.id
  where _sw_can_see(p_kind, p_ref) and case p_kind
    when 'meetup' then exists (select 1 from meetup_rsvps r where r.meetup_id = p_ref and r.user_id = p.id and r.status = 'going')
    else p.id <> p_ref end
  order by p.display_name;
$$;

create or replace function public._sw_meetup_deleted() returns trigger
language plpgsql security definer set search_path = public as $$
begin delete from splitwise_links where kind = 'meetup' and ref_id = old.id; return old; end $$;
create trigger sw_meetup_deleted after delete on public.meetups for each row execute function public._sw_meetup_deleted();

revoke execute on function public._sw_can_see(text, uuid), public._sw_can_set(text, uuid), public._sw_meetup_deleted() from public, anon, authenticated;
revoke execute on function public.splitwise_link_get(text, uuid), public.splitwise_link_set(text, uuid, text), public.splitwise_people(text, uuid) from public, anon;
grant execute on function public.splitwise_link_get(text, uuid), public.splitwise_link_set(text, uuid, text), public.splitwise_people(text, uuid) to authenticated;
