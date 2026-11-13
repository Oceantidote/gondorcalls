-- Applied directly via SQL on 2026-11-13: members can only claim bring-list items for themselves (or unclaim).
drop policy i_upd on public.meetup_items;
create policy i_upd on public.meetup_items for update to authenticated using (meetup_visible(meetup_id))
  with check (meetup_visible(meetup_id) and (claimed_by is null or claimed_by = auth.uid()));
