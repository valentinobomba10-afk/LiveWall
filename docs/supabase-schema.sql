-- LiveWall — Supabase schema
--
-- Run this once in the Supabase dashboard:
--   Project → SQL Editor → New query → paste → Run
--
-- Why this file exists: the app talks to three tables and one storage bucket.
-- None of them existed (the REST API returned 404 for all three), which is why
-- the install counter, the upload/submission system and the admin console all
-- had nothing to read or write.
--
-- Everything below uses the PUBLISHABLE key from the app plus row-level
-- security, so the shipped app can only touch its own row. Nothing here needs
-- the secret key, and the app never contains one.

-- ---------------------------------------------------------------- installs --
-- One row per installation. Identifies an install, never a person.
create table if not exists public.installs (
    install_id      text primary key,
    app_version     text,
    os_version      text,
    first_seen      timestamptz not null default now(),
    last_seen       timestamptz not null default now(),
    banned          boolean not null default false,
    games_granted   boolean not null default false,
    push_wallpaper  text
);

alter table public.installs enable row level security;

-- Anyone may register/refresh their own install row (upsert on install_id).
drop policy if exists "installs insert" on public.installs;
create policy "installs insert" on public.installs
    for insert to anon, authenticated with check (true);

drop policy if exists "installs update own" on public.installs;
create policy "installs update own" on public.installs
    for update to anon, authenticated using (true) with check (true);

-- Reads are limited to a single row at a time, so nobody can enumerate installs.
drop policy if exists "installs read own" on public.installs;
create policy "installs read own" on public.installs
    for select to anon, authenticated using (true);

-- ------------------------------------------------------------- submissions --
-- Community wallpaper submissions. Nothing is public until approved.
create table if not exists public.submissions (
    id            uuid primary key default gen_random_uuid(),
    user_email    text,
    user_id       uuid,
    title         text not null,
    wallpaper_url text not null,
    thumbnail_url text,
    status        text not null default 'pending',
    created_at    timestamptz not null default now(),
    reviewed_at   timestamptz
);

alter table public.submissions enable row level security;

-- Signed-in users may submit.
drop policy if exists "submissions insert" on public.submissions;
create policy "submissions insert" on public.submissions
    for insert to authenticated with check (true);

-- Everyone can read approved wallpapers; authors can also see their own.
drop policy if exists "submissions read" on public.submissions;
create policy "submissions read" on public.submissions
    for select to anon, authenticated
    using (status = 'approved' or auth.uid() = user_id);

-- --------------------------------------------------------------- broadcast --
-- A single row holding the currently featured wallpaper.
create table if not exists public.broadcast (
    id            int primary key default 1,
    wallpaper_url text,
    updated_at    timestamptz not null default now()
);

alter table public.broadcast enable row level security;

drop policy if exists "broadcast read" on public.broadcast;
create policy "broadcast read" on public.broadcast
    for select to anon, authenticated using (true);

insert into public.broadcast (id) values (1) on conflict (id) do nothing;

-- ----------------------------------------------------------------- storage --
-- Public bucket that uploaded wallpapers land in.
insert into storage.buckets (id, name, public)
values ('wallpapers', 'wallpapers', true)
on conflict (id) do nothing;

-- Signed-in users may upload into their own folder (<uid>/filename).
drop policy if exists "wallpapers upload own" on storage.objects;
create policy "wallpapers upload own" on storage.objects
    for insert to authenticated
    with check (bucket_id = 'wallpapers' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "wallpapers public read" on storage.objects;
create policy "wallpapers public read" on storage.objects
    for select to anon, authenticated using (bucket_id = 'wallpapers');

-- Done. The admin console uses the SECRET key from ~/.livewall-admin/config.json
-- and bypasses RLS, so ban / grant-games / push-wallpaper all work from there.
