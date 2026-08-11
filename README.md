# Utopian CRM

A single-file HTML CRM for land investing operations. Tracks properties (with ARV / offer / margin), tasks with multi-user assignment, and a projects board for business improvements.

Works entirely offline in `localStorage`, or synced across the team via **Supabase** — flip between them by dropping in a `config.js`.

```
┌─ index.html         ← the whole app (HTML + CSS + JS inline)
├─ config.example.js  ← copy to config.js to enable Supabase
├─ schema.sql         ← run this once in your Supabase SQL Editor
├─ .gitignore         ← ignores config.js (never commit real credentials)
├─ LICENSE            ← MIT
└─ README.md
```

## Quick start (local, no database)

Just open `index.html` in a browser. Seed data appears on first load. Data persists in `localStorage` on that device.

```bash
# Or serve it
python3 -m http.server 8000
# → http://localhost:8000
```

The sidebar badge reads **Local**. Everything works, but data doesn't sync between devices or team members.

---

## Full setup with Supabase (recommended for teams)

### 1. Create a Supabase project

Go to [supabase.com](https://supabase.com), create a new project. Save the database password somewhere safe (you won't need it for the app, but Supabase will ask again later).

### 2. Run the schema

In the Supabase dashboard → **SQL Editor** → New query → paste all of `schema.sql` → Run.

You should see all 4 tables (`users`, `properties`, `tasks`, `projects`) appear under **Table Editor**.

### 3. Grab your API credentials

Supabase dashboard → **Project Settings** → **API**. Copy:
- **Project URL** (looks like `https://abcxyz.supabase.co`)
- **Project API key** → **anon / public** (a long string starting with `eyJ...`)

### 4. Wire up config.js

```bash
cp config.example.js config.js
```

Edit `config.js` and paste in both values:

```js
window.CRM_CONFIG = {
  supabaseUrl: 'https://abcxyz.supabase.co',
  supabaseKey: 'eyJhbGciOi...'
};
```

### 5. Refresh

Open `index.html`. The sidebar badge should now read **Supabase** (green dot). Everything you add, edit, or delete syncs live.

To confirm it's really syncing: add a task, then open the app on another device or browser — it appears immediately.

---

## Push to GitHub

```bash
cd utopian-crm
git init
git add .
git commit -m "Initial commit: Utopian CRM"

# Create the repo on github.com first, then:
git remote add origin git@github.com:YOUR-USERNAME/utopian-crm.git
git branch -M main
git push -u origin main
```

**Note:** `config.js` is gitignored — your Supabase credentials won't be committed. Every team member (or deploy environment) creates their own from `config.example.js`.

---

## Deploy to hosting

Any static host works. The whole app is `index.html` + `config.js` — no build step, no server.

### Netlify

```bash
# One-shot manual deploy: drag the folder onto app.netlify.com/drop
# Or connect the GitHub repo for auto-deploy on push:
```

1. Netlify → Add new site → Import from Git → pick your repo
2. Build command: *(leave blank)*
3. Publish directory: `/`
4. **Important:** Add `config.js` via *Site settings → Build & deploy → Environment* isn't quite right for a static file — instead, either:
   - Commit a production `config.js` to a *private* repo, OR
   - Use the Netlify UI to add a `_headers` file and inject credentials via a build script

Simplest path for a private team: keep the repo private and commit `config.js` (removing it from `.gitignore` in that private repo).

### Vercel

```bash
npm i -g vercel
vercel deploy
```

Same story — commit `config.js` in a private repo, or use a Vercel build step to write it from env vars.

### GitHub Pages

Push to `main`, then in the repo → **Settings → Pages → Source: main / (root)**. Same caveat about `config.js`.

### Cloudflare Pages, AWS S3, DigitalOcean Spaces, etc.

Static file. Upload the folder. Done.

---

## Row Level Security (important)

The `schema.sql` sets up permissive RLS policies — anyone with your anon key can read and write all data. For a small internal team using a private URL, this is fine. For anything more sensitive:

1. Enable **Supabase Auth** in the dashboard
2. Add a login screen in the app (see the [Supabase JS auth docs](https://supabase.com/docs/reference/javascript/auth-signinwithpassword))
3. Rewrite the RLS policies to key off `auth.uid()`

Ping me when you're ready to add real auth — it's a targeted change to the storage adapter and a new login screen.

---

## What's inside

- **Dashboard** — a "Create Task" button front and center, equity produced, KPIs, today's agenda, your open task list, monthly calendar
- **Properties** — deals tracked by Property ID (county/state, acres, buy/sell price, closing date), auto-computed margin
- **Tasks** — multi-assignee, priorities (high/medium/low), statuses (todo/in-progress/done/blocked), due dates, linkable to properties
- **Projects** — kanban board for business improvements (Marketing, SOPs, Tools, Team, Finance, Other) × 4 statuses (ideas/planned/in-progress/done)
- **Activity Log** — month calendar (jump to any past month via the dropdowns or prev/next, your position is remembered) of daily call logging (calls made, conversations held, offers made, offers accepted, not interested/dropped) and campaign logging (any number of campaign touches per day, with channel, counties hit, leads generated); an "Activity trends" chart lets you compare up to two metrics (calls made, calls picked up, offers made, rejected leads, campaigns sent, SMS sent) over a selectable time period
- **Team** — add/edit members with color-coded avatars, role labels
- **Settings** — backend status, JSON export/import, reset

## Architecture

The `StorageAdapter` object in `index.html` handles both backends behind one interface:

| Method | localStorage | Supabase |
|---|---|---|
| `loadAll()` | reads all JSON blobs | `.select('*')` on all 4 tables |
| `saveEntity(kind, e)` | mutates array in one key | `.upsert()` one row |
| `deleteEntity(kind, id)` | filters array | `.delete().eq('id', id)` |
| `saveBulk(data)` | writes all keys | ordered upserts (users first for FK) |
| `wipeAll()` | clears all keys | ordered deletes (reverse FK order) |

The adapter picks its backend at boot via `StorageAdapter.init()`. No other code has to know which one is active.

## Data backup

Even with Supabase, take a JSON snapshot occasionally:

**Settings → Export JSON** → downloads a full backup.
**Settings → Import JSON** → restores it (overwrites current data).

Useful before schema changes, big imports, or team handoffs.

## Roadmap ideas

Things we've discussed but haven't built:

- File uploads on properties (Supabase Storage)
- Email/SMS templates with merge fields
- Property map view (county heatmap)
- Reporting: closed deal profit, campaign source ROI, team performance
- Real authentication (Supabase Auth) with per-user RLS

Open an issue in the repo — or start a new Claude chat with "continue the Utopian CRM."
