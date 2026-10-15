-- NewsTrade: COMPLETE database setup. Paste all of this into Supabase → SQL Editor and tap Run.
-- Safe to run more than once. Email alerts (Brevo) are a separate step: step3-email-sender.sql.

-- ===================== journal.sql =====================
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

-- ===================== step1-comments-and-alerts.sql =====================
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

-- ===================== step1b-live-chat.sql =====================
-- NewsTrade: make chat messages appear instantly (Supabase Realtime). Safe to run more than once.
do $$
begin
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'comments') then
    alter publication supabase_realtime add table public.comments;
  end if;
end $$;

-- ===================== step1c-word-filter.sql =====================
-- NewsTrade: bad-word filter for chat, discussions and display names. Safe to run more than once.
create or replace function public.clean_text(t text) returns text
language plpgsql immutable as $$
declare
  pat text := '(^|[^a-z0-9])(' || array_to_string(array[
    'f+[u*@v]+c*k+\w*', 'motherf\w*', 's+h+[i1!*]+t+(s|ty|ter|head|hole)?', 'b+[i1!]+t+c+h+(es|y)?',
    'a+s+s+h+o+l+e+s?', 'c+u+n+t+s?', 'd+[i1!]+c+k+(head|s)?', 'p+u+s+s+y+', 'b+a+s+t+a+r+d+s?',
    'w+h+o+r+e+s?', 's+l+u+t+s?', 'n+[i1!]+g+g+\w*', 'f+a+g+(g+o+t+)?s?', 'r+e+t+a+r+d+(s|ed)?',
    'w+a+n+k+(er|ers|ing)?', 'p+r+[i1]+c+k+s?', 'c+o+c+k+s?', 't+w+a+t+s?',
    'k+u+m+a+', 'kumamako', 'kumamayo', 'm+s+e+n+g+e+', 'm+a+l+a+y+a+', 'm+k+u+n+d+u+', 'm+a+t+a+k+o+'
  ], '|') || ')(?=$|[^a-z0-9])';
begin
  if t is null then return null; end if;
  return regexp_replace(t, pat, '\1****', 'gi');
end $$;

-- Re-create the comment trigger: fill in the author's name, filter words, and limit to 5 posts a minute.
create or replace function public.comments_before_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.user_id := auth.uid();
  new.created_at := now();
  select coalesce(nullif(trim(u.raw_user_meta_data->>'name'), ''), 'Trader') into new.name
    from auth.users u where u.id = auth.uid();
  new.name := public.clean_text(new.name);
  new.body := public.clean_text(new.body);
  if (select count(*) from public.comments c
        where c.user_id = auth.uid() and c.created_at > now() - interval '1 minute') >= 5 then
    raise exception 'Slow down: too many comments in a minute';
  end if;
  return new;
end $$;

-- Clean anything already posted.
update public.comments
   set body = public.clean_text(body), name = public.clean_text(name)
 where body is distinct from public.clean_text(body) or name is distinct from public.clean_text(name);

-- ===================== step2-premium.sql =====================
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

-- ===================== step4-play-store.sql =====================
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

-- ===================== step5-community.sql =====================
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
