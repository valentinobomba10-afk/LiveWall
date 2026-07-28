import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var manager: WallpaperManager
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var displays: DisplayManager
    @State private var selectedIDs = Set<String>()
    @State private var showingAdd = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            previewPanel
            controls
            displayPanel
            errorView
            Spacer()
        }
        .padding(28)
        .onAppear { selectAllDisplays() }
        .sheet(isPresented: $showingAdd) { AddWallpaperView() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("LiveWall").font(.largeTitle.bold())
                Text("A living desktop for your Mac").foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "sparkles.tv").font(.system(size: 34)).foregroundStyle(.blue)
        }
    }

    private var previewPanel: some View {
        GroupBox {
            if let item = manager.activeItem ?? library.items.first {
                WallpaperPreviewView(item: item).frame(height: 270)
            } else {
                ContentUnavailableView("No wallpaper selected", systemImage: "rectangle.on.rectangle", description: Text("Add a local video or YouTube link to get started.")).frame(height: 270)
            }
        }
    }

    private var controls: some View {
        HStack {
            Button("Add Wallpaper", systemImage: "plus") { showingAdd = true }.buttonStyle(.borderedProminent)
            Spacer()
            Button("Stop", systemImage: "stop.fill") { manager.stopWallpaper() }.disabled(!manager.isPlaying)
            Button(manager.isPlaying ? "Pause" : "Play", systemImage: manager.isPlaying ? "pause.fill" : "play.fill") { togglePlayback() }.disabled(manager.activeItem == nil)
        }
    }

    private var displayPanel: some View {
        GroupBox("Displays") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(displays.displays, id: \.self) { screen in
                    Toggle(displays.displayName(screen), isOn: displayBinding(for: screen))
                }
                Button("Display Live Wallpaper", systemImage: "rectangle.on.rectangle") { applyWallpaper() }.buttonStyle(.borderedProminent).disabled(library.items.isEmpty)
            }
        }
    }

    @ViewBuilder private var errorView: some View {
        if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.callout) }
    }

    private func displayBinding(for screen: NSScreen) -> Binding<Bool> {
        let id = displays.stableID(screen)
        return Binding(get: { selectedIDs.contains(id) }, set: { $0 ? selectedIDs.insert(id) : selectedIDs.remove(id) })
    }

    private func selectAllDisplays() { selectedIDs = Set(displays.displays.map { displays.stableID($0) }) }
    private func togglePlayback() { manager.isPlaying ? manager.pauseWallpaper() : manager.resumeWallpaper() }
    private func applyWallpaper() {
        guard let item = library.items.first else { return }
        let targets = displays.displays.filter { selectedIDs.contains(displays.stableID($0)) }
        Task {
            do { try await manager.setWallpaper(item, on: targets) }
            catch { errorMessage = error.localizedDescription }
        }
    }
}
