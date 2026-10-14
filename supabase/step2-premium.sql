-- NewsTrade step 2: Premium subscriptions ($5/month via Dodo Payments). Safe to run more than once.
-- The "dodo-webhook" function writes to this table when someone subscribes, renews or cancels.

create table if not exists public.subscriptions (
  user_id            uuid primary key references auth.users (id) on delete cascade,
  ls_subscription_id text,                   -- Dodo subscription id
  status             text not null,          -- active, cancelled (until ends_at), on_hold, expired
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

-- Lets the payment webhook (server side only) find an account by the buyer's email.
create or replace function public.user_id_by_email(p_email text) returns uuid
language sql stable security definer set search_path = public as $$
  select id from auth.users where lower(email) = lower(p_email) limit 1;
$$;
revoke execute on function public.user_id_by_email(text) from public, anon, authenticated;
