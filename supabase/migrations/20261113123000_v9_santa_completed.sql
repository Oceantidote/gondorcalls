-- A Secret Santa gift counts as finished when completed_at is set (photo optional), not only when a photo exists.
-- The 2023–2025 history was entered as already given.
update public.ss_assignments set completed_at = make_timestamptz(year, 12, 25, 12, 0, 0, 'Europe/London')
 where year < 2026 and completed_at is null;

create or replace function public.ss_progress()
returns table(year int, revealed boolean, people int, finished int)
language sql security definer set search_path = public as $$
  select d.year, d.revealed, count(a.*)::int, count(a.completed_at)::int
  from ss_draws d left join ss_assignments a on a.year = d.year
  where is_member() group by d.year, d.revealed order by d.year desc;
$$;

create or replace function public.ss_delete_draw(p_year int) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _require_admin();
  if exists (select 1 from ss_assignments where year = p_year and (photo_path is not null or completed_at is not null)) then
    raise exception 'Gifts already finished for % - not deleting', p_year;
  end if;
  delete from email_outbox where kind = 'santa_drawn' and sent_at is null and subject = 'Secret Santa ' || p_year || ' has been drawn';
  delete from ss_draws where year = p_year;
end $$;
