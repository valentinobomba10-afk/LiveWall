# Acceptance Tests

Covers spec task 21. Each test has an ID, preconditions, steps, and a pass condition. Codex should be able to demonstrate every one. Automated unit tests are called out where they replace or support manual checks.

Legend: **[U]** unit-testable in `LiveWallCore`/`LiveWallServices`; **[M]** manual/integration on a real Mac.

---

## Local video (LOC)

- **LOC-1 [M]** Add a local .mp4 → appears in Library with a thumbnail; no crash. Pass: item persisted, thumbnail shown.
- **LOC-2 [M]** Set local video as wallpaper on main display → video plays, looped, muted by default, behind app windows and behind desktop icons. Pass: visible on desktop; clicking desktop icons still works (click-through).
- **LOC-3 [M]** Toggle Fill/Fit/Stretch/Centre live → aspect changes correctly without restart. Pass: gravity matches each mode.
- **LOC-4 [M]** Loop off → video stops at end and does not restart; Loop on → seamless loop. Pass: behaviour matches toggle.
- **LOC-5 [M]** Unmute + raise volume → audio plays; mute → silent. Pass: audio state follows controls.
- **LOC-6 [M]** Quit and relaunch with "restore last wallpaper" on → same video reappears. Pass: restored on launch.
- **LOC-7 [M]** Move/delete the source file, then relaunch → clear "File not found" handling, no crash, `lastWallpaperID` cleared. Pass: `missingLocalFile` surfaced non-modally.
- **LOC-8 [U]** Security-scoped bookmark round-trips through `WallpaperItem` Codable. Pass: decode == encode.

## Direct URL video (URL)

- **URL-1 [M]** Add a valid direct .mp4 URL → plays as wallpaper. Pass: video renders.
- **URL-2 [M]** Add an .m3u8 HLS URL → plays. Pass: stream renders.
- **URL-3 [M]** Invalid/404 URL → `webViewFailed`/`playbackFailed` message with Retry; no crash. Pass: error shown.
- **URL-4 [U]** Non-http scheme rejected at input. Pass: `invalidURL`.

## YouTube (YT)

- **YT-1 [U]** `YouTubeURLParser.videoID` extracts the id from `watch?v=`, `youtu.be/`, `/live/`, `/embed/`, `/shorts/`, and URLs with extra query params; returns nil for garbage. Pass: table of cases all correct.
- **YT-2 [M]** Add a normal public YouTube video → embeds via IFrame player, autoplays muted, loops. Pass: plays on desktop.
- **YT-3 [M]** Add a YouTube **livestream** URL → plays live. Pass: live content renders.
- **YT-4 [M]** Unmute a YouTube wallpaper → audio plays (may require the main window to have been key once; documented). Pass: audio toggles.
- **YT-5 [M]** Private/removed video → "Video unavailable" (code 100). Pass: mapped message, renderer torn down.
- **YT-6 [M]** Embedding-disabled video → "Embedding not allowed" (code 101/150). Pass: mapped message.
- **YT-7 [M]** No internet → "No internet connection" with Retry; retry works once online. Pass: reachability path.
- **YT-8 [Review]** Confirm **no** stream-extraction, ad-blocking, or DRM/geo/age bypass code exists anywhere. Pass: code review clean (see checklist).

## Window & desktop behaviour (WIN)

- **WIN-1 [M]** Wallpaper window sits behind normal app windows. Pass: any app window covers it.
- **WIN-2 [M]** Desktop icons remain visible and clickable over the video. Pass: click-through + level correct.
- **WIN-3 [M]** Wallpaper window never becomes key/main; typing focus stays in the frontmost app. Pass: focus unaffected.
- **WIN-4 [M]** Window covers the full screen including under the menu bar/Dock (no gap), and menu bar/Dock draw above it. Pass: no visible gap or overlap error.
- **WIN-5 [M]** Switching Spaces keeps the wallpaper visible (`.canJoinAllSpaces`). Pass: present on all Spaces.
- **WIN-6 [M]** Wallpaper does not appear as a window in Mission Control cycling / Cmd-`. Pass: excluded.
- **WIN-7 [M]** App has no Dock icon in accessory mode; opening the main window behaves correctly. Pass: menu-bar-first works.

## Multi-display & hot-plug (DISP)

- **DISP-1 [M]** Two displays, selection = All → one window per display, each with its own player; no duplicate windows. Pass: exactly 2 windows.
- **DISP-2 [M]** Selection = Main → wallpaper only on main display. Pass: 1 window on main.
- **DISP-3 [M]** Connect a display while running (All) → a new wallpaper window appears on it automatically. Pass: reconciled add.
- **DISP-4 [M]** Disconnect a display while running → its window+player are torn down; others keep running; no leak/crash. Pass: reconciled remove.
- **DISP-5 [M]** Change resolution/arrangement → windows resize/reposition to the new frames. Pass: frames updated.
- **DISP-6 [M]** Disconnect the only display / close clamshell → app stops cleanly, no crash; resumes on reconnect if configured. Pass: graceful.
- **DISP-7 [U]** `reconcileWindows` diff logic: given (current ids, target ids) it produces the correct add/remove/update sets. Pass: pure diff test.

## Performance & power (PWR)

- **PWR-1 [M]** Cover the wallpaper fully with a maximized app → that display's player pauses (occlusion). Uncover → resumes. Pass: pause/resume.
- **PWR-2 [M]** Lock the screen → playback pauses; unlock → resumes. Pass: lock policy.
- **PWR-3 [M]** Display sleeps → playback pauses; wakes → resumes and window level re-applied. Pass: sleep policy.
- **PWR-4 [M]** Enable Low Power Mode with `pauseOnLowPowerMode` on → pauses. Pass: LPM policy.
- **PWR-5 [M]** Unplug to battery with `pauseOnBattery` on → pauses; plug in → resumes. Pass: battery policy.
- **PWR-6 [M]** Another app enters native fullscreen with `pauseWhenAppFullscreen` on → pauses (best-effort); exit → resumes. Pass: heuristic works without false-positive flicker in normal use.
- **PWR-7 [M]** Stop wallpaper → Instruments shows `AVQueuePlayer`/`WKWebView` allocations return to baseline (no leak). Pass: memory released.
- **PWR-8 [U]** `PlaybackPolicy.shouldPlay` truth table for all input combinations vs settings. Pass: matches spec table.
- **PWR-9 [M]** Idle visible 1080p30 local video → CPU within budget (<~5% Apple Silicon), Energy Impact "Low". Pass: within budget.

## Settings & startup (SET)

- **SET-1 [U]** `AppSettings` + `[WallpaperItem]` Codable round-trip; unknown/old data → defaults, no crash. Pass: decode resilience.
- **SET-2 [M]** Toggle each setting → persists across relaunch. Pass: values restored.
- **SET-3 [M]** Enable "Launch at login" → `SMAppService.mainApp.status == .enabled`; appears in System Settings ▸ Login Items; disable → unregistered. Pass: login item toggles.
- **SET-4 [M]** "Restore last wallpaper" off → nothing plays on launch. Pass: no restore.
- **SET-5 [M]** Mute-by-default off → new wallpaper starts with sound (subject to YouTube autoplay rules). Pass: default honoured.

## Errors (ERR)

- **ERR-1 [M]** Every `WallpaperError` case renders its mapped title/message and never crashes. Pass: table verified.
- **ERR-2 [M]** Rapidly setting/stopping wallpapers and switching items → no duplicate players, no orphan windows, no crash. Pass: stress-stable.
- **ERR-3 [U]** `WallpaperError.youTube(fromIFrameCode:)` maps 2/5/100/101/150 correctly. Pass: mapping test.

## Compliance & honesty (CMP)

- **CMP-1 [Review]** No UI/README/Store string claims native wallpaper replacement (grep for banned phrases). Pass: none found.
- **CMP-2 [Review]** No download/ad-block/DRM/geo/age-bypass code (grep for `googlevideo`, `player_response`, ad-skip selectors, `yt-dlp`, etc.). Pass: none found.
- **CMP-3 [Review]** WKWebView uses `.nonPersistent()` store and only the `yt` message handler. Pass: verified.

---

## Test harness guidance
- Put **[U]** tests in `Tests/LiveWallCoreTests` and `Tests/LiveWallServicesTests`; run in CI on every PR.
- **[M]** tests: maintain a short manual checklist run before each release on both an Apple Silicon and (if available) an Intel Mac, single- and dual-display.
- **[Review]** items are gates in [code-review-checklist.md](code-review-checklist.md).
