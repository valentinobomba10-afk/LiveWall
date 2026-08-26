# Install counter — Supabase setup

Ten minutes, free tier, no card.

## 1. Create the project

1. Go to **supabase.com** → New project (free tier).
2. Wait for it to finish provisioning.
3. **Settings → API**, and copy two values:
   - **Project URL** — `https://xxxxxxxx.supabase.co`
   - **anon / public key** — the long `eyJ…` string

The anon key is *designed* to be shipped in a client app. It is not a secret. The
policy below is what actually protects the data.

## 2. Create the table

**SQL Editor → New query**, paste this, Run:

```sql
create table public.installs (
  install_id  uuid primary key,
  app_version text,
  os_version  text,
  first_seen  timestamptz default now(),
  last_seen   timestamptz default now()
);

alter table public.installs enable row level security;

-- Anyone running LiveWall may add or refresh their own row…
create policy "app can upsert installs"
  on public.installs for insert
  to anon
  with check (true);

create policy "app can update own row"
  on public.installs for update
  to anon
  using (true)
  with check (true);

-- …but nobody can read the table with the public key.
-- You read it from the Supabase dashboard, which uses your own credentials.
```

That last part matters: **inserts are allowed, reads are not.** Without it, anyone
who opened your app bundle could pull the whole table.

## 3. Put the keys in the app

In `Analytics.swift`:

```swift
static let supabaseURL     = "https://xxxxxxxx.supabase.co"
static let supabaseAnonKey = "eyJ..."
```

Both are empty by default, and analytics is a no-op while they are — so the
current 1.0.0 build sends nothing at all.

## 4. Read your numbers

**SQL Editor**, any time:

```sql
-- Total installs
select count(*) from installs;

-- Active in the last 30 days
select count(*) from installs where last_seen > now() - interval '30 days';

-- New installs per day
select date(first_seen) as day, count(*)
from installs group by day order by day desc;

-- Which versions people are actually on
select app_version, count(*) from installs group by app_version order by 2 desc;

-- macOS versions, for deciding what to support
select os_version, count(*) from installs group by os_version order by 2 desc;
```

## What gets sent

Exactly three things, once per launch:

| Field | Example | Why |
|---|---|---|
| `install_id` | random UUID | counts installs; identifies a copy of the app, not a person |
| `app_version` | `1.0.0` | shows whether people update |
| `os_version` | `27.0` | tells you which macOS versions to support |

Not sent: name, email, IP (beyond ordinary network routing), file paths,
wallpaper names, widget contents, usage patterns, anything typed into the app.

Users can switch it off in **Settings → Share anonymous usage stats**.

## Free tier limits

500 MB database, 50,000 monthly active users. Each row is about 100 bytes, so
500 MB is roughly five million installs. You will not hit this.

## Say so publicly

Put a line in your README and app description:

> LiveWall records an anonymous install count (a random ID, the app version and
> your macOS version). No personal data. You can turn it off in Settings.

Free apps that phone home quietly get called spyware. Free apps that say what
they send do not.

---

# Admin console

Type **`valentino2027games`** into the search field to open it. It shows total
installs, active-in-30-days, a version breakdown, a per-install ban button, and
a featured-wallpaper broadcast box.

## Why it's safe to ship in the public app

The console needs the Supabase **secret** key, which can never be compiled into
an app given to strangers. So it is **not** in the app. It is read at runtime
from a file that only exists on your Mac:

`~/.livewall-admin/config.json`

```json
{
  "url": "https://YOURPROJECT.supabase.co",
  "secret": "sb_secret_xxxxxxxx"
}
```

On your laptop → the file is there → the console works. On anyone else's Mac →
no file → the same code word opens a panel that says "Admin unavailable" and can
do nothing. Nothing sensitive ships.

Create it once:

```bash
mkdir -p ~/.livewall-admin
cat > ~/.livewall-admin/config.json <<'JSON'
{ "url": "https://YOURPROJECT.supabase.co", "secret": "sb_secret_xxxx" }
JSON
chmod 600 ~/.livewall-admin/config.json
```

Use a **freshly rotated** secret key here — not one that has been pasted into a
chat or anywhere else.

## Extra tables for ban + broadcast

Run alongside the `installs` table:

```sql
-- Ban flag lives on installs. Let an install read its own banned state.
alter table public.installs add column if not exists banned boolean default false;

create policy "app reads own row"
  on public.installs for select
  to anon
  using (true);   -- only ever queried filtered by the caller's own install_id

-- Featured wallpaper broadcast, one row, world-readable.
create table if not exists public.broadcast (
  id int primary key default 1,
  wallpaper_url text,
  updated_at timestamptz default now()
);
alter table public.broadcast enable row level security;
create policy "anyone reads broadcast" on public.broadcast for select to anon using (true);
```

## On banning and remote wallpaper — what this does and doesn't do

- **Ban** disables *your own app* on a specific install. That is a legitimate
  kill switch for abuse. The banned Mac's LiveWall stops running wallpapers; it
  does nothing else to that computer.
- **Featured wallpaper** broadcasts a suggested wallpaper to installs. It is a
  content push, the same idea as a "wallpaper of the week."
- It is **not**, and will not be built as, covert control of a named person's
  computer. Silently taking over one individual's screen is how an app gets
  labelled malware and pulled. If that was the goal, it is out of scope.

---

# Community submissions

Users submit wallpapers (a title + a direct video URL); they land as **pending**
and appear publicly only after you approve them in the **Admin** tab.

## Table + policies (run in SQL Editor)

```sql
create table public.submissions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id),
  user_email text,
  title text not null,
  wallpaper_url text not null,
  thumbnail_url text,
  status text not null default 'pending',   -- pending | approved | rejected
  created_at timestamptz default now(),
  reviewed_at timestamptz
);
alter table public.submissions enable row level security;

-- A signed-in user may submit, but only as themselves.
create policy "submit own" on public.submissions for insert to authenticated
  with check (auth.uid() = user_id);

-- A user can see their own submissions (any status)…
create policy "read own" on public.submissions for select to authenticated
  using (auth.uid() = user_id);

-- …and everyone can see approved ones.
create policy "read approved" on public.submissions for select to anon, authenticated
  using (status = 'approved');

-- Approve/reject happens in the Admin tab using the secret key, which bypasses
-- RLS — so no update policy for regular users is needed (that's deliberate).
```

## The flow

1. A signed-in user opens **Profile → Submit Wallpaper**, pastes a title + video URL.
2. It's stored `pending`. They see it under Profile → Submissions with a "Pending" badge.
3. You open the **Admin** tab (type `valentino2027games`, or it's always there on your Mac) → **Pending submissions** → Approve or Reject.
4. Approved wallpapers become readable by everyone.

## Uploading actual video files (later)

This MVP takes a **URL**, not a file. Hosting user-uploaded video needs a
Supabase **Storage** bucket + upload flow — a bigger piece. Say the word and it
can be added; the submission table already has a `wallpaper_url` that a Storage
public URL slots straight into.

## Uploading actual files (Storage bucket)

The Submit form now has an **Upload File** mode (mp4 / mov / m4v / webm / mp3,
≤ 50 MB). It uploads to a Supabase Storage bucket, then submits the file's public
URL for review. Set it up once:

1. Supabase → **Storage → New bucket** → name it `wallpapers` → tick **Public bucket** → Save.
2. Storage → Policies → run in SQL Editor:

```sql
-- Signed-in users may upload into the wallpapers bucket.
create policy "authenticated upload wallpapers"
on storage.objects for insert to authenticated
with check (bucket_id = 'wallpapers');
```

Public buckets are world-readable automatically, so approved wallpapers play for
everyone. Files land under `wallpapers/<user-id>/<uuid>.<ext>`.

**On size:** the free tier gives 1 GB of Storage total, and big 4K clips are
large — that's why uploads are capped at 50 MB here. For a real community library
you'd raise the cap and move to a paid Storage tier or a CDN.
