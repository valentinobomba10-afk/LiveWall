# Privacy, Security, Permissions & Distribution

Covers spec tasks 16 (privacy/security), 17 (permissions), 18 (sandbox / App Store limits), 19 (direct distribution), 20 (signing/notarization).

---

## 1. Privacy & security requirements (task 16)

LiveWall is a local utility. It should collect and transmit as little as possible.

- **No analytics, no telemetry, no accounts.** No third-party SDKs. No network calls except: (a) fetching remote video for `.directVideoURL`, (b) the YouTube IFrame embed for YouTube items, (c) YouTube thumbnail images for the library.
- **No YouTube data harvesting.** LiveWall never stores YouTube cookies persistently (`WKWebsiteDataStore.nonPersistent()`), never reads the user's YouTube account, and never extracts stream URLs.
- **Local files stay local.** Local video is accessed only via user-granted security-scoped bookmarks; LiveWall never uploads or copies user files.
- **Minimal logging.** Use `os.Logger`; never log full file paths, URLs, or video ids at default level (use `.debug`, and mark strings `privacy: .private`). Example: `logger.debug("Resolving item \(id, privacy: .public) kind \(kind.rawValue, privacy: .public)")`.
- **No secrets in the bundle.** There are no API keys (the IFrame API needs none).
- **Bookmarks are user data.** `library.json` may contain security-scoped bookmark blobs; store it in the app's Application Support container, not a shared/world-readable location.
- **WKWebView hardening:** disable back/forward gestures, disable AirPlay, non-persistent data store, only load the embed HTML with a `youtube.com` base URL, and don't expose native bridges beyond the single read-only `yt` message handler.

---

## 2. macOS permissions that may be required (task 17)

| Capability | Permission / mechanism | Notes |
| --- | --- | --- |
| Open a local video file | User selects via `NSOpenPanel` | No TCC prompt; the panel grants access. Persist with security-scoped bookmark. |
| Play remote/YouTube | Outgoing network | Sandbox entitlement `com.apple.security.network.client`. No prompt. |
| Launch at login | `SMAppService.register()` | May show in System Settings ▸ Login Items; user can approve/revoke. |
| Detect other-app fullscreen (heuristic) | `CGWindowListCopyWindowInfo` bounds only | Reading window **bounds/level** does not require Screen Recording permission; reading window **names/thumbnails/content** does. **Stay bounds-only** to avoid triggering the Screen Recording TCC prompt. |
| Screen lock/sleep detection | Distributed + `NSWorkspace` notifications | No permission required. |

**Explicitly NOT needed / NOT requested:** Camera, Microphone, Screen Recording, Accessibility, Full Disk Access, Contacts, Location. If any code path would trigger a Screen Recording prompt (e.g., calling `CGWindowListCreateImage`, or reading `kCGWindowName`), that is a bug — the fullscreen heuristic must use bounds/level only.

---

## 3. App Sandbox & App Store limitations (task 18)

### 3.1 Sandbox entitlements (recommended set)
```xml
<!-- LiveWall.entitlements -->
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.network.client</key><true/>            <!-- remote + YouTube -->
<key>com.apple.security.files.user-selected.read-only</key><true/> <!-- NSOpenPanel picks -->
<key>com.apple.security.files.bookmarks.app-scope</key><true/>  <!-- security-scoped bookmarks -->
```
No `network.server`, no `files.all`, no temporary-exception entitlements.

### 3.2 Does the desktop-overlay approach work sandboxed?
Yes. Setting `NSWindow.level` to the desktop level, `collectionBehavior`, `ignoresMouseEvents`, enumerating `NSScreen`, `AVPlayer`, and `WKWebView` all function inside the App Sandbox. `SMAppService` login items work sandboxed and on the App Store.

### 3.3 App Store concerns (realistic)
The overlay technique is allowed and shippable, but review can raise:
- **"Looks like it changes the wallpaper" claims.** Mitigated by our honest language rule (§6) — describe it as a desktop-level animated overlay.
- **YouTube embedding.** Must clearly be the official embed and comply with YouTube ToS. Reviewers dislike anything resembling stream ripping or ad-blocking — we do neither, and say so.
- **Login items / background behaviour.** Fine via `SMAppService`, but describe it in review notes.
- **Private APIs.** None used. The distributed lock notifications are semi-documented; if App Store review objects, the sleep/wake path still covers pausing (lock detection is an enhancement, not load-bearing).

### 3.4 Sandbox limitations that shape the design
- Persisted local file access **requires** security-scoped bookmarks (already in the design).
- Reliable other-app fullscreen detection is limited without private APIs → we ship a best-effort heuristic and a setting the user can disable.
- Frame-rate hard-capping isn't available → documented as best-effort.

---

## 4. Direct distribution vs Mac App Store (task 19)

**Recommendation: ship primarily via direct download (Developer ID + notarized).** Reasons:

| Factor | Direct (Developer ID) | Mac App Store |
| --- | --- | --- |
| Desktop-overlay technique | ✅ works | ✅ works (sandboxed) |
| Review friction re: "wallpaper" & YouTube embed | none | possible back-and-forth |
| Update cadence / hotfixes | immediate | gated by review |
| Login item | `SMAppService` ✅ | `SMAppService` ✅ |
| Sandbox required | optional (still recommended) | mandatory |
| Discovery / trust | lower | higher |
| Payments/IAP | you handle | built-in |

Direct distribution is more practical for iteration and avoids review ambiguity around the (honest) overlay technique and YouTube embedding, while still being fully sandboxed + notarized for user trust. **Keep the code sandbox-clean so a Mac App Store build remains possible later** — don't take direct-only shortcuts (no private APIs, no temporary-exception entitlements). Consider offering both: a notarized DMG now, App Store later.

---

## 5. Code signing & notarization (task 20)

### 5.1 Signing
- Certificate: **Developer ID Application** (for direct) / **Apple Distribution** (for App Store).
- **Hardened Runtime** enabled (required for notarization).
- Universal binary: build for `arm64` + `x86_64` (`ARCHS = "arm64 x86_64"`, `ONLY_ACTIVE_ARCH = NO` for release).
- Entitlements as in §3.1. For Hardened Runtime + WKWebView, JIT normally runs in WebKit's own XPC process; add `com.apple.security.cs.allow-jit` **only if** JS execution fails under Hardened Runtime in testing. Do not add broad exceptions preemptively.

### 5.2 Notarization (direct builds)
```bash
# 1. Archive & export a Developer ID–signed .app, then zip it
ditto -c -k --keepParent "LiveWall.app" "LiveWall.zip"

# 2. Submit with notarytool (store credentials once in the keychain profile "LiveWallNotary")
xcrun notarytool submit "LiveWall.zip" --keychain-profile "LiveWallNotary" --wait

# 3. Staple the ticket to the app (and to the DMG you distribute)
xcrun stapler staple "LiveWall.app"

# 4. Verify
spctl -a -vvv -t exec "LiveWall.app"        # should say: accepted, source=Notarized Developer ID
codesign --verify --deep --strict --verbose=2 "LiveWall.app"
```
- Distribute a **notarized, stapled DMG**; staple the DMG too so first launch works offline.
- Re-notarize on every release; stapling avoids a Gatekeeper network round-trip on the user's Mac.

### 5.3 CI notes
- Store the Developer ID cert in the CI keychain; store notary credentials via `notarytool store-credentials`.
- Fail the release pipeline if `spctl`/`codesign` verification fails.

---

## 6. User-facing language (compliance) {#user-facing-language}

Approved phrasing (use these; do not deviate toward "sets your wallpaper"):
- ✅ "Display animated video wallpapers on your desktop."
- ✅ "LiveWall plays video in a desktop-level layer behind your apps and icons."
- ✅ "This is a live wallpaper overlay — it does not replace the macOS system wallpaper."
- ❌ "Set any video as your Mac's wallpaper" (implies OS-level replacement).
- ❌ "Replaces your system wallpaper."

YouTube note to include in About/README:
- "YouTube playback uses YouTube's official embedded player. LiveWall does not download videos, remove ads, or bypass any restrictions. Some videos can't be embedded if the owner disabled it or the video is private/age-restricted/region-blocked."
