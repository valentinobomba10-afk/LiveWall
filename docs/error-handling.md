# Error Handling

Covers spec task 14. Every failure path listed there maps to a `WallpaperError` case, a user-facing message, and a recovery action. **Nothing here may `fatalError`, force-unwrap a fallible value, or crash.**

---

## 1. `WallpaperError` (Core)

```swift
public enum WallpaperError: Error, Equatable {
    // Input / source
    case invalidURL
    case invalidYouTubeURL
    case unsupportedSource
    case unsupportedVideoFormat(String?)     // file type/codec
    case missingLocalFile
    // Network
    case noInternet
    case noInternetOrLoadFailed(NSError?)
    // YouTube (mapped from IFrame onError codes)
    case youTubePrivate                      // 100 (also removed)
    case youTubeRemoved                      // 100
    case youTubeEmbeddingDisabled            // 101 / 150
    case youTubeAgeRestricted                // surfaced via 101/150 or playback block
    case youTubeRegionBlocked
    case youTubeInvalidParameter             // 2
    case youTubeHTML5Error                   // 5
    // Playback / webview
    case playbackFailed(Error?)
    case webViewFailed(Error?)
    // Environment
    case noDisplaysAvailable
    case displayDisconnected

    public static func youTube(fromIFrameCode code: Int) -> WallpaperError {
        switch code {
        case 2:          return .youTubeInvalidParameter
        case 5:          return .youTubeHTML5Error
        case 100:        return .youTubeRemoved            // removed OR private
        case 101, 150:   return .youTubeEmbeddingDisabled  // owner disabled embedding / restricted
        default:         return .playbackFailed(nil)
        }
    }
}
```

> The IFrame API cannot always distinguish *private* vs *removed* vs *age-restricted* vs *region-blocked* — codes `100` and `101/150` are coarse. Surface an honest, combined message and let the user open the link in a browser to see the real reason. Never attempt to probe or bypass the restriction.

---

## 2. User-facing messages & recovery

Presented via `.alert(item:)` on Home or a non-modal menu-bar toast for background failures (e.g., restore-on-launch). Keep messages plain and actionable.

| Case | Title | Message | Recovery offered |
| --- | --- | --- | --- |
| `invalidURL` / `invalidYouTubeURL` | "Can't read that link" | "That doesn't look like a valid video or YouTube URL." | Re-enter URL |
| `unsupportedVideoFormat` | "Unsupported video" | "This file's format isn't supported. Try an .mp4 or .mov (H.264/HEVC)." | Pick another file |
| `missingLocalFile` | "File not found" | "The original video has moved or been deleted." | Re-locate file (re-pick to refresh bookmark) / Remove from library |
| `noInternet` / `noInternetOrLoadFailed` | "No internet connection" | "LiveWall needs a connection to play YouTube videos." | Retry / switch to a local video |
| `youTubePrivate`/`youTubeRemoved` | "Video unavailable" | "This YouTube video is private or has been removed." | Open in browser / pick another |
| `youTubeEmbeddingDisabled` | "Embedding not allowed" | "The owner has disabled playback on other sites, or the video is restricted." | Open in browser / pick another |
| `youTubeAgeRestricted` | "Age-restricted video" | "This video can't be embedded due to age restrictions." | Pick another |
| `youTubeRegionBlocked` | "Not available in your region" | "This video is blocked where you are." | Pick another |
| `webViewFailed` / `youTubeHTML5Error` | "Playback problem" | "YouTube playback failed. Try again." | Retry |
| `noDisplaysAvailable` | "No displays" | "No displays are available for a wallpaper right now." | (auto-recovers on reconnect) |
| `displayDisconnected` | (silent) | log only; auto-reconcile | none needed |

**Rules**
- Errors from renderers arrive via `WallpaperRenderer.onFailure` → `WallpaperManager` → published `lastError` → UI.
- On any terminal renderer failure, `WallpaperManager` tears that renderer down (no half-alive player) and sets `playbackState = .failed`.
- Restore-on-launch failures are **non-modal** (menu-bar badge/toast), never a blocking alert at startup, and clear `lastWallpaperID`.

---

## 3. Detection details per case (task 14 list)

1. **Invalid URLs** — `YouTubeURLParser.videoID` returns nil, or `URL(string:)` fails / non-http(s) scheme for direct URLs. Validate before creating a `WallpaperItem`.
2. **Unsupported video files** — after `AVURLAsset`, check `asset.load(.isPlayable)` (async); if not playable → `unsupportedVideoFormat`. Also pre-filter by UTType in the open panel.
3. **Missing local files** — bookmark resolves but `fileExists` is false, or `startAccessingSecurityScopedResource()` returns false → `missingLocalFile`. Handle stale bookmarks by prompting a re-pick.
4. **Private YouTube videos** — IFrame `onError` 100 → `youTubeRemoved`/`youTubePrivate` (combined message).
5. **Removed YouTube videos** — IFrame `onError` 100.
6. **Age-restricted** — often 101/150 or a playback stall; message as age-restricted when detectable, otherwise "embedding not allowed."
7. **Region-blocked** — 101/150 or geo error; message as region-blocked when the API indicates it, else combined.
8. **No internet** — check reachability before loading YouTube (see §4); `didFailProvisionalNavigation` also maps here.
9. **WKWebView playback failure** — `didFail`/`didFailProvisionalNavigation` or IFrame code 5 → `webViewFailed`/`youTubeHTML5Error` with Retry.
10. **Monitor disconnection** — `DisplayManaging.onChange` removes the controller; if it was the only display, stop cleanly and surface `noDisplaysAvailable` only if the user then tries to set a wallpaper.

---

## 4. Reachability (lightweight)

Before loading a YouTube embed, do a cheap reachability check so we can show "No internet" instead of a blank webview:

```swift
import Network
final class Reachability {
    private let monitor = NWPathMonitor()
    private(set) var isOnline = true
    func start() {
        monitor.pathUpdateHandler = { [weak self] path in self?.isOnline = (path.status == .satisfied) }
        monitor.start(queue: .global(qos: .utility))
    }
    func stop() { monitor.cancel() }
}
```

If `!isOnline` when the user sets a YouTube wallpaper → `noInternet` with Retry; the retry re-checks and loads if back online. Don't block local/direct-file playback on reachability.

---

## 5. Defensive coding rules (enforced in review)

- No force-unwraps (`!`) on `NSScreen`, dictionary lookups, `URL(string:)`, or bookmark resolution. Use `guard let … else { throw/return }`.
- Every `throws` API called from UI is wrapped; the user sees a message, the app stays alive.
- Renderer `onFailure` is always set before `prepare()`.
- Timeouts: if a YouTube embed hasn't reached `onReady`/`onStateChange` within ~15 s, treat as `webViewFailed` and offer Retry (covers silent embed failures).
- Log via `os.Logger` (subsystem `com.livewall`, categories per area). No `print` in shipping code. Never log full local file paths or URLs at default level (privacy — see [security-distribution.md](security-distribution.md)).
