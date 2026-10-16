-- NewsTrade step 8: Premium chat extras — ★ Pro badge on messages and a Premium-only VIP room. Safe to run more than once.

alter table public.comments add column if not exists pro boolean not null default false;
alter table public.comments add column if not exists owner boolean not null default false;

-- Re-create the comment trigger: author name, Pro badge, word filter, 5 posts a minute, VIP room for Premium only.
create or replace function public.comments_before_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.user_id := auth.uid();
  new.created_at := now();
  select coalesce(nullif(trim(u.raw_user_meta_data->>'name'), ''), 'Trader') into new.name
    from auth.users u where u.id = auth.uid();
  new.name := public.clean_text(new.name);
  new.body := public.clean_text(new.body);
  new.pro  := public.is_premium(auth.uid());
  new.owner := exists (select 1 from public.site_owners o where o.user_id = auth.uid());
  if new.event_id = 'chat_vip' and not new.pro then
    raise exception 'The VIP room is for Premium members';
  end if;
  if (select count(*) from public.comments c
        where c.user_id = auth.uid() and c.created_at > now() - interval '1 minute') >= 5 then
    raise exception 'Slow down: too many comments in a minute';
  end if;
  return new;
end $$;

-- Only Premium members can read the VIP room; everything else stays public.
drop policy if exists "Anyone reads comments" on public.comments;
create policy "Anyone reads comments" on public.comments for select to anon, authenticated
  using (event_id <> 'chat_vip' or public.is_premium(auth.uid()));

-- Gold OWNER badge on everything the site owner has already posted.
update public.comments c set owner = true
 where not c.owner and exists (select 1 from public.site_owners o where o.user_id = c.user_id);
