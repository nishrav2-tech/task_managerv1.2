# Google Calendar setup

The CRM lets each teammate link their own Google Calendar from **Settings > Google Calendar**.
Their events show on the Dashboard calendar (only on their own view or Everyone), and dragging
one to another day moves it in Google. This needs one Google Cloud OAuth client for the workspace.

## 1. Google Cloud project

1. Go to https://console.cloud.google.com and create a project (for example "Utopian CRM").
2. **APIs & Services > Library**: search "Google Calendar API" and click **Enable**.

## 2. OAuth consent screen (Google Auth Platform)

1. **APIs & Services > OAuth consent screen** (or **Google Auth Platform > Branding**).
2. User type: **External** (or **Internal** if everyone uses the same Google Workspace domain).
3. App name: Utopian CRM. Support and developer email: yours.
4. **Data access / Scopes**: add
   - `.../auth/calendar.events`
   - `.../auth/calendar.calendarlist.readonly`
   - `openid`, `.../auth/userinfo.email`
5. **Audience**: click **Publish app** (move it to "In production").
   In "Testing" Google disconnects everyone every 7 days.
   Because it's not verified, people see "Google hasn't verified this app" the first time:
   click **Advanced > Go to Utopian CRM**. Fine for up to 100 users.

## 3. OAuth client

1. **APIs & Services > Credentials > Create credentials > OAuth client ID**.
2. Application type: **Web application**.
3. Authorized redirect URI:
   `https://yahosblylysopbxgztvg.supabase.co/functions/v1/gcal`
4. Create, then copy the **Client ID** and **Client secret**.

## 4. Save them on the server

Run in the Supabase SQL editor (or send them to Claude to do it):

```sql
insert into public.app_secrets(key, value) values
  ('GOOGLE_CLIENT_ID', '...apps.googleusercontent.com'),
  ('GOOGLE_CLIENT_SECRET', '...')
on conflict (key) do update set value = excluded.value;
```

They stay server-side only. Each person then presses **Connect Google Calendar** in Settings.

## How privacy works

- `public.gcal_connections` holds each person's Google token, keyed by their login. RLS is on with
  no policies, so no browser session (admins included) can read it; only the `gcal` Edge Function can.
- The function always acts on the signed-in caller's own connection, from their session token.
- Google events are never stored in the database, and the dashboard only draws them when the
  calendar is showing you or Everyone, never a teammate.
