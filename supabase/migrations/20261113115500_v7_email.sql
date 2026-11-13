-- Email: notifications are queued here by triggers and sent by the `email` edge function (action "outbox"),
-- which the Worker cron calls every 5 minutes. Invites and password resets are sent directly by the same function.
alter table public.profiles add column email_notifications boolean not null default true;
grant update (email_notifications) on public.profiles to authenticated;

create table public.email_outbox (
  id bigserial primary key,
  kind text not null,
  recipients uuid[] not null,
  subject text not null,
  body text not null,
  link text,
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  attempts int not null default 0,
  last_error text
);
alter table public.email_outbox enable row level security;
revoke all on public.email_outbox from anon, authenticated;

create or replace function public.queue_email(p_kind text, p_recipients uuid[], p_subject text, p_body text, p_link text) returns void
language sql security definer set search_path = public as $$
  insert into email_outbox(kind, recipients, subject, body, link)
  select p_kind, p_recipients, p_subject, p_body, 'https://gondorcalls.com/' || coalesce(p_link, '')
  where coalesce(array_length(p_recipients, 1), 0) > 0;
$$;
revoke execute on function public.queue_email(text,uuid[],text,text,text) from public, anon, authenticated;

create or replace function public._everyone_except(p_except uuid[]) returns uuid[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(id), '{}') from profiles where not (id = any(coalesce(p_except, '{}')));
$$;
revoke execute on function public._everyone_except(uuid[]) from public, anon, authenticated;
create or replace function public._name(p uuid) returns text language sql stable security definer set search_path = public as $$
  select coalesce((select display_name from profiles where id = p), 'Someone');
$$;
revoke execute on function public._name(uuid) from public, anon, authenticated;

-- ventures: new proposal → everyone else; launched → members (agree the charter); live → members
create or replace function public.trg_email_ventures() returns trigger
language plpgsql security definer set search_path = public as $$
declare mem uuid[];
begin
  if new.stage = 'proposal' and (tg_op = 'INSERT' or old.stage <> 'proposal') then
    perform queue_email('venture_proposal', _everyone_except(array[new.created_by]),
      'New venture proposal: ' || new.title,
      _name(new.created_by) || ' has proposed "' || new.title || '".' || case when new.summary <> '' then E'\n\n' || new.summary else '' end ||
      E'\n\nAre you in, supportive, or worried?' || case when new.decide_by is not null then ' Answer by ' || to_char(new.decide_by, 'FMDay FMDD Mon') || '.' else '' end,
      '#venture/' || new.id);
  elsif tg_op = 'UPDATE' and new.stage <> old.stage and new.stage in ('chartering','active') then
    select coalesce(array_agg(user_id), '{}') into mem from venture_members where venture_id = new.id;
    if new.stage = 'chartering' then
      perform queue_email('venture_launched', mem, new.title || ' has launched: agree the charter',
        '"' || new.title || '" has 2 or more people in, so it has launched. Before it goes live, everyone involved needs to agree the charter: shares, time, money, and what happens if someone leaves.',
        '#venture/' || new.id || '/charter');
    else
      perform queue_email('venture_live', mem, new.title || ' is live',
        'Everyone has agreed the charter, so "' || new.title || '" is now active. Your private workspace is ready: features, tasks, money and decisions.',
        '#venture/' || new.id);
    end if;
  end if;
  return new;
end $$;
create trigger email_ventures after insert or update of stage on public.ventures for each row execute function public.trg_email_ventures();

-- meetups: new meetup → everyone else (minus anyone it's hidden from)
create or replace function public.trg_email_meetups() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform queue_email('meetup_new', _everyone_except(array[new.created_by] || new.hidden_from),
    'New meetup: ' || new.title,
    _name(new.created_by) || ' has started planning "' || new.title || '". Add the dates that work for you and suggest somewhere to stay.' ||
      case when new.description <> '' then E'\n\n' || new.description else '' end,
    '#meetup/' || new.id);
  return new;
end $$;
create trigger email_meetups after insert on public.meetups for each row execute function public.trg_email_meetups();

-- gifts: plan opened → everyone except the birthday person; bought → everyone who owes the buyer
create or replace function public.trg_email_gifts() returns trigger
language plpgsql security definer set search_path = public as $$
declare who text := _name(new.recipient_id);
begin
  if tg_op = 'INSERT' then
    perform queue_email('gift_open', _everyone_except(array[new.recipient_id] || new.hidden_from),
      'Present planning: ' || who || ' on ' || to_char(new.birthday_on, 'FMDD FMMonth'),
      who || '''s birthday is on ' || to_char(new.birthday_on, 'FMDay FMDD FMMonth') || '. A gift plan is open (hidden from ' || who ||
      '). Add ideas, vote, and someone volunteer to buy it. Don''t mention it in the group chat!',
      '#gift/' || new.id);
  elsif new.status = 'bought' and old.status = 'planning' then
    perform queue_email('gift_bought', _everyone_except(array[new.recipient_id, new.buyer_id]),
      'Pay ' || _name(new.buyer_id) || ' back for ' || who || '''s present',
      _name(new.buyer_id) || ' has bought ' || coalesce(new.gift_title, 'the present') || ' for ' || who || '. Please send them £' ||
      trim(to_char(new.per_person, 'FM999990.00')) || ', then tick "I''ve paid" on the page.',
      '#gift/' || new.id);
  end if;
  return new;
end $$;
create trigger email_gifts after insert or update of status on public.gifts for each row execute function public.trg_email_gifts();

-- Secret Santa: draw made → each giver (no names in the email)
create or replace function public.trg_email_santa() returns trigger
language plpgsql security definer set search_path = public as $$
declare yr int; givers uuid[];
begin
  select min(year), array_agg(giver_id) into yr, givers from new_rows;
  perform queue_email('santa_drawn', givers, 'Secret Santa ' || yr || ' has been drawn',
    'The ' || yr || ' Secret Santa draw is done. Sign in to see who you are painting for (it''s only shown to you), and check their wishlist.',
    '#santa');
  return null;
end $$;
create trigger email_santa after insert on public.ss_assignments referencing new table as new_rows for each statement execute function public.trg_email_santa();

-- venture tasks: assigned to someone other than the person doing the assigning
create or replace function public.trg_email_tasks() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.owner_id is not null and new.owner_id is distinct from auth.uid()
     and (tg_op = 'INSERT' or new.owner_id is distinct from old.owner_id) then
    perform queue_email('task_assigned', array[new.owner_id],
      'Task for you: ' || new.title,
      coalesce(_name(auth.uid()), 'Someone') || ' gave you a task in "' || (select title from ventures where id = new.venture_id) || '": ' || new.title ||
        case when new.due_on is not null then E'\nDue ' || to_char(new.due_on, 'FMDay FMDD FMMonth') || '.' else '' end,
      '#venture/' || new.venture_id || '/tasks');
  end if;
  return new;
end $$;
create trigger email_tasks after insert or update of owner_id on public.venture_tasks for each row execute function public.trg_email_tasks();

-- For the email edge function (service role only)
create or replace function public.email_targets(p_ids uuid[], p_force boolean default false)
returns table(id uuid, email text, display_name text)
language sql stable security definer set search_path = public, auth as $$
  select p.id, u.email::text, p.display_name from profiles p join auth.users u on u.id = p.id
  where p.id = any(p_ids) and (p_force or p.email_notifications) and u.email is not null;
$$;
create or replace function public.user_by_email(p_email text) returns uuid
language sql stable security definer set search_path = public, auth as $$
  select u.id from auth.users u join profiles p on p.id = u.id where lower(u.email) = lower(trim(p_email)) limit 1;
$$;
revoke execute on function public.email_targets(uuid[],boolean), public.user_by_email(text) from public, anon, authenticated;
grant execute on function public.email_targets(uuid[],boolean), public.user_by_email(text) to service_role;
grant all on public.email_outbox to service_role;
grant usage, select on sequence public.email_outbox_id_seq to service_role;
