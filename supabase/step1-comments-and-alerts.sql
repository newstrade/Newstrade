-- NewsTrade step 1: event discussion + email alert list. Safe to run more than once.

-- COMMENTS: anyone can read; signed-in members post and delete their own.
create table if not exists public.comments (
  id         uuid primary key default gen_random_uuid(),
  event_id   text not null check (char_length(event_id) <= 120),
  user_id    uuid not null default auth.uid() references auth.users (id) on delete cascade,
  name       text not null default 'Trader',
  body       text not null check (char_length(trim(body)) between 1 and 500),
  created_at timestamptz not null default now()
);
create index if not exists comments_event on public.comments (event_id, created_at);
alter table public.comments enable row level security;
drop policy if exists "Anyone reads comments" on public.comments;
drop policy if exists "Members add comments" on public.comments;
drop policy if exists "Members delete own comments" on public.comments;
create policy "Anyone reads comments" on public.comments for select to anon, authenticated using (true);
create policy "Members add comments" on public.comments for insert to authenticated with check (user_id = auth.uid());
create policy "Members delete own comments" on public.comments for delete to authenticated using (user_id = auth.uid());

-- Fill in the author's name from their account and limit posting to 5 comments a minute.
create or replace function public.comments_before_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.user_id := auth.uid();
  new.created_at := now();
  select coalesce(nullif(trim(u.raw_user_meta_data->>'name'), ''), 'Trader') into new.name
    from auth.users u where u.id = auth.uid();
  if (select count(*) from public.comments c
        where c.user_id = auth.uid() and c.created_at > now() - interval '1 minute') >= 5 then
    raise exception 'Slow down: too many comments in a minute';
  end if;
  return new;
end $$;
drop trigger if exists comments_before_insert on public.comments;
create trigger comments_before_insert before insert on public.comments
  for each row execute function public.comments_before_insert();

-- EVENT ALERTS: which events each member starred, so the email job knows whom to remind.
create table if not exists public.event_alerts (
  user_id  uuid not null default auth.uid() references auth.users (id) on delete cascade,
  event_id text not null check (char_length(event_id) <= 120),
  title    text not null check (char_length(title) <= 160),
  at       timestamptz not null,
  sent_at  timestamptz,
  primary key (user_id, event_id)
);
create index if not exists event_alerts_due on public.event_alerts (at) where sent_at is null;
alter table public.event_alerts enable row level security;
drop policy if exists "Read own alerts" on public.event_alerts;
drop policy if exists "Add own alerts" on public.event_alerts;
drop policy if exists "Change own alerts" on public.event_alerts;
drop policy if exists "Delete own alerts" on public.event_alerts;
create policy "Read own alerts" on public.event_alerts for select to authenticated using (user_id = auth.uid());
create policy "Add own alerts" on public.event_alerts for insert to authenticated with check (user_id = auth.uid());
create policy "Change own alerts" on public.event_alerts for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "Delete own alerts" on public.event_alerts for delete to authenticated using (user_id = auth.uid());
