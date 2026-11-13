-- Everything a member is allowed to see, in one feed. Each source keeps its own secrecy rule:
-- Santa: only revealed years; meetups: unless hidden from you; gifts: only once given.
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
  order by 7 desc;
$$;
revoke execute on function public.gallery_all() from public, anon;
grant execute on function public.gallery_all() to authenticated;
