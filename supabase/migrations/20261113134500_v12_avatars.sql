-- Profile pictures: stored in the public "models" bucket under avatars/<user id>/<random>.jpg
alter table public.profiles add column if not exists avatar_path text
  check (avatar_path is null or avatar_path ~ ('^avatars/' || id || '/[0-9a-f-]{36}\.jpg$'));
grant update (avatar_path) on public.profiles to authenticated;

drop policy if exists "members upload own avatar" on storage.objects;
create policy "members upload own avatar" on storage.objects for insert to authenticated
  with check (bucket_id = 'models' and public.is_member()
    and name ~ ('^avatars/' || auth.uid() || '/[0-9a-f-]{36}\.jpg$'));
