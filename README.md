# LiveWall

Animated video wallpapers for macOS — play local videos, direct video URLs, and YouTube videos or livestreams on your desktop, across one or more displays.

> **How it works (honest version):** macOS has no public API to set a continuously playing video as the actual system wallpaper. LiveWall instead draws your video in a **desktop-level overlay window** placed behind your app windows and desktop icons. It does **not** replace the macOS system wallpaper, and it uses **no private APIs**.

---

## Contents
- [Installation](#installation)
- [Supported macOS versions](#supported-macos-versions)
- [Apple Silicon & Intel support](#apple-silicon--intel-support)
- [Adding a local video](#adding-a-local-video)
- [Using a YouTube link](#using-a-youtube-link)
- [Multi-monitor support](#multi-monitor-support)
- [Performance settings](#performance-settings)
- [Known limitations](#known-limitations)
- [Troubleshooting](#troubleshooting)
- [Privacy](#privacy)
- [For developers](#for-developers)

---

## Installation

**From the notarized DMG (recommended):**
1. Download `LiveWall.dmg`.
2. Open it and drag **LiveWall** to your Applications folder.
3. Launch LiveWall. It appears as a menu-bar icon (no Dock icon by default).
4. First launch: because LiveWall is signed with a Developer ID and notarized by Apple, it opens normally. If Gatekeeper still prompts, right-click the app ▸ **Open** once.

**Enable "Launch at login"** in LiveWall ▸ Settings ▸ General if you want your wallpaper to start automatically. macOS may ask you to approve it under **System Settings ▸ General ▸ Login Items**.

---

## Supported macOS versions
- **Minimum:** macOS 13 Ventura
- **Recommended:** macOS 14 Sonoma or later

(macOS 13+ is required for the modern login-item and menu-bar APIs LiveWall uses.)

---

## Apple Silicon & Intel support
LiveWall ships as a **Universal 2** binary and runs natively on:
- **Apple Silicon** (M-series) Macs — recommended for the best energy efficiency (hardware video decode).
- **Intel** Macs — supported; expect somewhat higher CPU/energy use on older machines. Tune with the [performance settings](#performance-settings).

---

## Adding a local video
1. Open LiveWall from the menu bar ▸ **Open LiveWall…**
2. Click **Add Wallpaper ▸ Choose Local Video…** and pick a file (`.mp4`, `.m4v`, `.mov`; H.264 or HEVC recommended).
3. Pick which **display(s)** to use and a **fill mode** (Fill / Fit / Stretch / Centre).
4. Click **Set Wallpaper**. Use the controls to Play/Pause, toggle **Loop**, and adjust **Volume/Mute**.

Your video is added to the **Library** for one-click reuse later. LiveWall remembers where the file is (it does not copy or move it). If you move or delete the original file, LiveWall will tell you it can't find it.

You can also add a **direct video URL** (a link ending in `.mp4`/`.mov`, or an HLS `.m3u8` stream) in the same **Add Wallpaper** sheet.

---

## Using a YouTube link
1. Menu bar ▸ **Open LiveWall…** ▸ **Add Wallpaper**, then paste a YouTube URL in the URL field.
2. Works with normal videos (`youtube.com/watch?v=…`, `youtu.be/…`) and **livestreams** (`youtube.com/live/…`).
3. **Set Wallpaper.**

YouTube playback uses YouTube's **official embedded player**. LiveWall does **not** download videos, remove or skip ads, or bypass any restrictions.

Some videos can't be used as a wallpaper — LiveWall will tell you when:
- the owner disabled playback on other sites (embedding off),
- the video is **private** or has been **removed**,
- it's **age-restricted** or **region-blocked**.

**Sound note:** wallpapers start **muted**. YouTube (like web browsers) only allows automatic playback when muted. To hear audio, unmute in the controls; you may need to open the LiveWall window once for the first unmute to take effect.

---

## Multi-monitor support
- Choose **All Displays**, **Main Display**, or specific displays in the display selector.
- With multiple displays selected, LiveWall runs one wallpaper per screen.
- **Hot-plug aware:** connect a display and the wallpaper extends to it automatically; disconnect one and LiveWall cleans it up. Changing resolution or rearranging displays repositions everything.

---

## Performance settings
LiveWall is designed to stay light and to get out of the way when you're not looking at it.

In **Settings ▸ Power** and **Settings ▸ Playback**:
- **Pause when another app is fullscreen** — stops playback while you're in a fullscreen app.
- **Pause on battery power** — saves energy on the go.
- **Pause in Low Power Mode.**
- **Mute by default.**
- **Video quality** — `Auto` recommended.
- **Frame-rate limit** — 24/30/60 fps or Unlimited (a hint; see limitations).

LiveWall **also pauses automatically** when the wallpaper is fully covered by another window, when the display sleeps, and when the screen is locked — you don't need to configure those.

---

## Known limitations
- **Not the native wallpaper.** LiveWall renders a desktop-level overlay; it does not change the macOS system wallpaper, and (by design) your desktop icons stay on top of the video.
- **macOS controls the desktop layer.** Desktop icons, Mission Control, Spaces, **Stage Manager**, fullscreen apps, the Dock, and sleep/lock transitions are all managed by macOS. LiveWall's overlay is best-effort and may be temporarily hidden, reordered, or replaced during those system transitions. LiveWall uses no private APIs and does not promise persistence through them.
- **YouTube:** no downloading, ad-skipping, or bypassing of DRM/age/region/private restrictions — by design. Videos that block embedding can't be used.
- **YouTube audio autoplay** is blocked until you interact (unmute manually).
- **Frame-rate limit / video quality** are best-effort hints. LiveWall doesn't manipulate video streams; local video plays at the file's own frame rate, and YouTube may ignore quality hints.
- **"Pause when another app is fullscreen"** uses a best-effort heuristic and may occasionally not detect every case; the occlusion-based auto-pause still covers most situations.

---

## Troubleshooting

| Problem | Try this |
| --- | --- |
| Wallpaper not visible | Make sure a wallpaper is **Set** and playing; check the display selector; if a fullscreen/maximized app is covering it, that display auto-pauses by design. |
| Desktop icons disappeared | LiveWall keeps icons on top by default; if you enabled "hide desktop icons," turn it off in Settings. |
| Can't click desktop icons | LiveWall is click-through by default. If clicks aren't reaching the desktop, restart LiveWall. |
| "Video unavailable" (YouTube) | The video is private/removed, or embedding is disabled by the owner. Try another video. |
| "Embedding not allowed" | The owner disabled off-site playback, or it's age/region restricted. Try another video. |
| "No internet connection" | YouTube and remote URLs need a connection; local videos work offline. |
| "File not found" | The original local file was moved or deleted — re-add it. |
| High CPU/energy on Intel | Lower the frame-rate limit, use a smaller/H.264 video, enable pause-on-battery. |
| Won't launch at login | Approve LiveWall in **System Settings ▸ General ▸ Login Items**. |
| Wallpaper doesn't return after sleep | It should resume automatically; if not, open LiveWall and press Play. |

---

## Privacy
LiveWall has no accounts, analytics, or telemetry. Local videos never leave your Mac. YouTube plays through the official embedded player with a non-persistent web session (no YouTube cookies stored). See the in-app **About** page for details.

---

## For developers

Architecture and engineering specs live in [`SPEC.md`](SPEC.md) and [`docs/`](docs/). Target macOS 13+, Universal 2 (`arm64` + `x86_64`).

**Build & run:**
```bash
# Option A — Swift Package Manager (fastest for iterating on logic)
swift build
swift run LiveWall

# Option B — generate an Xcode app project (for signing, entitlements, app bundle)
xcodegen generate   # reads project.yml
open LiveWall.xcodeproj
```

Start with [`docs/implementation-plan.md`](docs/implementation-plan.md), and self-check every change against [`docs/code-review-checklist.md`](docs/code-review-checklist.md). The current review of the initial skeleton is in [`docs/review-001-initial-skeleton.md`](docs/review-001-initial-skeleton.md).
