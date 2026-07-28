# LiveWall — Master Specification

> Animated video wallpapers for macOS (local files, direct video URLs, and YouTube video/livestream links) on Apple Silicon and Intel Macs.

This document is the entry point. It states what LiveWall is, the hard constraints Codex must respect, and links to the detailed engineering docs. **Read this file first, then the doc for the area you are implementing.**

---

## 1. What LiveWall is (and is not)

LiveWall renders animated video content in the desktop background region of one or more displays.

**LiveWall does NOT change the native macOS wallpaper.** macOS provides no public API to set a continuously playing video as the actual system desktop picture. Instead, LiveWall creates one **borderless, click-through, desktop-level `NSWindow` per selected display**, positioned behind normal app windows (and, by default, behind the desktop icons), and plays video inside it. All user-facing copy, marketing, README text, and code comments must describe the app this way. Do not claim it "sets your wallpaper" in the OS sense — say it "displays a live wallpaper" via a desktop-level overlay.

### Content sources
- **Local video files** — played with `AVPlayer` (`AVQueuePlayer` + `AVPlayerLooper`).
- **Direct video URLs** — remote `.mp4`/`.mov`/HLS `.m3u8` played with `AVPlayer`.
- **YouTube video links** — played via the official **YouTube IFrame Player API** inside a `WKWebView`.
- **YouTube livestream links** — same IFrame embed path.

### Playback capabilities
Muted or audio-enabled playback · looping · per-display assignment · Fill / Fit / Stretch / Centre · play/pause · volume/mute · frame-rate and quality caps.

---

## 2. Hard constraints (non-negotiable)

These are correctness and compliance requirements. A build that violates any of them is not acceptable.

### 2.1 Legal / content compliance — YouTube
LiveWall uses **only** the official, sanctioned YouTube embedded IFrame player loaded from YouTube's own domains. LiveWall **must not**:
- Download, cache to disk, extract, or re-host YouTube video or audio streams.
- Bypass, block, skip, fast-forward, or hide advertisements.
- Bypass or interfere with DRM / Widevine / FairPlay.
- Bypass login, age-restriction, private-video, or region/geo restrictions.
- Scrape stream URLs (no `youtube-dl`/`yt-dlp`-style extraction, no parsing of `player_response`, no `googlevideo.com` direct requests).
- Simulate clicks to dismiss ads or consent screens.

If a video cannot be embedded (owner disabled embedding, private, removed, age-gated, region-blocked), LiveWall surfaces a clear error and stops — it never attempts a workaround. See [error-handling.md](docs/error-handling.md).

### 2.2 "Not the native wallpaper" honesty
No UI string, tooltip, App Store description, or README line may state or imply LiveWall replaces the macOS system wallpaper. Approved phrasing lives in [security-distribution.md](docs/security-distribution.md#user-facing-language).

### 2.3 Resource safety
- Never run more than one wallpaper window per physical display.
- Always tear down `AVPlayer` / `AVPlayerLooper` / `WKWebView` when a wallpaper is stopped, a display disconnects, or the app pauses for power/lock/sleep. See [performance-and-power.md](docs/performance-and-power.md).
- No retain cycles between windows, renderers, players, and the manager (see the review checklist).

---

## 3. Platform targets

| Item | Decision |
| --- | --- |
| Minimum macOS | **13.0 Ventura** (required for `SMAppService` login items and `MenuBarExtra`) |
| Recommended | macOS 14 Sonoma or later |
| Architectures | **Universal 2** — `arm64` (Apple Silicon) + `x86_64` (Intel) |
| Language / UI | Swift 5.9+, SwiftUI first, AppKit where required |
| Build system | Swift Package Manager (SPM) as the primary module graph, wrapped in an Xcode app target |
| Distribution (primary) | **Developer ID + notarized**, direct download (see rationale in [security-distribution.md](docs/security-distribution.md)) |

---

## 4. Document map

| Doc | Covers spec tasks |
| --- | --- |
| [docs/architecture.md](docs/architecture.md) | Project structure, files, classes, protocols, method signatures, DI (tasks 2–5) |
| [docs/window-and-displays.md](docs/window-and-displays.md) | Borderless desktop window, window level, multi-display, hot-plug (tasks 6–8) |
| [docs/playback.md](docs/playback.md) | AVPlayer local/remote video + YouTube IFrame in WKWebView + compliance (tasks 9–11) |
| [docs/ui.md](docs/ui.md) | SwiftUI Home, library, controls, Settings (task 12) |
| [docs/settings-and-startup.md](docs/settings-and-startup.md) | Settings model, persistence, launch at login, restore (task 13) |
| [docs/performance-and-power.md](docs/performance-and-power.md) | CPU/GPU budget, pause-on-hidden/sleep/lock/battery, teardown (task 15) |
| [docs/error-handling.md](docs/error-handling.md) | Every error case + recovery + user messaging (task 14) |
| [docs/security-distribution.md](docs/security-distribution.md) | Privacy, permissions, sandbox, App Store vs direct, signing/notarization (tasks 16–20) |
| [docs/acceptance-tests.md](docs/acceptance-tests.md) | Acceptance test per major feature (task 21) |
| [docs/implementation-plan.md](docs/implementation-plan.md) | Ordered, checkable task list for Codex (task 22) |
| [docs/code-review-checklist.md](docs/code-review-checklist.md) | What the reviewer (me) checks every PR |
| [README.md](README.md) | End-user README (task 23) |

---

## 5. Core domain vocabulary (shared across all docs)

These names are canonical. Codex must use them verbatim.

- **WallpaperItem** — a persisted library entry (one video/link + its metadata).
- **WallpaperKind** — `.localVideo`, `.directVideoURL`, `.youTube`, `.youTubeLive`.
- **WallpaperRenderer** — object that draws one item into one window (`VideoWallpaperRenderer` or `WebWallpaperRenderer`).
- **WallpaperManager** — orchestrator; owns the active item and coordinates windows/power.
- **DisplayManager** — enumerates screens and reports hot-plug changes.
- **DesktopWindow / DesktopWindowController** — the borderless per-display overlay window and its controller.
- **SettingsService** — persistence for `AppSettings` and the library.
- **LaunchAtLoginService** — wraps `SMAppService`.
- **PowerMonitor** — battery / low-power / lock / display-sleep / other-app-fullscreen state.
- **PlaybackPolicy** — pure decision function: should playback be running right now?
- **FillMode** — `.fill`, `.fit`, `.stretch`, `.center`.

---

## 6. How Codex should work through this

1. Read this file + [architecture.md](docs/architecture.md).
2. Follow [implementation-plan.md](docs/implementation-plan.md) phase by phase — it is ordered so each phase is runnable/testable.
3. For each feature, satisfy the matching case in [acceptance-tests.md](docs/acceptance-tests.md).
4. Before opening a PR, self-check against [code-review-checklist.md](docs/code-review-checklist.md).
5. Never introduce any capability listed in §2.1. If a task seems to require it, stop and flag it.
