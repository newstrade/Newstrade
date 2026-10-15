-- NewsTrade step 4: Google Play requirements (report messages + delete account). Safe to run more than once.

-- Reports: members flag a message; only you (in the Supabase dashboard) can read them.
create table if not exists public.reports (
  id          uuid primary key default gen_random_uuid(),
  comment_id  uuid not null references public.comments (id) on delete cascade,
  reporter    uuid not null default auth.uid() references auth.users (id) on delete cascade,
  created_at  timestamptz not null default now(),
  unique (comment_id, reporter)
);
alter table public.reports enable row level security;
drop policy if exists "Members report messages" on public.reports;
create policy "Members report messages" on public.reports for insert to authenticated with check (reporter = auth.uid());

-- See the most-reported messages (run this whenever you want to moderate):
--   select c.id, c.name, c.body, count(*) as reports
--     from public.reports r join public.comments c on c.id = r.comment_id
--    group by c.id order by reports desc;
-- Remove one:   delete from public.comments where id = 'PASTE-ID';

-- Delete my account: removes the signed-in user and, through "on delete cascade",
-- their journal, alerts, comments, reports and subscription row.
create or replace function public.delete_my_account() returns void
language plpgsql security definer set search_path = public, auth as $$
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  delete from public.comments where user_id = auth.uid();
  delete from auth.users where id = auth.uid();
end $$;
revoke execute on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;
