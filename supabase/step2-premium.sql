-- NewsTrade step 2: Premium subscriptions ($5/month via Lemon Squeezy). Safe to run more than once.
-- The "lemon-webhook" function writes to this table when someone subscribes, renews or cancels.

create table if not exists public.subscriptions (
  user_id            uuid primary key references auth.users (id) on delete cascade,
  ls_subscription_id text,
  status             text not null,          -- active, on_trial, past_due, cancelled, expired, unpaid, paused
  renews_at          timestamptz,
  ends_at            timestamptz,
  portal_url         text,
  updated_at         timestamptz not null default now()
);
alter table public.subscriptions enable row level security;
drop policy if exists "Read own subscription" on public.subscriptions;
create policy "Read own subscription" on public.subscriptions for select to authenticated using (user_id = auth.uid());
-- No insert/update policies: only the payment webhook (server side) can change subscriptions.

create or replace function public.is_premium(uid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.subscriptions s
     where s.user_id = uid
       and (s.status in ('active', 'on_trial', 'past_due')
            or (s.status = 'cancelled' and s.ends_at > now()))
  );
$$;
grant execute on function public.is_premium(uuid) to authenticated;

-- Trade journal becomes Premium: subscribers read and write; anyone can still delete their own old trades.
drop policy if exists "Read own trades"   on public.journal;
drop policy if exists "Add own trades"    on public.journal;
drop policy if exists "Change own trades" on public.journal;
drop policy if exists "Delete own trades" on public.journal;
create policy "Read own trades"   on public.journal for select to authenticated using (user_id = auth.uid() and public.is_premium(auth.uid()));
create policy "Add own trades"    on public.journal for insert to authenticated with check (user_id = auth.uid() and public.is_premium(auth.uid()));
create policy "Change own trades" on public.journal for update to authenticated using (user_id = auth.uid() and public.is_premium(auth.uid())) with check (user_id = auth.uid());
create policy "Delete own trades" on public.journal for delete to authenticated using (user_id = auth.uid());
