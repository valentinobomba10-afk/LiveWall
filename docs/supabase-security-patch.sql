-- LiveWall — SECURITY PATCH. Run this in the Supabase SQL Editor now.
--
-- The first schema gave the public (publishable) key blanket SELECT and UPDATE
-- on public.installs via `using (true)`. That key ships inside the app, so any
-- user could read every install row, ban anybody, and push an arbitrary
-- wallpaper URL to anybody. Verified against the live project.
--
-- Fix: the public key keeps only what the app genuinely needs — register/refresh
-- its own heartbeat — and loses the ability to read the table or touch the
-- admin-controlled columns. Reading your own status now goes through a
-- security-definer function that returns exactly one row.

-- 1. Drop the over-permissive policies -------------------------------------
drop policy if exists "installs read own"   on public.installs;
drop policy if exists "installs update own" on public.installs;
drop policy if exists "installs insert"     on public.installs;

-- 2. Insert stays open (an install must be able to register itself) ---------
create policy "installs insert" on public.installs
    for insert to anon, authenticated with check (true);

-- 3. Update allowed, but only the heartbeat columns -------------------------
--    RLS can't restrict columns, so use column-level GRANTs for that.
create policy "installs heartbeat update" on public.installs
    for update to anon, authenticated using (true) with check (true);

revoke update on public.installs from anon, authenticated;
grant  update (install_id, app_version, os_version, last_seen)
    on public.installs to anon, authenticated;

-- 4. No direct reads for the public key ------------------------------------
revoke select on public.installs from anon, authenticated;

-- 5. One-row status lookup, by exact install id ----------------------------
--    SECURITY DEFINER so it can read the table the caller cannot.
create or replace function public.install_status(p_install_id text)
returns table (banned boolean, games_granted boolean, push_wallpaper text)
language sql
security definer
set search_path = public
as $$
    select i.banned, i.games_granted, i.push_wallpaper
    from public.installs i
    where i.install_id = p_install_id
    limit 1;
$$;

revoke all on function public.install_status(text) from public;
grant execute on function public.install_status(text) to anon, authenticated;

-- 6. Tidy up the leftover self-test row ------------------------------------
delete from public.installs where install_id = 'livewall-selftest-0001';

-- The admin console uses the SECRET (service_role) key from
-- ~/.livewall-admin/config.json, which bypasses RLS, so ban / grant-games /
-- push-wallpaper keep working there — and only there.
