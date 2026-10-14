-- NewsTrade step 3: send Premium alert emails through Brevo (free, 300 emails a day).
-- Run step 2 (Premium) first. Before running: replace the two PASTE_... values below. Run this only once.

create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;

select vault.create_secret('PASTE_YOUR_BREVO_API_KEY', 'brevo_api_key');
select vault.create_secret('PASTE_YOUR_VERIFIED_SENDER_EMAIL', 'alert_sender');

create or replace function public.send_event_alert_emails() returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  r record;
  k text;
  s text;
begin
  select decrypted_secret into k from vault.decrypted_secrets where name = 'brevo_api_key';
  select decrypted_secret into s from vault.decrypted_secrets where name = 'alert_sender';
  if k is null or s is null then return; end if;

  for r in
    select a.user_id, a.event_id, a.title, a.at, u.email,
           coalesce(nullif(u.raw_user_meta_data->>'tz', ''), 'UTC') as tz,
           coalesce(nullif(u.raw_user_meta_data->>'name', ''), 'there') as name
      from public.event_alerts a
      join auth.users u on u.id = a.user_id
     where a.sent_at is null
       and a.at > now()
       and a.at <= now() + interval '30 minutes'
       and u.email_confirmed_at is not null
       and coalesce((u.raw_user_meta_data->>'emailAlerts')::boolean, false)
       and public.is_premium(a.user_id)
     limit 200
  loop
    begin
      perform net.http_post(
        url := 'https://api.brevo.com/v3/smtp/email',
        headers := jsonb_build_object('api-key', k, 'Content-Type', 'application/json', 'accept', 'application/json'),
        body := jsonb_build_object(
          'sender', jsonb_build_object('name', 'NewsTrade', 'email', s),
          'to', jsonb_build_array(jsonb_build_object('email', r.email)),
          'subject', 'Starting soon: ' || r.title,
          'htmlContent', format(
            '<p>Hi %s,</p><p><b>%s</b> is at <b>%s</b> (%s time), in about %s minutes.</p>'
            '<p><a href="https://newstrade.github.io/Newstrade/">Open NewsTrade</a></p>'
            '<p style="color:#888;font-size:12px">You get this email because you starred this event and turned on email alerts. '
            'You can turn them off from your account in NewsTrade.</p>',
            replace(replace(r.name, '<', '&lt;'), '>', '&gt;'),
            replace(replace(r.title, '<', '&lt;'), '>', '&gt;'),
            to_char(r.at at time zone r.tz, 'HH24:MI'), r.tz,
            ceil(extract(epoch from (r.at - now())) / 60)::int)
        )
      );
    exception when others then
      null; -- skip one bad row (e.g. unknown time zone) instead of stopping all emails
    end;
    update public.event_alerts set sent_at = now() where user_id = r.user_id and event_id = r.event_id;
  end loop;
end $$;

revoke execute on function public.send_event_alert_emails() from public, anon, authenticated;

select cron.schedule('newstrade-email-alerts', '*/5 * * * *', 'select public.send_event_alert_emails()');
