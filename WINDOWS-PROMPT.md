# Prompt for the Windows Claude Code agent

Copy everything below the line into the other Claude Code session.

---

You are building **LiveWall for Windows 11** — a live-wallpaper and desktop-widget app. You are on a Windows PC, so you can actually compile, run, and test. Do that: never claim something works until you have run it and looked at it.

## What LiveWall is

An app that plays video as an animated desktop wallpaper — the video renders **behind the desktop icons**, so icons stay visible and clickable — plus a set of interactive desktop widgets that sit on top of that wallpaper. A macOS version already exists and is at v0.6.3; you are building the Windows equivalent with the same feature set and the same look.

**Be honest about what the app does.** On macOS it does not replace the system wallpaper — it draws a window at desktop level. On Windows, the equivalent is parenting your render window to `WorkerW` behind `Progman`'s icon layer. Never describe it as "changing the wallpaper" if it is drawing a window.

---

## Part 1 — Wallpaper engine

**Sources**
- Local video files (mp4/mov/webm)
- Direct video URLs
- Local images (static)
- YouTube (poster/thumbnail only — see restrictions below)
- Interactive web wallpapers (bundled HTML/WebGL rendered in a webview)

**Playback**
- Loop, mute, volume, and scaling mode (fill / fit / stretch)
- Brightness and saturation adjustment over the wallpaper
- Play / pause / stop
- Pointer position is forwarded to interactive wallpapers so they react to the mouse **without** the wallpaper stealing clicks from the desktop

**Multi-monitor**
- A **different** wallpaper per display, not one mirrored everywhere
- Hot-plug: connecting/disconnecting a monitor or changing resolution reconciles the windows without a restart

**Power and performance** (all user-configurable in Settings)
- Pause on battery
- Pause in battery-saver / low-power mode
- Pause when the screen is locked or asleep
- Pause when another app is fullscreen (games)
- Pause when the wallpaper is fully covered by windows (opt-in)
- Idle CPU/GPU use must be minimal — this is the single most important non-functional requirement

**Persistence**
- The current wallpaper (per display) is saved and restored on launch
- Optional launch-at-login

**Rotation / playlists**
- Rotate through a set of wallpapers on a timer (interval in minutes)

**Static fallback**
- When paused or not running, a still frame from the video is set as the actual desktop wallpaper so the look persists

---

## Part 2 — The app UI

The macOS version's UI is modelled on the **Backdrop** app (cindori.com/backdrop). Match this:

**Palette** — near-black with a plum cast. Canvas `#131016`, sidebar `#191320`. Flat surfaces, hairline separators (white at ~7%), colour reserved for selection and primary actions. Default system font, **not** a rounded font.

**Sidebar** (~216px, fixed)
- Navigation starts directly under the window controls — no wordmark, no logo
- Rows: Home, Library, Favorites, My Wallpapers, Playlists, Widgets
- Selected row: soft white fill at ~9%, 8px radius, accent-coloured icon and label
- Bottom cluster: a filled accent "Add Wallpaper" row, then Settings

**Toolbar** (top-right only)
- A "＋ Create" pill and a circular search button that expands into a field
- Nothing else lives up here — Settings is in the sidebar

**Home** — a full-bleed hero carousel with side arrows and page dots. Title at ~52px bold bottom-left over a spec line (resolution · category · source). Bottom-right: a Link pill, a favourite heart, and a filled accent "Set Wallpaper" button.

**Library** — a large page title, then **category sections**: a bold section header with "Show All ›" on the right, and a horizontally-scrolling row of cards beneath. Not a flat grid with filter chips. "Show All" drills into a flat grid of that category with a back control.

**Cards** — pure artwork, 12px radius, no border, no shadow, no caption underneath. Title and metadata fade in on hover over a bottom gradient. Hovering a card **plays its video preview in place**.

**Wallpaper detail page** — clicking a card opens its own page: the clip plays full-bleed, with a Back control in the toolbar, the title and specs bottom-left, and actions bottom-right.

**Floating player bar** — appears while a wallpaper is running: play/pause, stop, a thumbnail, then two lines showing which display and which wallpaper, and a displays icon.

**Other screens** — Favorites, My Wallpapers (user's own files, with an add tile), Playlists, Settings.

---

## Part 3 — Wallpaper catalogue

LiveWall pulls a catalogue from **motionbgs.com** by parsing its public tag pages.

- Walk **every** page of every tag until pages stop returning new items (cap at ~40 pages/tag as a safety stop)
- Carry the site's own tag through as the wallpaper's category (`car` → "Cars", `superhero` → "Superheroes", `tv` → "TV & Film"). Do **not** guess categories from the title — that was a bug in the macOS version
- Each entry has a small `-preview.mp4` next to the full 4K asset. Use the preview for hover previews and the detail page; only download the full asset when the user actually sets it
- Never open remote 4K video just to draw a grid thumbnail

---

## Part 4 — Desktop widgets

Widgets render in their own window layer **above** the wallpaper and are interactive.

**Widget types**
1. **Clock** — digital or analog face, 12/24-hour, optional seconds, optional date, any timezone, custom font and size
2. **Image** — any picture from disk, with fit / fill / stretch modes and an optional "open original on click"
3. **App Launcher** — pick any installed application, show its real system icon, click to launch; custom name and custom icon override; adjustable size
4. **Shortcut** — opens a website, file, folder, app or custom URL; system icon or custom icon; bare domains get `https://` prepended
5. **To-Do** — a checklist with a live done/total count; tick items on the desktop, edit the text in the app

**Styling** — every widget supports width, height, opacity, background transparency, blur, corner radius, border, shadow, font, text size, text alignment and padding. Seven presets: **Glass, Minimal, Dark, Light, Transparent, macOS-style, Windows-style**. Applying a preset changes the look but preserves hand-set text size, padding, alignment and opacity. Preset swatches render the real widget so they preview accurately.

**Interaction**
- Drag anywhere on the desktop, with snap-to-grid
- Resize by four corner handles that appear on hover; each resizes from its own corner. Resize freely while dragging and settle onto the grid on release
- Right-click menu: Edit, Duplicate, Lock Position, Bring Forward, Send Backward, Remove
- Lock disables both moving and resizing
- All text scales to fit its widget rather than clipping

**Widget Manager** — a Widgets tab listing every widget with an enable/disable switch, duplicate and delete buttons, a large "＋ Add Widget" button opening a gallery, plus Edit Mode and Snap-to-Grid toggles.

**Persistence** — position, size, settings, z-order and **which monitor** each widget belongs to, saved to disk and restored at launch. Saves are debounced, because dragging mutates state every frame.

### Four traps the macOS version hit — check the Windows equivalents

1. **Window level.** Widgets must sit above the wallpaper but **below normal application windows**, or they cover the user's work. On macOS the fix was desktop-icon level + 1. A pure desktop-level window could not receive clicks at all — the OS routed them to the file manager. Find the Windows layer that is both below normal windows and still clickable.
2. **First click swallowed.** The widget window is never the focused window, so the OS spent the first click focusing it and discarded it — every widget needed clicking twice. On macOS the fix was `acceptsFirstMouse`. Find the Windows equivalent.
3. **Images decoded every frame.** Image loading was called from the view body, which re-evaluates on every frame of a drag — dragging a photo widget froze the app. Cache decoded images and icons.
4. **Video composited over everything.** The video view was a native view inside the UI framework, so it painted over sibling UI elements regardless of z-order. Anything you overlay on a playing wallpaper needs its own explicitly ordered layer.

---

## Part 5 — Games section and the key hunt

There is a hidden Games section (bundled HTML games in a webview). It is **locked** until the user finds **10 hidden key icons** scattered through the UI:

- 7 on specific wallpaper detail pages — pin these to specific wallpapers **by name**, not by list index
- 1 in Settings
- 1 in the Check for Updates dialog
- 1 on the Home screen

Clicking a key animates it away and shows "🔑 You found a key! / Key collected — n/10" with ten progress pips. The tenth shows "🔓 GAMES UNLOCKED!" and reveals the Games tab.

Progress persists between launches. A key can never be collected twice. Keys must render **above** the wallpaper video (see trap 4).

---

## Part 6 — Settings, updates, misc

- Settings: launch at login, all the pause policies, rotation interval, update notifications, download folder and a "clear downloaded wallpapers" action with a storage total
- Update check against a GitHub releases feed, with a "download update" action
- A first-run profile screen (name + email, stored locally — **never** store a password)
- Closing the main window keeps the wallpaper running; only explicit Quit stops it
- A tray/menu-bar item for quick play/pause/quit

---

## Hard rules

- **Never** download YouTube video or audio, and never bypass ads, DRM, login walls, age gates, region locks, private-video checks or embedding restrictions. YouTube support is poster images and official embeds only.
- Never claim the app replaces the native system wallpaper when it is drawing a window.
- Do not fabricate test results. If you have not run it, say so.

---

## Your first task

**Before writing any code**, read this whole document and reply with:

1. Your plan for the Windows wallpaper layer (`WorkerW`/`Progman`) and the widget layer, including how you will solve traps 1 and 2 above.
2. Your choice of stack (WinUI 3, WPF, Electron, something else) and why, given the low-idle-CPU requirement.
3. **Anything in this document that is missing, ambiguous, or that you think should work differently on Windows.** Ask about it rather than guessing — and if you spot a feature that a Windows user would expect but that is not listed here because macOS has no equivalent, say so and propose it.

Then build it in vertical slices — get one wallpaper playing behind the icons before you build the whole library UI.
