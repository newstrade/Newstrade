-- NewsTrade step 7: anonymous visit counter + owner-only stats. Safe to run more than once.
-- After running, make yourself the owner (see the last line).

create table if not exists public.visits (
  id         bigint generated always as identity primary key,
  at         timestamptz not null default now(),
  visitor    text not null check (char_length(visitor) between 8 and 40),  -- random id kept on the device, not a person
  source     text check (source is null or char_length(source) <= 40),      -- ?src= link tag, e.g. whatsapp
  app        boolean not null default false,                                -- opened from the installed app
  lang       text check (lang is null or char_length(lang) <= 5)
);
create index if not exists visits_at on public.visits (at);
alter table public.visits enable row level security;
drop policy if exists "Anyone can count a visit" on public.visits;
create policy "Anyone can count a visit" on public.visits for insert to anon, authenticated
  with check (at > now() - interval '1 minute' and at < now() + interval '1 minute');
-- Nobody can read raw visits through the app; the owner sees totals through visit_stats().

create table if not exists public.site_owners (user_id uuid primary key references auth.users (id) on delete cascade);
alter table public.site_owners enable row level security;

create or replace function public.visit_stats(days int default 30) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare tz text := 'Africa/Nairobi'; result jsonb;
begin
  if not exists (select 1 from public.site_owners where user_id = auth.uid()) then
    raise exception 'Only the site owner can see stats';
  end if;
  select jsonb_build_object(
    'total_visits',   (select count(*) from visits),
    'total_visitors', (select count(distinct visitor) from visits),
    'today_visits',   (select count(*) from visits where (at at time zone tz)::date = (now() at time zone tz)::date),
    'today_visitors', (select count(distinct visitor) from visits where (at at time zone tz)::date = (now() at time zone tz)::date),
    'week_visitors',  (select count(distinct visitor) from visits where at > now() - interval '7 days'),
    'app_visitors',   (select count(distinct visitor) from visits where app),
    'members',        (select count(*) from auth.users),
    'members_today',  (select count(*) from auth.users where (created_at at time zone tz)::date = (now() at time zone tz)::date),
    'daily', (select coalesce(jsonb_agg(jsonb_build_object('day', d::date, 'visits', coalesce(v.visits, 0), 'visitors', coalesce(v.visitors, 0)) order by d), '[]')
                from generate_series((now() at time zone tz)::date - (days - 1), (now() at time zone tz)::date, interval '1 day') d
                left join (select (at at time zone tz)::date as day, count(*) as visits, count(distinct visitor) as visitors
                             from visits where at > now() - make_interval(days => days + 1) group by 1) v on v.day = d::date),
    'sources', (select coalesce(jsonb_agg(jsonb_build_object('source', s, 'visitors', n) order by n desc), '[]')
                  from (select coalesce(source, 'direct') as s, count(distinct visitor) as n
                          from visits where at > now() - make_interval(days => days) group by 1 order by 2 desc limit 12) x)
  ) into result;
  return result;
end $$;
revoke execute on function public.visit_stats(int) from public, anon;
grant execute on function public.visit_stats(int) to authenticated;

-- Make yourself the owner: put the email you sign in to NewsTrade with, then run this line.
-- insert into public.site_owners select id from auth.users where lower(email) = lower('YOUR-EMAIL') on conflict do nothing;

-- Public counter for the app: only totals, no details. The app hides it until the weekly number reaches 50.
create or replace function public.public_stats() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'week_visitors', (select count(distinct visitor) from public.visits where at > now() - interval '7 days'),
    'members',       (select count(*) from auth.users));
$$;
grant execute on function public.public_stats() to anon, authenticated;
