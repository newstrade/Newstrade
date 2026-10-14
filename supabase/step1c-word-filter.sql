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
