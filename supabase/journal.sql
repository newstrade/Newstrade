-- NewsTrade trade journal. Run once in Supabase → SQL Editor.
-- Each signed-in user can only see, add, change and delete their own trades.

create table if not exists public.journal (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  created_at  timestamptz not null default now(),
  traded_on   date not null default current_date,
  symbol      text not null check (char_length(symbol) between 1 and 30),
  side        text not null default 'buy' check (side in ('buy', 'sell')),
  entry       numeric,
  exit        numeric,
  pnl         numeric not null,
  notes       text check (notes is null or char_length(notes) <= 500)
);

create index if not exists journal_user_date on public.journal (user_id, traded_on desc);

alter table public.journal enable row level security;

drop policy if exists "Read own trades"   on public.journal;
drop policy if exists "Add own trades"    on public.journal;
drop policy if exists "Change own trades" on public.journal;
drop policy if exists "Delete own trades" on public.journal;

create policy "Read own trades"   on public.journal for select to authenticated using (user_id = auth.uid());
create policy "Add own trades"    on public.journal for insert to authenticated with check (user_id = auth.uid());
create policy "Change own trades" on public.journal for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "Delete own trades" on public.journal for delete to authenticated using (user_id = auth.uid());
