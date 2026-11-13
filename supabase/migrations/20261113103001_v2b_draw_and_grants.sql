-- Applied as part of v2_members_platform; split out here for readability.

-- Draw: random-restart hill climbing; a pair last used y years ago costs 10^(n-1-y),
-- so with a fixed group of n nobody repeats a person within n-1 years.
-- Reciprocal pairs (A->B and B->A) cost 0.25.
create or replace function public.ss_run_draw(p_year int) returns json
language plpgsql security definer set search_path = public as $$
declare
  ids uuid[]; n int; cost float8[]; i int; j int; q int; k int; ys int;
  perm int[]; best int[]; best_score float8 := 'infinity'; s float8; s2 float8;
  improved boolean; tmp int; restarts int;
begin
  perform _require_admin();
  if exists (select 1 from ss_draws where year = p_year) then raise exception 'Draw for % already exists', p_year; end if;
  select array_agg(id order by random()) into ids from profiles where santa_active;
  n := coalesce(array_length(ids, 1), 0);
  if n < 3 then raise exception 'Need at least 3 people in Secret Santa (have %)', n; end if;
  restarts := greatest(20, 1500 / n);
  cost := array_fill(0::float8, array[n*n]);
  for i in 1..n loop
    for j in 1..n loop
      if i = j then cost[(i-1)*n+j] := 1e12;
      else
        select p_year - max(a.year) into ys from ss_assignments a
         where a.giver_id = ids[i] and a.receiver_id = ids[j] and a.year < p_year;
        if ys is not null then cost[(i-1)*n+j] := power(10::float8, (n-1-ys)); end if;
      end if;
    end loop;
  end loop;
  for k in 1..restarts loop
    select array_agg(x order by random()) into perm from generate_series(1, n) x;
    s := 0;
    for q in 1..n loop s := s + cost[(q-1)*n+perm[q]]; if perm[perm[q]] = q then s := s + 0.25; end if; end loop;
    loop
      improved := false;
      for i in 1..n-1 loop
        for j in i+1..n loop
          tmp := perm[i]; perm[i] := perm[j]; perm[j] := tmp;
          s2 := 0;
          for q in 1..n loop s2 := s2 + cost[(q-1)*n+perm[q]]; if perm[perm[q]] = q then s2 := s2 + 0.25; end if; end loop;
          if s2 < s - 1e-9 then s := s2; improved := true;
          else tmp := perm[i]; perm[i] := perm[j]; perm[j] := tmp; end if;
        end loop;
      end loop;
      exit when not improved;
    end loop;
    if s < best_score then best_score := s; best := perm; end if;
    exit when best_score = 0;
  end loop;
  insert into ss_draws(year) values (p_year);
  for q in 1..n loop insert into ss_assignments(year, giver_id, receiver_id) values (p_year, ids[q], ids[best[q]]); end loop;
  return (select json_build_object('year', p_year, 'people', n, 'repeat_pairs', count(prev.gap), 'shortest_gap_years', min(prev.gap))
    from ss_assignments a
    left join lateral (select p_year - max(b.year) gap from ss_assignments b
       where b.giver_id = a.giver_id and b.receiver_id = a.receiver_id and b.year < p_year) prev on prev.gap is not null
    where a.year = p_year);
end $$;

-- grants
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.get_page(text), public.ping() to anon, authenticated;
grant execute on function public.is_member(), public.is_admin(), public.can_see(uuid[]),
  public.ss_submit_model(int,text,text), public.ss_progress(), public.ss_gallery(),
  public.ss_set_revealed(int,boolean), public.ss_delete_draw(int), public.ss_run_draw(int),
  public.admin_set_santa_active(uuid,boolean), public.admin_create_invite(text,text,uuid),
  public.admin_list_invites(), public.admin_revoke_invite(uuid) to authenticated;
