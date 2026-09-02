# LiveWall — Changelog

All notable changes to LiveWall. Newest first.

## 2.0.0 — New interface

The interface has been rebuilt from scratch. The old `BrowseView` UI is deleted, not restyled — LiveWall now renders an entirely new UI layer (`LiveWallUI.swift`) built on one design system. All wallpaper, widget, movie, game and account functionality is unchanged.

- **New design system** — frosted glass panels, soft grey/white surfaces, thin borders, 18px cards, Apple-style spacing, blue→purple accents.
- **New sidebar** — LiveWall logo, then Home / Wallpapers / Widgets / Favorites / Discover, a divider, then My Setups / Settings. The selected row gets a soft rounded highlight.
- **New Home** — a large Current Wallpaper card (LIVE + resolution badges, name, type, Preview / Set Wallpaper / Apply), a widgets panel on the right, Recent Wallpapers along the bottom-left, and a Quick Actions 2×2 grid bottom-right.
- **Every page rebuilt** on the same system: Wallpapers, Wallpaper Detail, Widgets, Favorites, Discover, My Setups, Settings, Movies and Games.
- Fixed the Home layout collapsing on wide and full-screen windows — the hero card sized itself from the scroll view's unbounded height and pushed the widgets panel off-screen.

## 1.9.0 — Complete UI rebuild

The interface has been rebuilt from the ground up to match the LiveWall design.

- **New window shell** — a real macOS unified toolbar across the top: space for the traffic lights, one centred "Search wallpapers, widgets…" field, and your account avatar. The old floating pill controls are gone.
- **New sidebar** — brand lockup, the seven primary sections (Home, Wallpapers, Widgets, Favorites, Discover, My Setups, Settings), a quiet Library group underneath, and the LiveWall Pro card pinned to the bottom.
- **Home is a true dashboard** — a large wallpaper preview card on the left with Recent Wallpapers under it, and a widgets panel on the right with Quick Actions below. Exactly the reference layout.
- **Real widgets, not mockup filler** — a live analog clock, live rotation status, and an app launcher that shows your Mac's actual app icons and really opens them.
- **Discover is its own page** now, instead of a grid bolted under Home.

## 1.8.0 — New design

- Redesigned around a new visual system: violet-biased neutrals, a blue→purple accent, glass cards and 16px radii.
- **Home is now a dashboard** — the current wallpaper as a hero card with LIVE/resolution badges and Preview / Set Wallpaper / Apply, a Recent Wallpapers rail, and a right-hand rail.
- Added a **live analog clock** and a **rotation status** widget to the Home rail.
- Added **Quick Actions**: Shuffle Wallpaper, Auto Change, Import Wallpaper, Create Setup.
- Sidebar now carries the LiveWall brand mark, and the Add Wallpaper button uses the accent gradient.

## 1.7.11 — Hard keys guaranteed visible

- The 5 hard keys now sit on a **dark circular chip** (black disc + white outline) so they stay clearly visible over any wallpaper, no matter how bright or busy. Still small, still no glow/pulse, still in odd corners — but you can always see them.

## 1.7.10 — Make the hard keys visible

- The 5 hard keys were too faint to see. They're now clearly visible (dimmer than the easy ones, with a soft dark halo so they read over bright art) and a bit larger — still no glow/pulse and still in odd corners, so they're harder but findable.

## 1.7.9 — 15 keys, five of them brutal

- Bumped the key hunt from 10 to **15 keys**.
- The last **5 keys are hard**: hidden on busier character/anime-style wallpapers (Sunset Samurai, Cyber Streets Reign, The Witcher's Path, Ghost of Night City, Neon Iron Man), tucked into obscure edges/corners, dim and non-pulsing — you have to sweep your cursor to find them.

## 1.7.8 — Real full-screen games

- Games now open as a full-window view instead of a floating sheet, so the **Full Screen** button (⌃⌘F) makes the game truly fill the whole display.

## 1.7.7 — All keys on wallpapers

- Moved the Settings, Home, and update-popup keys onto wallpaper pages, so all ten hidden keys now live on wallpapers (bottom-right of each). Added Mist Over the Pines, Night Sky, and Cosmic Mountain OLED as the three new keyed wallpapers.

## 1.7.6 — Fix Discover grid layout

- Fixed the Home/Discover grid where wallpaper cards rendered oversized and overlapped each other. Each card is now a clean 16:9 tile locked to its column.

## 1.7.5 — Game tabs & working auto-update

- Games now open in a **browser-style tabbed view** — open several at once, switch between them without reloading, close individual tabs. No address bar, just the game.
- **Fixed auto-update:** LiveWall now checks for a newer version automatically at launch (it silently defaulted to off before). Toggle it in Settings › App updates.
- Clarified the update setting label and added an explanation.

## 1.7.4 — Full-screen games & easier keys

- Added a **Full Screen** button to every game (⌃⌘F), with an Exit Full Screen toggle.
- Made the ten hidden keys easier to spot: brighter, with a gentle glow pulse.
- Added a keys-progress hint in the sidebar once you've found your first key, showing how many remain and where to look.
- The update-popup key now also appears when you're already up to date, so it's always reachable.
- Enlarged the Settings and update-popup keys so they're simpler to find.

## 1.7.3 — Skate wallpapers

- Added a dedicated Skate category with 15 live DesktopHut wallpapers.
- Added verified direct MP4 downloads and lightweight poster images for every Skate card.
- Excluded the phone-shaped result so all included wallpapers fit desktop displays.

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
