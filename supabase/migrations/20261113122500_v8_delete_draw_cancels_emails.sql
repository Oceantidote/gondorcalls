-- Deleting a draw (only possible before any photos) also cancels its "you've been drawn" emails if they haven't gone yet.
create or replace function public.ss_delete_draw(p_year int) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _require_admin();
  if exists (select 1 from ss_assignments where year = p_year and photo_path is not null) then
    raise exception 'Photos already uploaded for % - not deleting', p_year;
  end if;
  delete from email_outbox where kind = 'santa_drawn' and sent_at is null and subject = 'Secret Santa ' || p_year || ' has been drawn';
  delete from ss_draws where year = p_year;
end $$;
