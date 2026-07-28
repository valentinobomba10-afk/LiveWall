# User Interface (SwiftUI)

Covers spec task 12. All screens live in `LiveWallUI`. Views are thin; logic lives in view models that talk to `WallpaperManager` / `SettingsService` (injected via `@EnvironmentObject`).

---

## 1. Navigation shape

Menu-bar-first app with one main control window plus the standard Settings scene.

```
Menu bar item (MenuBarExtra)
 ├─ Play / Pause          → wallpaperManager
 ├─ Stop Wallpaper
 ├─ Mute / Unmute
 ├─ Open LiveWall…        → shows main Window
 ├─ Settings…             → Settings scene (⌘,)
 └─ Quit

Main Window ("LiveWall")  → HomeView
 ├─ Sidebar: Home · Library · Settings (NavigationSplitView)
 └─ Detail:
     Home    → HomeView (preview + primary actions + controls)
     Library → LibraryView (saved wallpapers grid)
     Settings→ SettingsView (also reachable via ⌘,)
```

Use `NavigationSplitView` for the main window; `MenuBarExtra` (macOS 13+) for the menu bar; `Settings { }` scene for preferences.

---

## 2. HomeView (task 12: Home page, add buttons, preview, set/stop, controls)

```swift
struct HomeView: View {
    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var manager: WallpaperManager
    @StateObject private var vm = HomeViewModel()

    var body: some View {
        VStack(spacing: 16) {
            WallpaperPreviewView(item: manager.activeItem, state: manager.playbackState)
                .frame(minHeight: 220)

            HStack {
                Button { vm.addLocalVideo() }  label: { Label("Add Local Video", systemImage: "film") }
                Button { vm.addYouTubeLink() } label: { Label("Add YouTube Link", systemImage: "link") }
                Spacer()
                DisplayPickerView(selection: $vm.displaySelection)
                FillModePicker(mode: $vm.fillMode)
            }

            HStack {
                Button {
                    vm.setWallpaper(using: manager)
                } label: { Label("Set Wallpaper", systemImage: "sparkles.tv") }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.pendingItem == nil && manager.activeItem == nil)

                Button(role: .destructive) { manager.stop() } label: {
                    Label("Stop Wallpaper", systemImage: "stop.fill")
                }.disabled(!manager.isRunning)
            }

            PlaybackControlsView()          // play/pause, loop, volume/mute
        }
        .padding()
        .alert(item: $vm.error) { err in Alert(title: Text(err.title), message: Text(err.message)) }
    }
}
```

### 2.1 Add Local Video
`NSOpenPanel` restricted to video UTTypes; on pick, create a security-scoped bookmark and a `WallpaperItem`, add to library, set as pending.

```swift
func addLocalVideo() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
        let bookmark = try url.bookmarkData(options: [.withSecurityScope],
                                            includingResourceValuesForKeys: nil, relativeTo: nil)
        let item = WallpaperItem(kind: .localVideo, title: url.deletingPathExtension().lastPathComponent,
                                 localBookmark: bookmark)
        settings.addToLibrary(item); pendingItem = item
    } catch { self.error = .init(error) }
}
```

### 2.2 Add YouTube Link
A sheet with a `TextField` for the URL; validate with `YouTubeURLParser.videoID(from:)`; distinguish live via `isLikelyLivePath`. Reject invalid input inline (no alert spam).

```swift
func commitYouTube(_ raw: String) {
    guard let id = YouTubeURLParser.videoID(from: raw) else { self.error = .invalidYouTubeURL; return }
    let kind: WallpaperKind = YouTubeURLParser.isLikelyLivePath(raw) ? .youTubeLive : .youTube
    let item = WallpaperItem(kind: kind, title: raw, youTubeVideoID: id)
    settings.addToLibrary(item); pendingItem = item
}
```

### 2.3 WallpaperPreviewView
Shows a live-ish preview of the selected item. **Reuse the real renderer** at small size so preview matches output:
- Local/direct: an `AVPlayerLayer`-backed `NSViewRepresentable` playing muted at low priority.
- YouTube: a small `WKWebView` with the same embed HTML (muted).
- When idle, show a placeholder with the item's title/kind and a "Set Wallpaper to start" hint.

> The preview player is separate from the desktop renderers; tear it down when the view disappears (`onDisappear`) to avoid a duplicate player running.

---

## 3. PlaybackControlsView (play/pause, loop, volume/mute)

```swift
struct PlaybackControlsView: View {
    @EnvironmentObject var manager: WallpaperManager
    @EnvironmentObject var env: AppEnvironment
    @State private var volume: Double = 0
    @State private var muted = true
    @State private var loop = true

    var body: some View {
        HStack(spacing: 16) {
            Button { manager.playbackState == .playing ? manager.pause() : manager.play() } label: {
                Image(systemName: manager.playbackState == .playing ? "pause.fill" : "play.fill")
            }.disabled(!manager.isRunning)

            Toggle("Loop", isOn: $loop).toggleStyle(.switch)
                .onChange(of: loop) { manager.setLooping($0) }

            Button { muted.toggle(); manager.setMuted(muted) } label: {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            Slider(value: $volume, in: 0...1) { _ in manager.setVolume(Float(volume)) }
                .frame(width: 140).disabled(muted)
        }
        .onAppear { syncFromSettings() }
    }
}
```

- Volume slider disabled while muted.
- Changing loop rebuilds the local player if needed (see [playback.md](playback.md#24-loop-toggle)); for YouTube it reloads the embed.

---

## 4. DisplayPickerView (display selector)

```swift
struct DisplayPickerView: View {
    @EnvironmentObject var env: AppEnvironment
    @Binding var selection: DisplaySelection

    var body: some View {
        Menu {
            Button("All Displays") { selection = .allDisplays }
            Button("Main Display")  { selection = .mainDisplay }
            Divider()
            ForEach(env.displayManager.displays) { d in
                Button { selection = .specific([.init(d.id)]) } label: {
                    Text("\(d.localizedName) — \(Int(d.frame.width))×\(Int(d.frame.height))")
                }
            }
        } label: { Label(selectionLabel, systemImage: "display.2") }
        .onReceive(env.displayManager.changePublisher) { _ in /* refresh menu */ }
    }
}
```

Updates live when displays are connected/disconnected (task 8). For multi-select, offer a checklist submenu; MVP can ship All/Main/single.

---

## 5. FillModePicker (Fill / Fit / Stretch / Centre)

```swift
struct FillModePicker: View {
    @Binding var mode: FillMode
    var body: some View {
        Picker("Fill Mode", selection: $mode) {
            Text("Fill").tag(FillMode.fill)
            Text("Fit").tag(FillMode.fit)
            Text("Stretch").tag(FillMode.stretch)
            Text("Centre").tag(FillMode.center)
        }.pickerStyle(.segmented).labelsHidden()
    }
}
```

Changing the mode calls `manager.setFillMode(_:)` live (no restart).

---

## 6. LibraryView (saved wallpaper library)

Grid of saved `WallpaperItem`s with thumbnails, kind badge, and per-item actions.

```swift
struct LibraryView: View {
    @EnvironmentObject var env: AppEnvironment
    @EnvironmentObject var manager: WallpaperManager
    private let columns = [GridItem(.adaptive(minimum: 200), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(env.settings.library) { item in
                    LibraryItemCell(item: item)
                        .contextMenu {
                            Button("Set as Wallpaper") { try? manager.setWallpaper(item, on: .allDisplays) }
                            Button("Rename…") { … }
                            Button("Remove", role: .destructive) { env.settings.removeFromLibrary(item.id) }
                        }
                        .onTapGesture(count: 2) { try? manager.setWallpaper(item, on: .allDisplays) }
                }
            }.padding()
        }
        .overlay { if env.settings.library.isEmpty { ContentUnavailableView("No wallpapers yet",
            systemImage: "photo.on.rectangle", description: Text("Add a local video or YouTube link.")) } }
    }
}
```

- Thumbnails: generate with `AVAssetImageGenerator` for local/direct; for YouTube use the standard thumbnail URL `https://img.youtube.com/vi/<id>/hqdefault.jpg` (a normal image request — not stream extraction).
- Removing a local item does **not** delete the user's file; it only drops the library entry + bookmark.

---

## 7. SettingsView (task 12: settings page; details in settings-and-startup.md)

A `TabView` or `Form` with sections. Bind each control to `env.settings.settings.<field>` (writing triggers persistence). Full field list and semantics: [settings-and-startup.md](settings-and-startup.md).

```swift
struct SettingsView: View {
    @EnvironmentObject var env: AppEnvironment
    var body: some View {
        TabView {
            GeneralSettingsTab().tabItem { Label("General", systemImage: "gear") }
            PlaybackSettingsTab().tabItem { Label("Playback", systemImage: "play.rectangle") }
            PowerSettingsTab().tabItem { Label("Power", systemImage: "bolt") }
            AboutTab().tabItem { Label("About", systemImage: "info.circle") }
        }.frame(width: 460, height: 360)
    }
}
```

**About tab must include** the honest description (LiveWall renders a desktop-level overlay, not the native wallpaper) and the YouTube compliance note. See [security-distribution.md](security-distribution.md#user-facing-language).

---

## 8. View-model contract

- View models are `@MainActor final class … : ObservableObject`.
- They hold **no** window/player references — they call `WallpaperManager`.
- Errors surface as an `IdentifiableError` for `.alert(item:)`; never `fatalError`.
- All long operations (asset load, thumbnail gen) are `async` with a loading state; UI shows a spinner, never blocks the main thread.

---

## 9. Accessibility & polish

- Every icon-only button has `.accessibilityLabel`.
- Segmented/menu controls are keyboard navigable.
- Respect Reduce Motion: if enabled, offer to pause the preview and note it in settings.
- Localizable strings via `String(localized:)`; keep the honest-wallpaper phrasing intact across locales.
