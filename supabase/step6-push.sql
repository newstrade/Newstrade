-- NewsTrade step 6: push notifications (Premium): event reminders and price alerts.
-- Run setup-all.sql first. Replace PASTE_CRON_SECRET at the bottom with the secret Claude gave you in chat.

create table if not exists public.push_subscriptions (
  endpoint   text primary key,
  user_id    uuid not null default auth.uid() references auth.users (id) on delete cascade,
  p256dh     text not null,
  auth_key   text not null,
  created_at timestamptz not null default now()
);
alter table public.push_subscriptions enable row level security;
drop policy if exists "Own push devices" on public.push_subscriptions;
create policy "Own push devices" on public.push_subscriptions for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

create table if not exists public.price_alerts (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null default auth.uid() references auth.users (id) on delete cascade,
  market       text not null check (char_length(market) <= 40),
  direction    text not null check (direction in ('above', 'below')),
  price        numeric not null check (price > 0),
  created_at   timestamptz not null default now(),
  triggered_at timestamptz
);
create index if not exists price_alerts_active on public.price_alerts (market) where triggered_at is null;
alter table public.price_alerts enable row level security;
drop policy if exists "Read own price alerts" on public.price_alerts;
drop policy if exists "Add price alerts" on public.price_alerts;
drop policy if exists "Delete own price alerts" on public.price_alerts;
create policy "Read own price alerts" on public.price_alerts for select to authenticated using (user_id = auth.uid());
create policy "Add price alerts" on public.price_alerts for insert to authenticated
  with check (user_id = auth.uid() and public.is_premium(auth.uid())
              and (select count(*) from public.price_alerts p where p.user_id = auth.uid() and p.triggered_at is null) < 20);
create policy "Delete own price alerts" on public.price_alerts for delete to authenticated using (user_id = auth.uid());

alter table public.event_alerts add column if not exists push_sent_at timestamptz;

-- What the sender needs (only the server's own key can call these)
create or replace function public.due_event_pushes()
returns table (user_id uuid, event_id text, title text, at timestamptz)
language sql stable security definer set search_path = public as $$
  select a.user_id, a.event_id, a.title, a.at
    from public.event_alerts a
   where a.push_sent_at is null and a.at > now() and a.at <= now() + interval '31 minutes'
     and public.is_premium(a.user_id)
     and exists (select 1 from public.push_subscriptions s where s.user_id = a.user_id);
$$;
create or replace function public.active_price_alerts()
returns table (id uuid, user_id uuid, market text, direction text, price numeric)
language sql stable security definer set search_path = public as $$
  select p.id, p.user_id, p.market, p.direction, p.price
    from public.price_alerts p
   where p.triggered_at is null and public.is_premium(p.user_id)
     and exists (select 1 from public.push_subscriptions s where s.user_id = p.user_id);
$$;
revoke execute on function public.due_event_pushes() from public, anon, authenticated;
revoke execute on function public.active_price_alerts() from public, anon, authenticated;

-- Run the sender every 5 minutes
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;
select cron.unschedule('newstrade-push') where exists (select 1 from cron.job where jobname = 'newstrade-push');
select cron.schedule('newstrade-push', '*/5 * * * *', $$
  select net.http_post(
    url := 'https://uqmtoteqcwxtvftkgogh.supabase.co/functions/v1/push-sender',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron-secret', 'PASTE_CRON_SECRET'),
    body := '{}'::jsonb
  );
$$);
