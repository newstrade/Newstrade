-- NewsTrade step 5: sentiment polls, Premium leaderboard, invite-a-friend rewards. Safe to run more than once.

-- ---------- Sentiment polls: one bullish/bearish vote per person, per market, per day ----------
create table if not exists public.sentiment (
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  market  text not null check (char_length(market) <= 40),
  day     date not null default current_date,
  vote    smallint not null check (vote in (-1, 1)),
  primary key (user_id, market, day)
);
alter table public.sentiment enable row level security;
drop policy if exists "Read own votes" on public.sentiment;
drop policy if exists "Vote" on public.sentiment;
drop policy if exists "Change vote" on public.sentiment;
create policy "Read own votes" on public.sentiment for select to authenticated using (user_id = auth.uid());
create policy "Vote" on public.sentiment for insert to authenticated with check (user_id = auth.uid() and day = current_date);
create policy "Change vote" on public.sentiment for update to authenticated using (user_id = auth.uid() and day = current_date) with check (user_id = auth.uid() and day = current_date);

-- Totals for the last 24 hours, readable by everyone (no names, just counts).
create or replace function public.sentiment_totals(markets text[])
returns table (market text, bulls int, bears int)
language sql stable security definer set search_path = public as $$
  select s.market, count(*) filter (where s.vote = 1)::int, count(*) filter (where s.vote = -1)::int
    from public.sentiment s
   where s.market = any(markets) and s.day >= current_date - 1
   group by s.market;
$$;
grant execute on function public.sentiment_totals(text[]) to anon, authenticated;

-- ---------- Invite friends: 3 friends who sign up = 30 days of Premium ----------
create table if not exists public.referral_codes (
  user_id uuid primary key references auth.users (id) on delete cascade,
  code    text not null unique
);
create table if not exists public.referrals (
  referee    uuid primary key references auth.users (id) on delete cascade,
  referrer   uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  check (referee <> referrer)
);
alter table public.referral_codes enable row level security;
alter table public.referrals enable row level security;
-- No direct access: everything goes through the functions below.

create or replace function public.referral_bonus_until(uid uuid) returns timestamptz
language sql stable security definer set search_path = public as $$
  -- every 3rd friend unlocks 30 days, counted from the day that friend joined
  select max(created_at) + interval '30 days'
    from (select created_at, row_number() over (order by created_at) as n
            from public.referrals where referrer = uid) r
   where n % 3 = 0;
$$;

-- My code, how many friends joined, and until when my free Premium runs.
create or replace function public.my_referral() returns table (code text, friends int, bonus_until timestamptz)
language plpgsql security definer set search_path = public as $$
declare c text;
begin
  if auth.uid() is null then raise exception 'Not signed in'; end if;
  select rc.code into c from public.referral_codes rc where rc.user_id = auth.uid();
  if c is null then
    loop
      c := lower(substr(md5(random()::text || clock_timestamp()::text), 1, 7));
      begin
        insert into public.referral_codes (user_id, code) values (auth.uid(), c);
        exit;
      exception when unique_violation then
        if exists (select 1 from public.referral_codes where user_id = auth.uid()) then
          select rc.code into c from public.referral_codes rc where rc.user_id = auth.uid(); exit;
        end if;
      end;
    end loop;
  end if;
  return query select c,
    (select count(*)::int from public.referrals where referrer = auth.uid()),
    public.referral_bonus_until(auth.uid());
end $$;
grant execute on function public.my_referral() to authenticated;

-- Called by a new member's app once they're signed in. Only counts accounts created in the last 7 days,
-- with a confirmed email, and only once per person.
create or replace function public.claim_referral(ref_code text) returns boolean
language plpgsql security definer set search_path = public, auth as $$
declare r uuid; joined timestamptz; confirmed timestamptz;
begin
  if auth.uid() is null then return false; end if;
  select user_id into r from public.referral_codes where code = lower(trim(ref_code));
  if r is null or r = auth.uid() then return false; end if;
  select created_at, email_confirmed_at into joined, confirmed from auth.users where id = auth.uid();
  if confirmed is null or joined < now() - interval '7 days' then return false; end if;
  insert into public.referrals (referee, referrer) values (auth.uid(), r) on conflict (referee) do nothing;
  return found;
end $$;
grant execute on function public.claim_referral(text) to authenticated;

-- Premium now also counts free months earned by inviting friends.
create or replace function public.is_premium(uid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.subscriptions s
     where s.user_id = uid
       and (s.status in ('active', 'on_trial', 'past_due')
            or (s.status = 'cancelled' and s.ends_at > now()))
  ) or coalesce(public.referral_bonus_until(uid) > now(), false);
$$;
grant execute on function public.is_premium(uuid) to authenticated;

-- ---------- Leaderboard: Premium members who opt in, ranked by win rate (min 5 trades, last 30 days) ----------
create table if not exists public.leaderboard_optin (
  user_id      uuid primary key default auth.uid() references auth.users (id) on delete cascade,
  display_name text not null check (char_length(trim(display_name)) between 2 and 24),
  created_at   timestamptz not null default now()
);
alter table public.leaderboard_optin enable row level security;
drop policy if exists "Read own opt-in" on public.leaderboard_optin;
drop policy if exists "Join leaderboard" on public.leaderboard_optin;
drop policy if exists "Rename on leaderboard" on public.leaderboard_optin;
drop policy if exists "Leave leaderboard" on public.leaderboard_optin;
create policy "Read own opt-in" on public.leaderboard_optin for select to authenticated using (user_id = auth.uid());
create policy "Join leaderboard" on public.leaderboard_optin for insert to authenticated with check (user_id = auth.uid() and public.is_premium(auth.uid()));
create policy "Rename on leaderboard" on public.leaderboard_optin for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "Leave leaderboard" on public.leaderboard_optin for delete to authenticated using (user_id = auth.uid());

create or replace function public.leaderboard()
returns table (display_name text, trades int, win_rate numeric, is_me boolean)
language sql stable security definer set search_path = public as $$
  select coalesce(public.clean_text(o.display_name), 'Trader'),
         count(j.*)::int,
         round(100.0 * count(j.*) filter (where j.pnl > 0) / count(j.*), 1),
         o.user_id = auth.uid()
    from public.leaderboard_optin o
    join public.journal j on j.user_id = o.user_id and j.traded_on >= current_date - 30
   where public.is_premium(o.user_id)
   group by o.user_id, o.display_name
  having count(j.*) >= 5
   order by 3 desc, 2 desc
   limit 20;
$$;
grant execute on function public.leaderboard() to anon, authenticated;
