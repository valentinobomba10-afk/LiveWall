# LiveWall — Changelog

All notable changes to LiveWall. Newest first.

## 1.6.12 — Copy movie links

- Added “Copy Google Drive Link” to every Drive movie card’s right-click menu.
- Added a visible “Copy Drive Link” button to the movie player.
- Downloaded movies retain and copy their original shareable Drive link.

## 1.6.11 — Download-first movie backgrounds

- Clicking an online movie now downloads a compatible local MP4 with visible progress and cancellation.
- Setting an online movie as the background downloads it first, then applies and loops the local copy automatically.
- Downloaded movies replace their online catalog card and remain available after restarting LiveWall.
- Resolve Drive's signed MP4 rendition instead of saving a webpage or an incompatible MKV original.
- Replaced the broken movie catalog with 81 verified previews from the selected Google Sites pages and Drive folders.
- Removed duplicate, private, and unavailable movie entries.

## 1.6.9 — Movie posters

- Added poster images to movie cards.
- Local MP4 files now generate a thumbnail automatically.
- Movie websites can be saved with an optional poster image URL.
- Fixed movie-card spacing so titles and source badges never overlap adjacent cards.
- Fixed Drive movies not starting when selected as a live background.
- Prevented Keychain session restore from freezing the app during launch.

## 1.6.8 — Movie cleanup

- Removed the bundled online movie portal and its special background player.
- Movies now supports user-added websites and imported local MP4 files only.
- Old saved portal wallpapers are no longer restored.

## 1.6.7 — Verified Movie Autoplay

- Replaced the fixed Drive catalog with the complete 1Flex movie portal.
- A selected 1Flex movie can be reopened as a live web background.
- 1Flex movies automatically start and resume embedded video playback.
- Added a verified VidFast autoplay fallback when 1Flex's provider service returns no usable player.
- Added fast title search to the Movies tab.
- Added a loading notice before opening large Drive movies.

## 1.3.1 — Community submissions

- **File uploads.** The Submit form now takes an actual video file (mp4 / mov /
  m4v / webm / mp3, up to 50 MB) as well as a pasted link. Files upload to a
  Supabase Storage bucket and submit their public URL for review.

## 1.3.0 — Profile & submission system

- **Profile page** — avatar, account, three stat tiles (Submissions / Approved /
  Favorites) and Submissions / Favorites / My Uploads tabs.
- **Submit a wallpaper** — signed-in users can submit wallpapers. Each one is
  held as *pending* and only goes public once approved.
- **Admin review tab** — a moderation queue with Approve / Reject, alongside the
  install stats, ban and featured-wallpaper tools. Visible only on the admin's
  Mac, or after the code word; useless without the local secret key.

## 1.2.0 — Light theme

- The whole app is now light: near-white canvas, light sidebar, dark text.
- Sidebar bottom cluster: **Profile · Feedback · Settings**.
- Text over wallpaper artwork and the floating player bar stay light, so nothing
  goes invisible against imagery.

## 1.1.1 — Accounts

- **Sign in / create account** backed by Supabase Auth, with a polished screen.
  Passwords go straight to Supabase; only session tokens are kept, in the
  Keychain.
- Account section in Settings with **Sign Out**.
- "Continue without an account" for people who'd rather not sign in.

## 1.0.3 — Stability

- Fixed a menu-bar status-item crash on login-launched instances.
- Launch-at-login is now opt-in (was forced on every start).
- Anonymous install counter wired to Supabase (a random ID, app version, macOS
  version — nothing personal; switch it off in Settings).

## 1.0.0 — Public release

- Removed the sign-up gate; the app opens straight into the wallpaper browser.
- In-app self-update: "Download Update" installs the new version and relaunches.
- Remote kill switch: a banned install stops running wallpapers.

## 0.6.x — Widgets polish

- **To-Do widget** — a desktop checklist with a live done/total count.
- Widgets are clickable and draggable on the desktop, sit above the wallpaper
  but below your windows, resize from corner handles, and snap to a grid.
- Fixed the double-click and photo-drag-freeze bugs; text scales to fit.

## 0.5.x — Widget system

- **Desktop widgets**: Clock, Image, App Launcher, Shortcut — placed on the
  desktop over the live wallpaper, each with themes (Glass, Minimal, Dark, Light,
  Transparent, macOS, Windows) and full styling controls.
- Widget Manager tab with enable/disable, duplicate, remove, and a gallery.
- **Secret Games unlock** — the Games section now unlocks by finding 10 hidden
  keys across the app, replacing the old Settings ten-click trick.
- Wallpaper detail pages that play the clip full-screen; hover-to-preview in the
  grid; the full MotionBGS catalogue with real categories; resizable window;
  Backdrop-style redesign.

---

*Versions between the milestones above (e.g. 0.5.5–0.5.9, 1.0.1–1.0.2, 1.3.0)
were incremental fixes rolled into the entries here.*
