import SwiftUI
import AVKit
import AVFoundation
import AppKit
import UniformTypeIdentifiers

enum SidebarSection: String, CaseIterable, Identifiable {
    case newWallpapers = "New Wallpapers"
    case gallery = "Gallery"
    case myWallpapers = "My Wallpapers"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .newWallpapers: return "sparkles"
        case .gallery: return "square.grid.2x2.fill"
        case .myWallpapers: return "rectangle.stack.badge.plus"
        }
    }
}

// MARK: - View model

final class WallpaperViewModel: ObservableObject {
    struct DisplayRow: Identifiable, Hashable {
        let id: CGDirectDisplayID; let name: String; let width: Int; let height: Int; let isMain: Bool
    }

    @Published var section: SidebarSection = .gallery
    @Published var search = ""
    @Published var categoryFilter = "All"

    @Published var templates: [LibraryItem] = []
    let library: LibraryStore

    @Published var selectedID: UUID?
    @Published var muted = true
    @Published var loops = true
    @Published var volume: Double = 0.5
    @Published var scaling: ScalingMode = .fill

    @Published var displays: [DisplayRow] = []
    @Published var selectedDisplayIDs: Set<CGDirectDisplayID> = []

    @Published var isRunning = false
    @Published var isPaused = false
    @Published var runningItemID: UUID?

    @Published var status = "Browse templates, or add your own in “My Wallpapers”."
    @Published var isError = false

    @Published var showAdd = false
    @Published var addURLText = ""
    @Published var isDownloading = false
    @Published var downloadTitle = ""
    @Published var downloadProgress = 0.0
    @Published var queuedDownloads: [LibraryItem] = []
    @Published var isDownloadPaused = false
    @Published var offlineMode = UserDefaults.standard.bool(forKey: "offlineMode")
    @Published var brightness: Double = UserDefaults.standard.object(forKey: "wallpaperBrightness") as? Double ?? 1
    @Published var saturation: Double = UserDefaults.standard.object(forKey: "wallpaperSaturation") as? Double ?? 1
    @Published var rotationEnabled = UserDefaults.standard.bool(forKey: "rotationEnabled")
    @Published var rotationMinutes: Double = UserDefaults.standard.object(forKey: "rotationMinutes") as? Double ?? 5

    private let controller: WallpaperController
    private let displayObserver: DisplayObserver
    private var downloadedTemplates: [UUID: LibraryItem] = [:]
    private var downloadTask: Task<Void, Never>?

    init(controller: WallpaperController, displayObserver: DisplayObserver, library: LibraryStore) {
        self.controller = controller
        self.displayObserver = displayObserver
        self.templates = Self.deduplicated(Self.interactiveTemplates + Self.builtInTemplates + Self.additionalTemplates + Self.additionalTemplates2 + Self.wallpaperWavesTemplates)
        self.library = library
        controller.setColorControls(brightness: brightness, saturation: saturation)
        refreshDisplays()
        displayObserver.addHandler { [weak self] in self?.refreshDisplays() }
    }

    var currentBase: [LibraryItem] {
        switch section {
        case .newWallpapers: return Array(templates.prefix(5))
        case .gallery: return templates
        case .myWallpapers: return library.items
        }
    }
    var currentItems: [LibraryItem] {
        currentBase.filter { item in
            (search.isEmpty || item.title.localizedCaseInsensitiveContains(search)) &&
            (categoryFilter == "All" || category(for: item) == categoryFilter)
        }
    }
    var categories: [String] {
        ["All"] + Set(templates.map { category(for: $0) }).sorted()
    }

    private func category(for item: LibraryItem) -> String {
        let title = item.title.lowercased()
        if item.kind == .web { return "Interactive" }
        if title.contains("car") || title.contains("bmw") || title.contains("nissan") || title.contains("toyota") || title.contains("porsche") || title.contains("mercedes") || title.contains("subaru") || title.contains("ferrari") || title.contains("dodge") || title.contains("supra") || title.contains("skyline") || title.contains("road") || title.contains("drive") { return "Cars" }
        if title.contains("space") || title.contains("astronaut") || title.contains("galaxy") || title.contains("nebula") || title.contains("black hole") || title.contains("cosmic") || title.contains("saturn") || title.contains("stellar") || title.contains("interstellar") || title.contains("void") || title.contains("universe") { return "Space" }
        if title.contains("coding") || title.contains("code") || title.contains("matrix") || title.contains("hud") || title.contains("technology") || title.contains("digital") || title.contains("circuit") || title.contains("bitcoin") || title.contains("program") || title.contains("razer") { return "Technology" }
        if title.contains("minecraft") || title.contains("roblox") || title.contains("elden ring") || title.contains("deltarune") || title.contains("star citizen") || title.contains("ghost of tsushima") { return "Games" }
        if title.contains("superman") || title.contains("spider") || title.contains("iron man") || title.contains("batman") || title.contains("marvel") || title.contains("homelander") || title.contains("spawn") || title.contains("thragg") { return "Superhero" }
        if title.contains("samurai") || title.contains("sword") || title.contains("knight") || title.contains("dragon") || title.contains("fantasy") || title.contains("magic") || title.contains("dune") { return "Fantasy" }
        if title.contains("rain") || title.contains("forest") || title.contains("mountain") || title.contains("lake") || title.contains("sunset") || title.contains("snow") || title.contains("field") || title.contains("flower") || title.contains("ocean") || title.contains("cliff") || title.contains("tree") || title.contains("garden") || title.contains("path") || title.contains("meadow") { return "Nature" }
        return "Other"
    }
    var selectedItem: LibraryItem? { (templates + library.items).first { $0.id == selectedID } }
    var canTogglePlay: Bool { isRunning }
    var showAsPlaying: Bool { isRunning && !isPaused }

    func refreshDisplays() {
        displays = displayObserver.screens.map {
            DisplayRow(id: DisplayObserver.displayID(for: $0), name: DisplayObserver.name(for: $0),
                       width: Int($0.frame.width), height: Int($0.frame.height), isMain: $0 == NSScreen.main)
        }
        let available = Set(displays.map(\.id))
        selectedDisplayIDs.formIntersection(available)
        if selectedDisplayIDs.isEmpty, let main = displays.first(where: \.isMain) ?? displays.first {
            selectedDisplayIDs = [main.id]
        }
    }

    func toggleDisplay(_ id: CGDirectDisplayID) {
        if selectedDisplayIDs.contains(id) { selectedDisplayIDs.remove(id) } else { selectedDisplayIDs.insert(id) }
    }

    func select(_ item: LibraryItem) {
        selectedID = item.id
        if item.kind == .directURL && downloadedTemplates[item.id] == nil {
            downloadTask = Task { @MainActor in
                if let local = await downloadTemplate(item) { apply(local) }
            }
        }
    }

    func apply(_ item: LibraryItem) {
        if item.kind == .directURL && templates.contains(where: { $0.id == item.id }) {
            downloadTask = Task { @MainActor in
                let local: LibraryItem?
                if let cached = downloadedTemplates[item.id] {
                    local = cached
                } else {
                    local = await downloadTemplate(item)
                }
                if let local { apply(local) }
            }
            return
        }
        guard let kind = item.wallpaperKind() else {
            setStatus("Couldn’t open “\(item.title)”. The file may have moved.", error: true); return
        }
        let request = WallpaperController.Request(
            kind: kind, muted: muted, volume: Float(volume), loops: loops,
            scaling: scaling, displayIDs: selectedDisplayIDs)
        controller.setWallpaper(request)
        Task { @MainActor in await StaticWallpaperService.applyStill(from: item, to: selectedDisplayIDs) }
        isRunning = true; isPaused = false; runningItemID = item.id; selectedID = item.id
        let n = max(selectedDisplayIDs.count, 1)
        setStatus("“\(item.title)” is live on \(n) display\(n == 1 ? "" : "s"). Close this window to keep it playing.", error: false)
    }

    func apply(_ item: LibraryItem, to displayID: CGDirectDisplayID) {
        let previous = selectedDisplayIDs
        selectedDisplayIDs = [displayID]
        apply(item)
        selectedDisplayIDs = previous
    }
    func activateFluxIdle() {
        apply(LibraryItem(title: "Flux · Drift Idle", kind: .web, urlString: "https://flux.sandydoo.me/"))
    }
    func setBrightness(_ value: Double) { brightness = value; UserDefaults.standard.set(value, forKey: "wallpaperBrightness"); controller.setColorControls(brightness: value, saturation: saturation) }
    func setSaturation(_ value: Double) { saturation = value; UserDefaults.standard.set(value, forKey: "wallpaperSaturation"); controller.setColorControls(brightness: brightness, saturation: value) }

    func applySelected() { if let item = selectedItem { apply(item) } else { setStatus("Select a wallpaper first.", error: true) } }

    @discardableResult
    private func downloadTemplate(_ item: LibraryItem) async -> LibraryItem? {
        if let cached = downloadedTemplates[item.id] { return cached }
        if offlineMode { setStatus("Offline mode is on. Use a downloaded wallpaper.", error: true); return nil }
        if isDownloading {
            if !queuedDownloads.contains(where: { $0.id == item.id }) { queuedDownloads.append(item) }
            return nil
        }
        await MainActor.run { isDownloading = true; downloadTitle = item.title; downloadProgress = 0 }
        do {
            let local = try await WallpaperDownloadService.download(item) { value in
                Task { @MainActor in self.downloadProgress = value }
            }
            await MainActor.run {
                downloadedTemplates[item.id] = local
                if let index = templates.firstIndex(where: { $0.id == item.id }) { templates[index] = local }
                isDownloading = false
                setStatus("Downloaded “\(item.title)”. It is now live.", error: false)
            }
            await MainActor.run {
                if let next = queuedDownloads.first {
                    queuedDownloads.removeFirst()
                    downloadTask = Task { @MainActor in _ = await downloadTemplate(next) }
                }
            }
            return local
        } catch {
            await MainActor.run { isDownloading = false; setStatus("Couldn’t download “\(item.title)”: \(error.localizedDescription)", error: true) }
            return nil
        }
    }

    func pauseDownload() { isDownloadPaused = true; downloadTask?.cancel(); setStatus("Download paused. Press Resume to continue.", error: false) }
    func resumeDownload() {
        guard isDownloadPaused else { return }
        isDownloadPaused = false
        guard let next = queuedDownloads.first ?? selectedItem else { return }
        Task { @MainActor in _ = await downloadTemplate(next) }
    }
    func cancelQueuedDownload(_ item: LibraryItem) { queuedDownloads.removeAll { $0.id == item.id } }

    var downloadFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("LiveWall/Downloads", isDirectory: true)
    }
    var downloadStorageBytes: Int64 {
        let urls = (try? FileManager.default.contentsOfDirectory(at: downloadFolder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return urls.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
    func clearDownloadedWallpapers() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: downloadFolder, includingPropertiesForKeys: nil)) ?? []
        for url in urls { try? FileManager.default.trashItem(at: url, resultingItemURL: nil) }
        downloadedTemplates.removeAll()
        setStatus("Downloaded wallpapers moved to Trash.", error: false)
    }
    func checkForUpdates(silent: Bool = false) {
        Task { @MainActor in
            let installed = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
            do {
                let release = try await GitHubUpdateService.latestRelease()
                let alert = NSAlert()
                if GitHubUpdateService.isNewer(release.tagName, than: installed) {
                    alert.messageText = "LiveWall \(release.tagName) is ready"
                    alert.informativeText = "Download the latest version from the shared LiveWall release channel."
                    alert.addButton(withTitle: "Download Update")
                    alert.addButton(withTitle: "Later")
                    if alert.runModal() == .alertFirstButtonReturn {
                        let download = release.assets.first(where: { $0.name.lowercased().hasSuffix(".zip") })?.browserDownloadURL ?? release.htmlURL
                        NSWorkspace.shared.open(download)
                    }
                } else {
                    guard !silent else { return }
                    alert.messageText = "LiveWall is up to date"
                    alert.informativeText = "You’re running version \(installed)."
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            } catch {
                guard !silent else { return }
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }
    func exportBackup() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "LiveWall Backup.json"; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let payload = Backup(items: library.items, offlineMode: offlineMode, brightness: brightness, saturation: saturation, rotationEnabled: rotationEnabled, rotationMinutes: rotationMinutes)
        if let data = try? JSONEncoder().encode(payload) { try? data.write(to: url, options: .atomic) }
    }
    func importBackup() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url), let backup = try? JSONDecoder().decode(Backup.self, from: data) else { return }
        for item in backup.items where !library.items.contains(item) { library.add(item) }
        offlineMode = backup.offlineMode; brightness = backup.brightness; saturation = backup.saturation; rotationEnabled = backup.rotationEnabled; rotationMinutes = backup.rotationMinutes
        UserDefaults.standard.set(offlineMode, forKey: "offlineMode"); UserDefaults.standard.set(brightness, forKey: "wallpaperBrightness")
        UserDefaults.standard.set(saturation, forKey: "wallpaperSaturation"); controller.setColorControls(brightness: brightness, saturation: saturation)
    }
    private struct Backup: Codable { var items: [LibraryItem]; var offlineMode: Bool; var brightness: Double; var saturation: Double; var rotationEnabled: Bool; var rotationMinutes: Double }

    private static var interactiveTemplates: [LibraryItem] {
        let fluidPreview = Bundle.main.url(forResource: "FluidPreview", withExtension: "png", subdirectory: "Interactive/Previews")?.absoluteString
        let fluxPreview = Bundle.main.url(forResource: "FluxPreview", withExtension: "webp", subdirectory: "Interactive/Previews")?.absoluteString
        var items = [
            LibraryItem(title: "Flux · Drift", kind: .web, urlString: "https://flux.sandydoo.me/", thumbnailURLString: fluxPreview)
        ]
        if let url = Bundle.main.url(forResource: "FluidSimulation", withExtension: "html", subdirectory: "Interactive") {
            items.append(LibraryItem(title: "WebGL Fluid Simulation", kind: .web, urlString: url.absoluteString, thumbnailURLString: fluidPreview))
        }
        for (name, title, previewName) in [
            ("AuroraParticles", "Aurora Particles", "AuroraPreview"),
            ("NeonRipples", "Neon Ripples", "NeonPreview"),
            ("WarpStars", "Warp Stars", "WarpPreview")
        ] {
            if let url = Bundle.main.url(forResource: name, withExtension: "html", subdirectory: "Interactive") {
                let preview = Bundle.main.url(forResource: previewName, withExtension: "png", subdirectory: "Interactive/Previews")?.absoluteString ?? fluidPreview
                items.append(LibraryItem(title: title, kind: .web, urlString: url.absoluteString, thumbnailURLString: preview))
            }
        }
        return items
    }

    private static let builtInTemplates: [LibraryItem] = [
        LibraryItem(title: "MotionBGS · Sunset of the Seven Suns - Deltarune", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9893"),
        LibraryItem(title: "MotionBGS · Mist Over the Pines", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9136"),
        LibraryItem(title: "MotionBGS · Coastal Cliffs Storm", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9889"),
        LibraryItem(title: "MotionBGS · Evening Drive and Windmills", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/7513"),
        LibraryItem(title: "MotionBGS · Large Cherry Blossom Tree", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9121"),
        LibraryItem(title: "MotionBGS · Stratospheric Twilight", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9859"),
        LibraryItem(title: "MotionBGS · Spring Flower Field", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9835"),
        LibraryItem(title: "MotionBGS · Orange Train at Sunset", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/5296"),
        LibraryItem(title: "MotionBGS · Snowfall in Forest", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/1041"),
        LibraryItem(title: "MotionBGS · Spring Meadow", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9834"),
        LibraryItem(title: "MotionBGS · Large Sakura Tree", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9831"),
        LibraryItem(title: "MotionBGS · Rainy Forest", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/3510"),
        LibraryItem(title: "MotionBGS · Beneath the Forgotten Arc", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9823"),
        LibraryItem(title: "MotionBGS · Stormlight Over Fields", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9352"),
        LibraryItem(title: "MotionBGS · Blue Moonlight Lake", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/5007"),
        LibraryItem(title: "MotionBGS · Full Moon Samurai", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/4121"),
        LibraryItem(title: "MotionBGS · Beneath the Golden Sky", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9786"),
        LibraryItem(title: "MotionBGS · Azure Horizon", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9760"),
        LibraryItem(title: "MotionBGS · Night Sky", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/3339"),
        LibraryItem(title: "MotionBGS · Cosmic Mountain OLED", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9723"),
        LibraryItem(title: "MotionBGS · Autumn Tree in Moonlight", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/5088"),
        LibraryItem(title: "MotionBGS · Last Train to Eden", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9718"),
        LibraryItem(title: "MotionBGS · Sunset Samurai  Blade Duel", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9637"),
        LibraryItem(title: "MotionBGS · Hydrangeas in Gentle Rain", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/7362"),
        LibraryItem(title: "MotionBGS · Windy Morning Fields", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9632"),
        LibraryItem(title: "MotionBGS · Mountain Horizon", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/7357"),
        LibraryItem(title: "MotionBGS · Full Moon (Elden Ring)", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/6572"),
        LibraryItem(title: "MotionBGS · Omi Village - Ghost of Tsushima", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9629"),
        LibraryItem(title: "MotionBGS · Imperial Rest", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9603"),
        LibraryItem(title: "MotionBGS · Silent Blade of the Forest", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/7087"),
        LibraryItem(title: "MotionBGS · Small House in Forest", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/5272"),
        LibraryItem(title: "MotionBGS · Midnight Fuel Stop", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9597"),
        LibraryItem(title: "MotionBGS · Mystic Ghost Forest", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9578"),
        LibraryItem(title: "MotionBGS · Minecraft Aquarium", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/6069"),
        LibraryItem(title: "MotionBGS · By the Fire (Minecraft)", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/530"),
        LibraryItem(title: "MotionBGS · Water World (Minecraft)", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/531"),
        LibraryItem(title: "MotionBGS · Minecraft Building", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/890"),
        LibraryItem(title: "MotionBGS · Minecraft Block Diamond", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/891"),
        LibraryItem(title: "MotionBGS · Minecraft Block Monster TNT", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/892"),
        LibraryItem(title: "MotionBGS · Monster Blocks in Minecraft", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/893"),
        LibraryItem(title: "MotionBGS · Minecraft Creeper", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/894"),
        LibraryItem(title: "MotionBGS · Enter the World of Minecraft", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/895"),
        LibraryItem(title: "MotionBGS · Minecraft Panels", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/4776"),
        LibraryItem(title: "MotionBGS · Minecraft Forest Guardian", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/8304"),
        LibraryItem(title: "MotionBGS · Sunset Mercedes Drive", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9886"),
        LibraryItem(title: "MotionBGS · White Toyota Drifting", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/6200"),
        LibraryItem(title: "MotionBGS · BMW Carros Driving", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/660"),
        LibraryItem(title: "MotionBGS · Honda Civic EK9 Spirit", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9755"),
        LibraryItem(title: "MotionBGS · BMW M4 Liberty on the Road", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/644"),
        LibraryItem(title: "MotionBGS · Evolution Never Ends", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9737"),
        LibraryItem(title: "MotionBGS · Nissan GTR R34 Skyline", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/5317"),
        LibraryItem(title: "MotionBGS · Sunset RX-7", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9734"),
        LibraryItem(title: "MotionBGS · BMW M5 in Dark", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/5411"),
        LibraryItem(title: "MotionBGS · Midnight Skyline", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9715"),
        LibraryItem(title: "MotionBGS · Cyber Streets Reign", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9687"),
        LibraryItem(title: "MotionBGS · The Drive on the Road at Sunset", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/1033"),
        LibraryItem(title: "MotionBGS · Man Sitting on Car Floating in the Ocean", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/1043"),
        LibraryItem(title: "MotionBGS · BMW M3 F30 Under the Rain", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/1061"),
        LibraryItem(title: "MotionBGS · Toyota Supra", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/2586"),
        LibraryItem(title: "MotionBGS · BMW M4 Headlight", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/2647"),
        LibraryItem(title: "MotionBGS · BMW M3 GT2 Need for Speed", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/287"),
        LibraryItem(title: "MotionBGS · Porsche Forza Motorsport 7", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/292"),
        LibraryItem(title: "MotionBGS · Yellow Nissan GTR", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/297"),
        LibraryItem(title: "MotionBGS · Nissan GTR on a Rainy Night", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/299"),
        LibraryItem(title: "MotionBGS · Supra NFS", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/3029"),
        LibraryItem(title: "MotionBGS · White Winter BMW", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/305"),
        LibraryItem(title: "MotionBGS · Porsche 911 Techart GT3", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/307"),
        LibraryItem(title: "MotionBGS · Subaru Impreza WRX", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9649"),
        LibraryItem(title: "MotionBGS · Synthwave Bike Ride", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9644"),
        LibraryItem(title: "MotionBGS · BMW M760", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/7213"),
        LibraryItem(title: "MotionBGS · Porsche 911 in Darkness", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/5292"),
        LibraryItem(title: "MotionBGS · Trueno AE86 Tokyo Street", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9596"),
        LibraryItem(title: "MotionBGS · BMW M4 Parked on a Wet Road at Night", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/317"),
        LibraryItem(title: "MotionBGS · Supra A80 Coastal Chill", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9595"),
        LibraryItem(title: "MotionBGS · Skyline R34 Trackside Meet", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9593"),
        LibraryItem(title: "MotionBGS · Dodge Charger Under the Rain", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/619"),
        LibraryItem(title: "MotionBGS · Nissan GTR Continues to Inspire", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/675"),
        LibraryItem(title: "MotionBGS · Nissan GT-R R35 Night Run", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9534"),
        LibraryItem(title: "MotionBGS · Nissan GT-R32 Rocket Bunny", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/2535"),
        LibraryItem(title: "MotionBGS · Before the Road", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9297"),
        LibraryItem(title: "MotionBGS · Formula 1 Red Bull Car", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/8046"),
        LibraryItem(title: "MotionBGS · Desert Horizon Drive", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9153"),
        LibraryItem(title: "MotionBGS · Desert Speeder", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9111"),
        LibraryItem(title: "MotionBGS · BMW M3 GTR Legend", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/7618"),
        LibraryItem(title: "MotionBGS · Lonely Highway Glow", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9092"),
        LibraryItem(title: "MotionBGS · BMW M2 Under the Rain", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/702"),
        LibraryItem(title: "MotionBGS · Deep Space Solitude", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9739"),
        LibraryItem(title: "MotionBGS · Mysteries of the Black Hole", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/7003"),
        LibraryItem(title: "MotionBGS · Forgotten Path", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9724"),
        LibraryItem(title: "MotionBGS · Black Hole", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/53"),
        LibraryItem(title: "MotionBGS · Dark Galaxy", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/4607"),
        LibraryItem(title: "MotionBGS · Pragmata Final Reach", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9538"),
        LibraryItem(title: "MotionBGS · Gravity’s Dark Abyss", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/7010"),
        LibraryItem(title: "MotionBGS · Astronaut Floating in Space", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/1044"),
        LibraryItem(title: "MotionBGS · Artemis 2 Moon Eclipse", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9453"),
        LibraryItem(title: "MotionBGS · Silver Surfer - Lone Drifter", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9082"),
        LibraryItem(title: "MotionBGS · Black Hole in Nebula", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/3261"),
        LibraryItem(title: "MotionBGS · Superman Beyond Earth", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9081"),
        LibraryItem(title: "MotionBGS · Venator and Kamino", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/2095"),
        LibraryItem(title: "MotionBGS · Silver Surfer Cosmic Void", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9078"),
        LibraryItem(title: "MotionBGS · Dark Heart of Space", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/7008"),
        LibraryItem(title: "MotionBGS · Cosmic Drive", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9043"),
        LibraryItem(title: "MotionBGS · Red Nebula", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/5733"),
        LibraryItem(title: "MotionBGS · Nebula", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/2887"),
        LibraryItem(title: "MotionBGS · Room at the Edge", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/8819"),
        LibraryItem(title: "MotionBGS · Astronaut Walking on the Moon", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/1040"),
        LibraryItem(title: "MotionBGS · Astronaut in the Ocean", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/78"),
        LibraryItem(title: "MotionBGS · Heart of the Singularity", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/8778"),
        LibraryItem(title: "MotionBGS · Stellar Colors of the Void", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/8776"),
        LibraryItem(title: "MotionBGS · Interstellar Black Hole", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/2888"),
        LibraryItem(title: "MotionBGS · Astronaut and Hands", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/2289"),
        LibraryItem(title: "MotionBGS · Saturn - Rings of Eternity", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/8730"),
        LibraryItem(title: "MotionBGS · Colorful Galaxy", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/5093"),
        LibraryItem(title: "MotionBGS · Rotating Black Hole", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/4564"),
        LibraryItem(title: "MotionBGS · Guardian of the Void", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/8700"),
        LibraryItem(title: "MotionBGS · Space Wave", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/8638"),
        LibraryItem(title: "MotionBGS · Space Bedroom", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/5245"),
        LibraryItem(title: "MotionBGS · Edge of the Event Horizon", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/7006"),
        LibraryItem(title: "MotionBGS · Star Citizen - Drake Corsair", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/8378"),
        LibraryItem(title: "MotionBGS · Universe Singularity", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/1938"),
        LibraryItem(title: "MotionBGS · Black Hole in Cosmos", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/1021"),
        LibraryItem(title: "MotionBGS · Dark Coding", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/6967"),
        LibraryItem(title: "MotionBGS · Space Science (Hud)", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/722"),
        LibraryItem(title: "MotionBGS · 3D Digital Globe", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/5819"),
        LibraryItem(title: "MotionBGS · Rog", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/5771"),
        LibraryItem(title: "MotionBGS · Matrix Binary Code", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/5606"),
        LibraryItem(title: "MotionBGS · Matrix Raining Particles", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/5605"),
        LibraryItem(title: "MotionBGS · Alphabet Code Rain", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/5604"),
        LibraryItem(title: "MotionBGS · Matrix Alphabet Code", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/5603"),
        LibraryItem(title: "MotionBGS · Hacker Code", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/5602"),
        LibraryItem(title: "MotionBGS · Green Binary Code", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/5601"),
        LibraryItem(title: "MotionBGS · Blue Code Rain", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/5600"),
        LibraryItem(title: "MotionBGS · Binary Code Falling", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/5599"),
        LibraryItem(title: "MotionBGS · Programmer Typing Code", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/5598"),
        LibraryItem(title: "MotionBGS · Laptop With Code", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/5597"),
        LibraryItem(title: "MotionBGS · Binary Code Wave", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/5529"),
        LibraryItem(title: "MotionBGS · Programming Code", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/5528"),
        LibraryItem(title: "MotionBGS · Binary Coding (Programming)", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/5351"),
        LibraryItem(title: "MotionBGS · Blue Digital Programming", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/5350"),
        LibraryItem(title: "MotionBGS · AMD Radeon", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/5344"),
        LibraryItem(title: "MotionBGS · Bitcoin (Digital Currency)", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/5342"),
        LibraryItem(title: "MotionBGS · Stock Market Charts", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/5340"),
        LibraryItem(title: "MotionBGS · Stock Trading", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/5339"),
        LibraryItem(title: "MotionBGS · Golden Bitcoin", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/5337"),
        LibraryItem(title: "MotionBGS · Bitcoin (Cryptocurrency)", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/5336"),
        LibraryItem(title: "MotionBGS · CPU Technology", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/5334"),
        LibraryItem(title: "MotionBGS · Circuit Board", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/5332"),
        LibraryItem(title: "MotionBGS · HUD Elements", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/5330"),
        LibraryItem(title: "MotionBGS · Tech Hud", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/5329"),
        LibraryItem(title: "MotionBGS · Dune HUD Interface", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/4519"),
        LibraryItem(title: "MotionBGS · Matrix Rain Codes", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/4260"),
        LibraryItem(title: "MotionBGS · Hacker Typer", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/3369"),
        LibraryItem(title: "MotionBGS · Iron Man Hud", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/1765"),
        LibraryItem(title: "MotionBGS · Futuristic User Interface HUD", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/1653"),
        LibraryItem(title: "MotionBGS · HUD Motion", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/1652"),
        LibraryItem(title: "MotionBGS · Futuristic Elements (HUD)", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/1650"),
        LibraryItem(title: "MotionBGS · Futuristic Interface (Hud)", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/723"),
        LibraryItem(title: "MotionBGS · Homelander Laser Eyes", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9779"),
        LibraryItem(title: "MotionBGS · Miles Morales in Multiverse", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/2001"),
        LibraryItem(title: "MotionBGS · Marvel Spiderman Miles Morales", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/543"),
        LibraryItem(title: "MotionBGS · Homelander Above Earth", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9778"),
        LibraryItem(title: "MotionBGS · Spider-Man 2", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/4646"),
        LibraryItem(title: "MotionBGS · Iron Man Arc Pulse", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9656"),
        LibraryItem(title: "MotionBGS · Grand Regent Thragg", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9643"),
        LibraryItem(title: "MotionBGS · Spider-Man Black Logo", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/1803"),
        LibraryItem(title: "MotionBGS · Gotham's Rainy Night", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/6356"),
        LibraryItem(title: "MotionBGS · Thragg Above Stars", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9642"),
        LibraryItem(title: "MotionBGS · Spawn Dark Hell Energy", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9604"),
        LibraryItem(title: "MotionBGS · Batman Arkham Knight", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/2726"),
        LibraryItem(title: "MotionBGS · Thragg & Mark (Invincible)", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9552"),
        LibraryItem(title: "MoeWalls · Minecraft House (960x540)", kind: .directURL, urlString: "https://motionbgs.com/media/1055/minecraft-house.960x540.mp4"),
        LibraryItem(title: "MotionBGS · Minecraft Sunset", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/2978"),
        LibraryItem(title: "MotionBGS · Nature in Minecraft", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/1964"),
        LibraryItem(title: "MotionBGS · Minecraft Northern Light", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9360"),
        LibraryItem(title: "MotionBGS · Minecraft Relaxing Fireplace", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9267"),
        LibraryItem(title: "MotionBGS · Deepwoken", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/6567"),
        LibraryItem(title: "MotionBGS · RedHorn Pirates", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/5992"),
        LibraryItem(title: "MotionBGS · Sonic Unleashed", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/4345"),
        LibraryItem(title: "MotionBGS · Roblox Characters", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/3526"),
        LibraryItem(title: "MotionBGS · Winter Devil", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/3524"),
        LibraryItem(title: "MotionBGS · Star Wars New Genesis", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/3530"),
        LibraryItem(title: "MotionBGS · Roblox Fighter", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/3531"),
        LibraryItem(title: "MotionBGS · Samurai Roblox", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/3532"),
        LibraryItem(title: "MotionBGS · Roblox Space", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/664"),
        LibraryItem(title: "MotionBGS · Dynamic Roblox Logo", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/779"),
        LibraryItem(title: "MotionBGS · Hunt Showdown Death Roots", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9293"),
        LibraryItem(title: "MotionBGS · Sunrise in the Cliffs Deltarune", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9894"),
        LibraryItem(title: "MotionBGS · The Witchers Path", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9733"),
        LibraryItem(title: "MotionBGS · Ghost of Night City", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9881"),
        LibraryItem(title: "MotionBGS · Samurai Under Maple", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9635"),
        LibraryItem(title: "MotionBGS · Prana System Error", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/9853"),
        LibraryItem(title: "MotionBGS · Surviving The Last of Us", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/501"),
        LibraryItem(title: "DesktopHut · Razer Neon Chroma Logo", kind: .directURL, urlString: "https://www.desktophut.com/files/1769591317.mp4")
    ]

    // Additional curated MotionBGS wallpapers. These are kept as compact data so
    // the catalog can grow without making the view model difficult to maintain.
    private static let additionalTemplates: [LibraryItem] = [
        "1033|the-drive-on-the-road-at-sunset", "1040|astronaut-walking-on-the-moon", "1041|snowfall-in-forest", "1043|man-sitting-on-car-floating-in-the-ocean", "1301|supercar-mercedes-benz-c63-amg-at-night", "1650|futuristic-elements-hud", "1652|hud-motion", "1653|futuristic-user-interface-hud-livewp", "1922|first-fall-day-in-forest", "1926|moonlit-bloom-cherry", "2095|venator-and-kamino", "2289|astronaut-and-hands", "2535|nissan-gt-r32-rocket-bunny", "2887|nebula", "2888|interstellar-black-hole", "3261|black-hole-in-nebula", "3339|night-sky", "3369|hacker-typer", "339|aesthetic-ferrari-f40-forza-horizon", "345|mazda-rx7-parked-in-tokyo", "350|orange-nissan-skyline-gtr", "3510|rainy-forest", "3616|lake-and-mountain-in-snow", "3624|colorful-sunset-on-street", "3728|moon-at-night", "3978|forza-horizon-4-in-winter", "4260|matrix-rain-codes", "4519|dune-hud-interface", "453|cozy-bedroom-at-night", "4564|rotating-black-hole", "4607|dark-galaxy", "500|the-last-of-us-part-ii", "5007|blue-moonlight-lake", "501|surviving-the-last-of-us", "5088|autumn-tree-in-moonlight", "5093|colorful-galaxy", "5245|space-bedroom", "5271|japanese-spring", "5272|small-house-in-forest", "5292|porsche-911-in-darkness", "5296|orange-train-at-sunset", "53|black-hole", "5315|japanese-night-village", "5317|nissan-gtr-r34-skyline", "532|mclaren-570s-nfs", "5329|tech-hud", "5330|hud-elements", "5332|circuit-board", "5334|cpu-technology", "5336|bitcoin-cryptocurrency", "5337|golden-bitcoin", "5339|stock-trading", "5340|stock-market-charts", "5342|bitcoin-digital-currency", "5344|amd-radeon", "5350|blue-digital-programming", "5351|binary-coding-programming", "5411|bmw-m5-in-dark", "5528|programming-code", "5529|binary-code-wave", "5597|laptop-with-code", "5598|programmer-typing-code", "5599|binary-code-falling", "5600|blue-code-rain", "5601|green-binary-code", "5602|hacker-code", "5603|matrix-alphabet-code", "5604|alphabet-code-rain", "5605|matrix-raining-particles", "5606|matrix-binary-code", "5733|red-nebula", "5771|rog", "5819|3d-digital-globe", "598|pink-lambo-aventador", "602|subaru-brz-under-the-rain-nfs", "618|ford-mustang-under-the-rain", "619|dodge-charger-under-the-rain", "6200|white-toyota-drifting", "626|audi-rs6-hazard", "635|ford-mustang-gt-parked-under-the-rain", "637|toyota-supra-at-neon-night-under-the-rain", "644|bmw-m4-liberty", "6584|ellen-joe-and-bagboo", "660|bmw-carros-driving", "675|nissan-gtr-continues-to-inspire", "6967|dark-coding", "7003|black-hole2", "7006|edge-of-the-event-horizon", "7008|dark-heart-of-space", "7010|gravitys-dark-abyss", "702|bmw-m2-under-the-rain", "7087|katana-forest", "7213|bmw-m760", "722|space-science-hud", "723|futuristic-interface-hud", "7357|mountain-horizon.3840x2160", "7362|hydrangeas-rain.3840x2160", "7484|skyrim-lanscape.3840x2160", "7513|evening-drive-and-windmills.3840x2160", "7618|bmw-m3-legend.3840x2160"
    ].compactMap { raw in
        let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = Int(parts[0]) else { return nil }
        let slug = parts[1].replacingOccurrences(of: ".3840x2160", with: "")
        let name = slug.replacingOccurrences(of: "-", with: " ").capitalized
        return LibraryItem(title: "MotionBGS · \(name)", kind: .directURL,
                           urlString: "https://motionbgs.com/dl/4k/\(id)")
    }

    private static let additionalTemplates2: [LibraryItem] = [
        LibraryItem(title: "MotionBGS · Miles Morales Nighttime Hero", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/1706"),
        LibraryItem(title: "MotionBGS · Marvels Spider-Man Miles Morales", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/2741"),
        LibraryItem(title: "MotionBGS · Miles Morales Young Spider-Man", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/1797"),
        LibraryItem(title: "MotionBGS · Toyota GR Supra", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/4365"),
        LibraryItem(title: "MotionBGS · Porsche 911 Carrera", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/4367"),
        LibraryItem(title: "MotionBGS · Porsche 959", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/4368"),
        LibraryItem(title: "MotionBGS · Supercar Porsche 911", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/4370"),
        LibraryItem(title: "MotionBGS · Porsche on Rainy Night", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/4371"),
        LibraryItem(title: "MotionBGS · BMW M4 NFS", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/4471"),
        LibraryItem(title: "MotionBGS · BMW M4 Running", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/4477"),
        LibraryItem(title: "MotionBGS · BMW M6 Black", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/4484"),
        LibraryItem(title: "MotionBGS · BMW M8 Black", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/4508"),
        LibraryItem(title: "MotionBGS · Toyota Supra Night Drive", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/4575"),
        LibraryItem(title: "MotionBGS · Radiant Iron Man", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/1760"),
        LibraryItem(title: "MotionBGS · Iron Man The Heart of a Hero", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/1762"),
        LibraryItem(title: "MotionBGS · Iron Man Marvel Rivals", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/7320"),
        LibraryItem(title: "MotionBGS · Neon Infused Iron Man", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/1764"),
        LibraryItem(title: "MotionBGS · Superhero Iron Man", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/1799"),
        LibraryItem(title: "MotionBGS · Iron Man Black Suit", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/1766"),
        LibraryItem(title: "MotionBGS · Ironman RGB", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/4249"),
        LibraryItem(title: "MotionBGS · Iron Man 3", kind: .directURL, urlString: "https://motionbgs.com/dl/4k/4073")
    ]

    private static let wallpaperWavesTemplates: [LibraryItem] = [
        "ancient-warrior-thousand-blades|https://wallpaperwaves.com/download.php?video=public_html/25/ancient-warrior-thousand-blades-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2026/04/ancient-warrior-thousand-blades-preview.mp4",
        "ao-guang-dragon-king|https://wallpaperwaves.com/download.php?video=/public_html/24/ao-guang-dragon-king-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2025/04/ao-guang-dragon-king-preview.mp4",
        "astral-gateway-adventure|https://wallpaperwaves.com/download.php?video=public_html/25/astral-gateway-adventure-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2025/11/astral-gateway-adventure-preview.mp4",
        "axel|https://wallpaperwaves.com/download.php?video=/public_html/24/axel-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/06/axel-preview.mp4",
        "bhadrakali-fierce-form-of-maa-kali|https://wallpaperwaves.com/download.php?video=/public_html/24/bhadrakali-fierce-form-of-maa-kali-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/06/bhadrakali-fierce-form-of-maa-kali-preview.mp4",
        "black-sun-gwent-the-witcher|https://wallpaperwaves.com/download.php?video=/24/black-sun-gwent-the-witcher-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/05/black-sun-gwent-the-witcher-preview.mp4",
        "blade-titan|https://wallpaperwaves.com/download.php?video=/public_html/24/blade-titan-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/06/blade-titan-preview.mp4",
        "celestial-angel-guardian|https://wallpaperwaves.com/download.php?video=public_html/26/celestial-angel-guardian-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2026/06/celestial-angel-guardian-preview.mp4",
        "celestial-guardian-the-light-bringer|https://wallpaperwaves.com/download.php?video=public_html/24/celestial-guardian-the-light-bringer-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2025/06/celestial-guardian-the-light-bringer-preview.mp4",
        "chinese-new-year-dragon-dance|https://wallpaperwaves.com/download.php?video=/public_html/24/chinese-new-year-dragon-dance-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/06/chinese-new-year-dragon-dance-preview.mp4",
        "cimson-moon-samurai|https://wallpaperwaves.com/download.php?video=/public_html/24/cimson-moon-samurai-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/09/cimson-moon-samurai-preview.mp4",
        "cyber-samurai-warrior|https://wallpaperwaves.com/download.php?video=/|https://wallpaperwaves.com/wp-content/uploads/2024/06/cyber-samurai-warrior-preview.mp4",
        "dark-fallen-angel|https://wallpaperwaves.com/download.php?video=/public_html/24/dark-fallen-angel-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2025/05/dark-fallen-angel-preview.mp4",
        "dark-gothic-angel|https://wallpaperwaves.com/download.php?video=/public_html/24/dark-gothic-angel-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/07/dark-gothic-angel-preview.mp4",
        "dark-knight-and-infernal-dragon|https://wallpaperwaves.com/download.php?video=public_html/24/dark-knight-and-infernal-dragon-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2025/07/dark-knight-and-infernal-dragon-preview.mp4",
        "dark-samurai-void-eyes|https://wallpaperwaves.com/download.php?video=public_html/26/dark-samurai-void-eyes-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2026/07/dark-samurai-void-eyes-preview.mp4",
        "dark-souls-fire-keeper-holding-flame|https://wallpaperwaves.com/download.php?video=public_html/24/dark-souls-fire-keeper-holding-flame-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2025/06/dark-souls-fire-keeper-holding-flame-preview.mp4",
        "fallen-dreams|https://wallpaperwaves.com/download.php?video=/24/fallen-dreams-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/05/fallen-dreams-preview.mp4",
        "fireborn-princess-and-dragon|https://wallpaperwaves.com/download.php?video=/public_html/24/fireborn-princess-and-dragon-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2025/03/fireborn-princess-and-dragon-preview.mp4",
        "forbidden-eye-symbol|https://wallpaperwaves.com/download.php?video=public_html/25/forbidden-eye-symbol-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2026/05/forbidden-eye-symbol-preview.mp4",
        "frog-in-the-cosmic-forest|https://wallpaperwaves.com/download.php?video=public_html/26/frog-in-the-cosmic-forest-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2026/07/frog-in-the-cosmic-forest-preview.mp4",
        "giant-dragon-shadow-warrior-scene|https://wallpaperwaves.com/download.php?video=public_html/25/giant-dragon-shadow-warrior-scene-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2026/04/giant-dragon-shadow-warrior-scene-preview.mp4",
        "godzilla-vs-king-ghidorah|https://wallpaperwaves.com/download.php?video=/public_html/24/godzilla-vs-king-ghidorah-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2025/05/godzilla-vs-king-ghidorah-preview.mp4",
        "gothic-female-knight-fantasy|https://wallpaperwaves.com/download.php?video=public_html/25/gothic-female-knight-fantasy-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2026/05/gothic-female-knight-fantasy-preview.mp4",
        "grim-reaper-of-shadows|https://wallpaperwaves.com/download.php?video=public_html/24/grim-reaper-of-shadows-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2025/09/grim-reaper-of-shadows-preview.mp4",
        "japanese-forest-mountainscape|https://wallpaperwaves.com/download.php?video=public_html/24/japanese-forest-mountainscape-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2025/06/japanese-forest-mountainscape-preview.mp4",
        "king-of-heroes-gilgamesh|https://wallpaperwaves.com/download.php?video=/public_html/24/king-of-heroes-gilgamesh-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/06/king-of-heroes-gilgamesh-preview.mp4",
        "lady-with-sword|https://wallpaperwaves.com/download.php?video=/24/lady-with-sword-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/05/lady-with-sword-preview.mp4",
        "magic-ritual|https://wallpaperwaves.com/download.php?video=/24/magic-ritual-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/06/magic-ritual-preview.mp4",
        "medieval-knights-campfire|https://wallpaperwaves.com/download.php?video=public_html/26/medieval-knights-campfire-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2026/07/medieval-knights-campfire-preview.mp4",
        "mysterious-forest-hanging-shadows|https://wallpaperwaves.com/download.php?video=public_html/25/mysterious-forest-hanging-shadows-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2026/03/mysterious-forest-hanging-shadows-preview.mp4",
        "mystical-cat-meditating|https://wallpaperwaves.com/download.php?video=/24/mystical-cat-meditating-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/05/mystical-cat-meditating-preview.mp4",
        "odin-the-allfather|https://wallpaperwaves.com/download.php?video=/public_html/24/odin-the-allfather-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/07/odin-the-allfather-preview.mp4",
        "oni-mask-blue-haired-demon-warrior|https://wallpaperwaves.com/download.php?video=public_html/25/oni-mask-blue-haired-demon-warrior-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2025/11/oni-mask-blue-haired-demon-warrior-preview.mp4",
        "purple-fantasy-dragon|https://wallpaperwaves.com/download.php?video=/public_html/24/purple-fantasy-dragon-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/08/purple-fantasy-dragon-preview.mp4",
        "purple-knight|https://wallpaperwaves.com/download.php?video=/public_html/24/purple-knight-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/09/purple-knight-preview.mp4",
        "queen-warrior|https://wallpaperwaves.com/download.php?video=/public_html/24/queen-warrior-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/06/queen-warrior-preview.mp4",
        "samurai-boy-and-dragon|https://wallpaperwaves.com/download.php?video=/public_html/24/samurai-boy-and-dragon-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/08/samurai-boy-and-dragon-preview.mp4",
        "spartan-warrior-battle-mode|https://wallpaperwaves.com/download.php?video=/public_html/24/spartan-warrior-battle-mode-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2025/04/spartan-warrior-battle-mode-preview.mp4",
        "sunset-samurai-warrior|https://wallpaperwaves.com/download.php?video=/public_html/24/sunset-samurai-warrior-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/06/sunset-samurai-warrior-preview.mp4",
        "sunset-view-from-train-window|https://wallpaperwaves.com/download.php?video=public_html/25/sunset-view-from-train-window-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2025/11/sunset-view-from-train-window-preview.mp4",
        "three-body-in-the-fog|https://wallpaperwaves.com/download.php?video=public_html/25/three-body-in-the-fog-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2025/10/three-body-in-the-fog-preview.mp4",
        "warrior-riding-horse|https://wallpaperwaves.com/download.php?video=/public_html/24/warrior-riding-horse-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/07/warrior-riding-horse-preview.mp4",
        "wolf-and-the-lady-warrior|https://wallpaperwaves.com/download.php?video=/wolf-and-the-lady-warrior-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/06/wolf-and-the-lady-warrior-preview.mp4",
        "2b-violin-performance-nier-automata|https://wallpaperwaves.com/download.php?video=/public_html/24/2b-violin-performance-nier-automata-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2025/05/2b-violin-performance-nier-automata-preview.mp4",
        "agent-47-hitman-absolution|https://wallpaperwaves.com/download.php?video=/public_html/24/agent-47-hitman-absolution-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/07/agent-47-hitman-absolution-preview.mp4",
        "ahri-oni-mask-cyberpunk|https://wallpaperwaves.com/download.php?video=/public_html/24/ahri-oni-mask-cyberpunk-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/06/ahri-oni-mask-cyberpunk-preview.mp4",
        "akali-league-of-legends|https://wallpaperwaves.com/download.php?video=/public_html/24/akali-league-of-legends-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/06/akali-league-of-legends-preview.mp4",
        "anticipating-fear-elden-ring|https://wallpaperwaves.com/download.php?video=/public_html/24/anticipating-fear-elden-ring-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/07/anticipating-fear-elden-ring-preview.mp4",
        "antifragile-sombra-overwatch|https://wallpaperwaves.com/download.php?video=public_html/25/antifragile-sombra-overwatch-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2026/06/antifragile-sombra-overwatch-preview.mp4",
        "arcane-jinx-league-of-legends|https://wallpaperwaves.com/download.php?video=/public_html/24/arcane-jinx-league-of-legends-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/07/arcane-jinx-league-of-legends-preview.mp4",
        "arkham-asylum-batman-intense-close-up|https://wallpaperwaves.com/download.php?video=public_html/25/arkham-asylum-batman-intense-close-up-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2026/04/arkham-asylum-batman-intense-close-up-preview.mp4",
        "assassins-creed-jade|https://wallpaperwaves.com/download.php?video=/public_html/24/assassins-creed-jade-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2025/05/assassins-creed-jade-preview.mp4",
        "bangalore-prestige-skin-apex-legends|https://wallpaperwaves.com/download.php?video=/public_html/24/bangalore-prestige-skin-apex-legends-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/07/bangalore-prestige-skin-apex-legends-preview.mp4",
        "batman-arkham-knight-gotham-city|https://wallpaperwaves.com/download.php?video=/24/batman-arkham-knight-gotham-city-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/06/batman-arkham-knight-gotham-city-preview.mp4",
        "batman-gotham-city|https://wallpaperwaves.com/download.php?video=/24/batman-gotham-city-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/05/batman-gotham-city-preview.mp4",
        "battle-bat-xayah-league-of-legends|https://wallpaperwaves.com/download.php?video=/public_html/24/battle-bat-xayah-league-of-legends-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/07/battle-bat-xayah-league-of-legends-preview.mp4",
        "battlefield-2042|https://wallpaperwaves.com/download.php?video=/public_html/24/battlefield-2042-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/06/battlefield-2042-preview.mp4",
        "battlefield-6-soldiers-in-warzone|https://wallpaperwaves.com/download.php?video=public_html/24/battlefield-6-soldiers-in-warzone-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2025/09/battlefield-6-soldiers-in-warzone-preview.mp4",
        "bianca-abystigma-lunar-guardian|https://wallpaperwaves.com/download.php?video=public_html/26/bianca-abystigma-lunar-guardian-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2026/06/bianca-abystigma-lunar-guardian-preview.mp4",
        "black-myth-wukong|https://wallpaperwaves.com/download.php?video=/public_html/24/black-myth-wukong-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/07/black-myth-wukong-preview.mp4",
        "blood-angels-warhammer-40k|https://wallpaperwaves.com/download.php?video=/public_html/24/blood-angels-warhammer-40k-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/07/blood-angels-warhammer-40k-preview.mp4",
        "bmw-m3-gtr-nfs-most-wanted-edition|https://wallpaperwaves.com/download.php?video=public_html/24/bmw-m3-gtr-nfs-most-wanted-edition-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2025/07/bmw-m3-gtr-nfs-most-wanted-edition-preview.mp4",
        "borderlands-4-psycho-rampage|https://wallpaperwaves.com/download.php?video=public_html/25/borderlands-4-psycho-rampage-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2025/11/borderlands-4-psycho-rampage-preview.mp4",
        "call-of-duty-black-ops-3|https://wallpaperwaves.com/download.php?video=/24/call-of-duty-black-ops-3-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/05/call-of-duty-black-ops-3-preview.mp4",
        "call-of-duty-black-ops-6|https://wallpaperwaves.com/download.php?video=/24/call-of-duty-black-ops-6-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/06/call-of-duty-black-ops-6-preview.mp4",
        "call-of-duty-modern-warfare-4|https://wallpaperwaves.com/download.php?video=public_html/26/call-of-duty-modern-warfare-4-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2026/07/call-of-duty-modern-warfare-4-preview.mp4",
        "call-of-duty-modern-warfare-ii-ghost|https://wallpaperwaves.com/download.php?video=/public_html/24/call-of-duty-modern-warfare-ii-ghost-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/06/call-of-duty-modern-warfare-ii-ghost-preview.mp4",
        "call-of-duty-warzone|https://wallpaperwaves.com/download.php?video=/public_html/24/call-of-duty-warzone-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/06/call-of-duty-warzone-preview.mp4",
        "catalyst-apex-legends|https://wallpaperwaves.com/download.php?video=/public_html/24/catalyst-apex-legends-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/06/catalyst-apex-legends-preview.mp4",
        "chun-li-street-fighter|https://wallpaperwaves.com/download.php?video=/public_html/24/chun-li-street-fighter-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/07/chun-li-street-fighter-preview.mp4",
        "ciri-the-witcher-3-wild-hunt|https://wallpaperwaves.com/download.php?video=/public_html/24/ciri-the-witcher-3-wild-hunt-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/07/ciri-the-witcher-3-wild-hunt-preview.mp4",
        "ciri-vs-bauk-the-witcher-4|https://wallpaperwaves.com/download.php?video=public_html/25/ciri-vs-bauk-the-witcher-4-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2025/10/ciri-vs-bauk-the-witcher-4-preview.mp4",
        "clair-obscur-expedition-33|https://wallpaperwaves.com/download.php?video=public_html/24/clair-obscur-expedition-33-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2025/07/clair-obscur-expedition-33-preview.mp4",
        "clove-valorant-home-screen|https://wallpaperwaves.com/download.php?video=/public_html/24/clove-valorant-home-screen-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/10/clove-valorant-home-screen-preview.mp4",
        "control-resonant|https://wallpaperwaves.com/download.php?video=public_html/26/control-resonant-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2026/06/control-resonant-preview.mp4",
        "control-resonant-portal-city|https://wallpaperwaves.com/download.php?video=public_html/25/control-resonant-portal-city-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2026/01/control-resonant-portal-city-preview.mp4",
        "cozy-minecraft-campfire-night|https://wallpaperwaves.com/download.php?video=public_html/26/cozy-minecraft-campfire-night-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2026/07/cozy-minecraft-campfire-night-preview.mp4",
        "cozy-minecraft-harbor-view|https://wallpaperwaves.com/download.php?video=public_html/26/cozy-minecraft-harbor-view-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2026/07/cozy-minecraft-harbor-view-preview.mp4",
        "cyberpunk-2077-animated|https://wallpaperwaves.com/download.php?video=/public_html/24/cyberpunk-2077-animated-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/09/cyberpunk-2077-animated-preview.mp4",
        "cyberpunk-2077-inspired-neon-streets|https://wallpaperwaves.com/download.php?video=public_html/25/cyberpunk-2077-inspired-neon-streets-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2025/11/cyberpunk-2077-inspired-neon-streets-preview.mp4",
        "cyberpunk-2077-johnny-silverhand|https://wallpaperwaves.com/download.php?video=public_html/25/cyberpunk-2077-johnny-silverhand-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2026/04/cyberpunk-2077-johnny-silverhand-preview.mp4",
        "cyberpunk-2077-motorcycle|https://wallpaperwaves.com/download.php?video=/24/cyberpunk-2077-motorcycle-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/06/cyberpunk-2077-motorcycle-preview.mp4",
        "cyberpunk-2077-night-city|https://wallpaperwaves.com/download.php?video=/public_html/24/cyberpunk-2077-night-city-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/06/cyberpunk-2077-night-city-preview.mp4",
        "cyberpunk-2077-yaiba-kusanagi|https://wallpaperwaves.com/download.php?video=/public_html/24/cyberpunk-2077-yaiba-kusanagi-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2025/03/cyberpunk-2077-yaiba-kusanagi-preview.mp4",
        "cyberpunk-gas-station-night|https://wallpaperwaves.com/download.php?video=public_html/25/cyberpunk-gas-station-night-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2026/05/cyberpunk-gas-station-night-preview.mp4",
        "dark-angels-warhammer-40k|https://wallpaperwaves.com/download.php?video=/public_html/24/dark-angels-warhammer-40k-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/07/dark-angels-warhammer-40k-preview.mp4",
        "dark-souls-ember-knight-flame|https://wallpaperwaves.com/download.php?video=public_html/25/dark-souls-ember-knight-flame-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2026/04/dark-souls-ember-knight-flame-preview.mp4",
        "darth-vader-hallway|https://wallpaperwaves.com/download.php?video=/public_html/24/darth-vader-hallway-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/08/darth-vader-hallway-preview.mp4",
        "darth-vader-star-wars-battlefront|https://wallpaperwaves.com/download.php?video=/public_html/24/darth-vader-star-wars-battlefront-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/06/darth-vader-star-wars-battlefront-preview.mp4",
        "destiny-2-the-final-shape-end-screen-hunter-titan-warlock|https://wallpaperwaves.com/download.php?video=/public_html/24/destiny-2-the-final-shape-end-screen-hunter-titan-warlock-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/07/destiny-2-the-final-shape-end-screen-preview.mp4",
        "doom-slayer-and-scorpion|https://wallpaperwaves.com/download.php?video=/public_html/24/doom-slayer-and-scorpion-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/08/doom-slayer-and-scorpion-preview.mp4",
        "doom-slayer-hack-and-slash|https://wallpaperwaves.com/download.php?video=/24/doom-slayer-hack-and-slash-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/06/doom-slayer-hack-and-slash-preview.mp4",
        "doom-the-dark-ages-doomslayer|https://wallpaperwaves.com/download.php?video=public_html/24/doom-the-dark-ages-doomslayer-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2025/06/doom-the-dark-ages-doomslayer-preview.mp4",
        "doomguy-doom-the-dark-ages|https://wallpaperwaves.com/download.php?video=/public_html/24/doomguy-doom-the-dark-ages-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/07/doomguy-doom-the-dark-ages-preview.mp4",
        "ekko-league-of-legends|https://wallpaperwaves.com/download.php?video=/public_html/24/ekko-league-of-legends-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/07/ekko-league-of-legends-preview.mp4",
        "elden-ring-malenia-blade|https://wallpaperwaves.com/download.php?video=/public_html/24/elden-ring-malenia-blade-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/06/elden-ring-malenia-blade-preview.mp4",
        "elden-ring-midras-frenzied-flame|https://wallpaperwaves.com/download.php?video=/public_html/24/elden-ring-midras-frenzied-flame-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/08/elden-ring-midras-frenzied-flame-preview.mp4",
        "elden-ring-nightreign-wylder|https://wallpaperwaves.com/download.php?video=public_html/24/elden-ring-nightreign-wylder-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2025/06/elden-ring-nightreign-wylder-preview.mp4",
        "elden-ring-shadow-of-the-erdtree|https://wallpaperwaves.com/download.php?video=/public_html/24/elden-ring-shadow-of-the-erdtree-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/06/elden-ring-shadow-of-the-erdtree-preview.mp4",
        "evelynn-k-da-all-out|https://wallpaperwaves.com/download.php?video=/24/evelynn-k-da-all-out-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/06/evelynn-k-da-all-out-preview.mp4",
        "everspace-starship-asteroid-flight|https://wallpaperwaves.com/download.php?video=public_html/25/everspace-starship-asteroid-flight-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2025/11/everspace-starship-asteroid-flight-preview.mp4",
        "final-fantasy-cloud-strife-epic-sword|https://wallpaperwaves.com/download.php?video=public_html/24/final-fantasy-cloud-strife-epic-sword-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2025/08/final-fantasy-cloud-strife-epic-sword-preview.mp4",
        "final-fantasy-vii-remake|https://wallpaperwaves.com/download.php?video=/public_html/24/final-fantasy-vii-remake-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/08/final-fantasy-vii-remake-preview.mp4",
        "final-fantasy-xv-noctis-weapon-summon|https://wallpaperwaves.com/download.php?video=public_html/25/final-fantasy-xv-noctis-weapon-summon-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2026/03/final-fantasy-xv-noctis-weapon-summon-preview.mp4",
        "forza-horizon-6-mount-fuji-drift|https://wallpaperwaves.com/download.php?video=public_html/25/forza-horizon-6-mount-fuji-drift-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2026/05/forza-horizon-6-mount-fuji-drift-preview.mp4",
        "forza-horizon-6-rain-drift|https://wallpaperwaves.com/download.php?video=public_html/25/forza-horizon-6-rain-drift-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2026/05/forza-horizon-6-rain-drift-preview.mp4",
        "gears-of-war-red-skull-emblem|https://wallpaperwaves.com/download.php?video=public_html/26/gears-of-war-red-skull-emblem-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2026/07/gears-of-war-red-skull-emblem-preview.mp4",
        "gemma-the-smithy-monster-hunter-wilds|https://wallpaperwaves.com/download.php?video=/public_html/24/gemma-the-smithy-monster-hunter-wilds-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/10/gemma-the-smithy-monster-hunter-wilds-preview.mp4",
        "genji-and-hanzo-overwatch|https://wallpaperwaves.com/download.php?video=/public_html/24/genji-and-hanzo-overwatch-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/06/genji-and-hanzo-overwatch-preview.mp4",
        "genji-cyber-samurai-overwatch|https://wallpaperwaves.com/download.php?video=public_html/25/genji-cyber-samurai-overwatch-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2025/12/genji-cyber-samurai-overwatch-preview.mp4",
        "geometry-dash-windows-11|https://wallpaperwaves.com/download.php?video=/public_html/24/geometry-dash-windows-11-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/08/geometry-dash-windows-11-preview.mp4",
        "geralt-cyberpunk-2077-neon-biker|https://wallpaperwaves.com/download.php?video=public_html/25/geralt-cyberpunk-2077-neon-biker-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2026/04/geralt-cyberpunk-2077-neon-biker-preview.mp4",
        "geralt-of-rivia-dark-forest-hunt|https://wallpaperwaves.com/download.php?video=public_html/25/geralt-of-rivia-dark-forest-hunt-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2026/03/geralt-of-rivia-dark-forest-hunt-preview.mp4",
        "geralt-of-rivia-monster-hunter|https://wallpaperwaves.com/download.php?video=public_html/26/geralt-of-rivia-monster-hunter-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2026/06/geralt-of-rivia-monster-hunter-preview.mp4",
        "ghost-call-of-duty-warzone|https://wallpaperwaves.com/download.php?video=/24/ghost-call-of-duty-warzone-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/05/ghost-call-of-duty-warzone-preview.mp4",
        "ghost-modern-warfare-red-shadow|https://wallpaperwaves.com/download.php?video=public_html/25/ghost-modern-warfare-red-shadow-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2025/11/ghost-modern-warfare-red-shadow-preview.mp4",
        "ghost-of-tsushima-samurai-jin-sakai|https://wallpaperwaves.com/download.php?video=/public_html/24/ghost-of-tsushima-samurai-jin-sakai-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/06/ghost-of-tsushima-samurai-jin-sakai-preview.mp4",
        "ghost-of-tsushima-samurai-red-sky|https://wallpaperwaves.com/download.php?video=public_html/24/ghost-of-tsushima-samurai-red-sky-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2025/10/ghost-of-tsushima-samurai-red-sky-preview.mp4",
        "ghost-of-yotei-mountain-view|https://wallpaperwaves.com/download.php?video=public_html/25/ghost-of-yotei-mountain-view-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2025/10/ghost-of-yotei-mountain-view-preview.mp4",
        "ghost-of-yotei-the-lone-warrior|https://wallpaperwaves.com/download.php?video=public_html/25/ghost-of-yotei-the-lone-warrior-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2025/11/ghost-of-yotei-the-lone-warrior-preview.mp4",
        "ghost-rider-flame-fury-fortnite|https://wallpaperwaves.com/download.php?video=public_html/25/ghost-rider-flame-fury-fortnite-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2025/11/ghost-rider-flame-fury-fortnite-preview.mp4",
        "ghostrunner-x-trepang2|https://wallpaperwaves.com/download.php?video=/public_html/24/ghostrunner-x-trepang2-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/07/ghostrunner-x-trepang2-preview.mp4",
        "grand-theft-auto-6-heist-duo|https://wallpaperwaves.com/download.php?video=public_html/24/grand-theft-auto-6-heist-duo-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2025/06/grand-theft-auto-6-heist-duo1-preview.mp4",
        "grand-theft-auto-v-cover-art|https://wallpaperwaves.com/download.php?video=/public_html/24/grand-theft-auto-v-cover-art-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/08/grand-theft-auto-v-cover-art-preview.mp4",
        "gta-6-jack-of-hearts-nightlife|https://wallpaperwaves.com/download.php?video=public_html/25/gta-6-jack-of-hearts-nightlife-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2026/04/gta-6-jack-of-hearts-nightlife-preview.mp4",
        "gta-6-official-poster|https://wallpaperwaves.com/download.php?video=public_html/26/gta-6-official-poster-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2026/06/gta-6-official-poster-preview.mp4",
        "gta-6-vice-city-cover-art|https://wallpaperwaves.com/download.php?video=public_html/26/gta-6-vice-city-cover-art-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2026/06/gta-6-vice-city-cover-art-preview.mp4",
        "gta-6-vice-city-duo-heist|https://wallpaperwaves.com/download.php?video=public_html/25/gta-6-vice-city-duo-heist-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2026/04/gta-6-vice-city-duo-heist-preview.mp4",
        "gta-v-franklin-michael-trevor|https://wallpaperwaves.com/download.php?video=public_html/25/gta-v-franklin-michael-trevor-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2026/04/gta-v-franklin-michael-trevor-preview.mp4",
        "gta-vi-concept-art|https://wallpaperwaves.com/download.php?video=/public_html/24/gta-vi-concept-art-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/08/gta-vi-concept-art-preview.mp4",
        "gta-vi-retro-miami-style|https://wallpaperwaves.com/download.php?video=public_html/25/gta-vi-retro-miami-style-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2025/11/gta-vi-retro-miami-style-preview.mp4",
        "guardians-of-the-galaxy-cosmic-battle|https://wallpaperwaves.com/download.php?video=public_html/26/guardians-of-the-galaxy-cosmic-battle-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2026/06/guardians-of-the-galaxy-cosmic-battle-preview.mp4",
        "halo-master-chief|https://wallpaperwaves.com/download.php?video=/24/halo-master-chief-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/06/halo-master-chief-preview.mp4",
        "halo-wars-2-spartans-cyclops|https://wallpaperwaves.com/download.php?video=/public_html/24/halo-wars-2-spartans-cyclops-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/07/halo-wars-2-spartans-cyclops-preview.mp4",
        "heavenly-kings-black-myth-wukong|https://wallpaperwaves.com/download.php?video=/public_html/24/heavenly-kings-black-myth-wukong-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/08/heavenly-kings-black-myth-wukong-preview.mp4",
        "helldivers-2-freedom-surge|https://wallpaperwaves.com/download.php?video=/public_html/24/helldivers-2-freedom-surge-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/08/helldivers-2-freedom-surge-preview.mp4",
        "high-noon-irelia|https://wallpaperwaves.com/download.php?video=/public_html/24/high-noon-irelia-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/07/high-noon-irelia-preview.mp4",
        "hollow-knight-hornet-boss-fight|https://wallpaperwaves.com/download.php?video=public_html/24/hollow-knight-hornet-boss-fight-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2025/09/hollow-knight-hornet-boss-fight-preview.mp4",
        "hoshimi-miyabi-zenless-zone-zero|https://wallpaperwaves.com/download.php?video=/public_html/24/hoshimi-miyabi-zenless-zone-zero-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2025/03/hoshimi-miyabi-zenless-zone-zero-preview.mp4",
        "hunt-showdown-dark-ritual-skull|https://wallpaperwaves.com/download.php?video=public_html/25/hunt-showdown-dark-ritual-skull-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2025/11/hunt-showdown-dark-ritual-skull-preview.mp4",
        "i-no-guitar-goddess-guilty-gear|https://wallpaperwaves.com/download.php?video=public_html/25/i-no-guitar-goddess-guilty-gear-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2026/03/i-no-guitar-goddess-guilty-gear-preview.mp4",
        "irelia-league-of-legends-epic-combat|https://wallpaperwaves.com/download.php?video=public_html/25/irelia-league-of-legends-epic-combat-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2025/12/irelia-league-of-legends-epic-combat-preview.mp4",
        "isabelle-doom-slayer|https://wallpaperwaves.com/download.php?video=/public_html/24/isabelle-doom-slayer-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/06/isabelle-doom-slayer-preview.mp4",
        "jason-and-lucia-gta-vi|https://wallpaperwaves.com/download.php?video=/public_html/24/jason-and-lucia-gta-vi-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2025/05/jason-and-lucia-gta-vi-preview.mp4",
        "jill-valentine-resident-evil|https://wallpaperwaves.com/download.php?video=/public_html/24/jill-valentine-resident-evil-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/07/jill-valentine-resident-evil-preview.mp4",
        "jinx-in-the-rain|https://wallpaperwaves.com/download.php?video=/24/jinx-in-the-rain-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/06/jinx-in-the-rain-preview.mp4",
        "jinx-neon-glow-arcane|https://wallpaperwaves.com/download.php?video=public_html/25/jinx-neon-glow-arcane-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2026/03/jinx-neon-glow-arcane-preview.mp4",
        "k-da-ahri-league-of-legends|https://wallpaperwaves.com/download.php?video=/public_html/24/k-da-ahri-league-of-legends-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/06/k-da-ahri-league-of-legends-preview.mp4",
        "karma-league-of-legends|https://wallpaperwaves.com/download.php?video=/public_html/24/karma-league-of-legends-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/07/karma-league-of-legends-preview.mp4",
        "kda-kaisa-popstar-glow|https://wallpaperwaves.com/download.php?video=public_html/25/kda-kaisa-popstar-glow-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2025/11/kda-kaisa-popstar-glow-preview.mp4",
        "killing-floor-3-nightfall|https://wallpaperwaves.com/download.php?video=/public_html/24/killing-floor-3-nightfall-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/06/killing-floor-3-nightfall-preview.mp4",
        "killjoy-valorant-cyberpunk-style|https://wallpaperwaves.com/download.php?video=public_html/25/killjoy-valorant-cyberpunk-style-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2025/12/killjoy-valorant-cyberpunk-style-preview.mp4",
        "kratos-atreus-god-of-war-ragnarok|https://wallpaperwaves.com/download.php?video=/public_html/24/kratos-atreus-god-of-war-ragnarok-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/06/kratos-atreus-god-of-war-ragnarok-preview.mp4",
        "kratos-rebellion-god-of-war|https://wallpaperwaves.com/download.php?video=/public_html/24/kratos-rebellion-god-of-war-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/11/kratos-rebellion-god-of-war-preview.mp4",
        "leon-kennedy-and-grace-ashcroft-resident-evil-requiem|https://wallpaperwaves.com/download.php?video=public_html/25/leon-kennedy-and-grace-ashcroft-resident-evil-requiem-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2026/03/leon-kennedy-and-grace-ashcroft-preview.mp4",
        "leon-s-kennedy-resident-evil-requiem|https://wallpaperwaves.com/download.php?video=public_html/25/leon-s-kennedy-resident-evil-requiem-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2026/03/leon-s-kennedy-resident-evil-requiem-preview.mp4",
        "leviatan-valorant|https://wallpaperwaves.com/download.php?video=/public_html/24/leviatan-valorant-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/09/leviatan-valorant-preview.mp4",
        "li-bai-king-of-glory|https://wallpaperwaves.com/download.php?video=/public_html/24/li-bai-king-of-glory-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/07/li-bai-king-of-glory-preview.mp4",
        "link-lost-temple-the-legend-of-zelda|https://wallpaperwaves.com/download.php?video=public_html/26/link-lost-temple-the-legend-of-zelda-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2026/07/link-lost-temple-the-legend-of-zelda-preview.mp4",
        "lucia-and-jason-gta-vi-motel-scene|https://wallpaperwaves.com/download.php?video=/public_html/24/gta-6-motel-scene-lucia-and-jason-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2025/05/gta-6-motel-scene-lucia-and-jason-preview.mp4",
        "manor-lords|https://wallpaperwaves.com/download.php?video=/public_html/24/manor-lords-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/07/manor-lords-preview.mp4",
        "mantis-marvel-rivals-cosmic-strike|https://wallpaperwaves.com/download.php?video=public_html/25/mantis-marvel-rivals-cosmic-strike-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2025/11/mantis-marvel-rivals-cosmic-strike-preview.mp4",
        "marvel-vs-capcom-fighting-collection|https://wallpaperwaves.com/download.php?video=/public_html/24/marvel-vs-capcom-fighting-collection-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/07/marvel-vs-capcom-fighting-collection-preview.mp4",
        "mass-effect-andromeda-crash-landing|https://wallpaperwaves.com/download.php?video=public_html/25/mass-effect-andromeda-crash-landing-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2025/11/mass-effect-andromeda-crash-landing-preview.mp4",
        "mass-effect-normandy-sr-2|https://wallpaperwaves.com/download.php?video=/public_html/24/mass-effect-normandy-sr-2-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/08/mass-effect-normandy-sr-2-preview.mp4",
        "master-chief-halo|https://wallpaperwaves.com/download.php?video=/public_html/24/master-chief-halo-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/07/master-chief-halo-preview.mp4",
        "mecha-break-unleashed|https://wallpaperwaves.com/download.php?video=/public_html/24/mecha-break-unleashed-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/09/mecha-break-unleashed-preview.mp4",
        "metal-gear-solid-snake-stealth-mode|https://wallpaperwaves.com/download.php?video=/public_html/24/metal-gear-solid-snake-stealth-mode-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2025/04/metal-gear-solid-snake-stealth-mode-preview.mp4",
        "metro-2039-wasteland-survivor|https://wallpaperwaves.com/download.php?video=public_html/25/metro-2039-wasteland-survivor-live-wallpaper.mp4|https://wallpaperwaves.com/wp-content/uploads/2026/06/metro-2039-wasteland-survivor-preview.mp4",
        "miles-morales-snow-city-close-up|https://wallpaperwaves.com/download.php?video=public_html/25/miles-morales-snow-city-close-up-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2026/04/miles-morales-snow-city-close-up-preview.mp4",
        "minecraft-campfire-cat-night|https://wallpaperwaves.com/download.php?video=public_html/25/minecraft-campfire-cat-night-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2026/05/minecraft-campfire-cat-night-preview.mp4",
        "minecraft-dog-sailing-the-ocean|https://wallpaperwaves.com/download.php?video=public_html/25/minecraft-dog-sailing-the-ocean-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2025/12/minecraft-dog-sailing-the-ocean-preview.mp4",
        "minecraft-shaders-lake|https://wallpaperwaves.com/download.php?video=public_html/26/minecraft-shaders-lake-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2026/07/minecraft-shaders-lake-preview.mp4",
        "minecraft-sunset-cat|https://wallpaperwaves.com/download.php?video=public_html/25/minecraft-sunset-cat-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2026/05/minecraft-sunset-cat-preview.mp4",
        "minecraft-village-cat-meadow|https://wallpaperwaves.com/download.php?video=public_html/25/minecraft-village-cat-meadow-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2026/06/minecraft-village-cat-meadow-preview.mp4",
        "monster-hunter-wilds-boss-battle|https://wallpaperwaves.com/download.php?video=/public_html/24/monster-hunter-wilds-boss-battle-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2025/05/monster-hunter-wilds-boss-battle-preview.mp4",
        "neon-ash-warframe|https://wallpaperwaves.com/download.php?video=/public_html/24/neon-ash-warframe-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/07/neon-ash-warframe-preview.mp4",
        "omen-shadow-agent-valorant|https://wallpaperwaves.com/download.php?video=public_html/25/omen-shadow-agent-valorant-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2026/05/omen-shadow-agent-valorant-preview.mp4",
        "omen-ultimate-shadow-form-valorant|https://wallpaperwaves.com/download.php?video=public_html/25/omen-ultimate-shadow-form-valorant-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2025/11/omen-ultimate-shadow-form-valorant-preview.mp4",
        "ori-and-the-will-of-the-wisps|https://wallpaperwaves.com/download.php?video=/24/ori-and-the-will-of-the-wisps-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/06/ori-and-the-will-of-the-wisps-preview.mp4",
        "path-to-nowhere|https://wallpaperwaves.com/download.php?video=/public_html/24/path-to-nowhere-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/06/path-to-nowhere-preview.mp4",
        "pathfinder-wrath-of-the-righteous|https://wallpaperwaves.com/download.php?video=/public_html/24/pathfinder-wrath-of-the-righteous-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/06/pathfinder-wrath-of-the-righteous-preview.mp4",
        "pragmata-sci-fi-companion-robot|https://wallpaperwaves.com/download.php?video=public_html/25/pragmata-sci-fi-companion-robot-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2026/05/pragmata-sci-fi-companion-robot-preview.mp4",
        "price-call-of-duty-modern-warfare-2|https://wallpaperwaves.com/download.php?video=/public_html/24/price-call-of-duty-modern-warfare-2-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/08/price-call-of-duty-modern-warfare-2-preview.mp4",
        "primordial-aatrox-league-of-legends|https://wallpaperwaves.com/download.php?video=/public_html/24/primordial-aatrox-league-of-legends-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/07/primordial-aatrox-league-of-legends-preview.mp4",
        "project-yasuo-league-of-legends|https://wallpaperwaves.com/download.php?video=/public_html/24/project-yasuo-league-of-legends-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/09/project-yasuo-league-of-legends-preview.mp4",
        "psyops-master-yi|https://wallpaperwaves.com/download.php?video=/24/psyops-master-yi-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/06/psyops-master-yi-preview.mp4",
        "racer-rin-muse-dash|https://wallpaperwaves.com/download.php?video=/public_html/24/racer-rin-muse-dash-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/07/racer-rin-muse-dash-preview.mp4",
        "raiden-metal-gear-rising-revengeance|https://wallpaperwaves.com/download.php?video=public_html/24/raiden-metal-gear-rising-revengeance-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2025/09/raiden-metal-gear-rising-revengeance-preview.mp4",
        "rainbow-six-siege-dokkaebi|https://wallpaperwaves.com/download.php?video=/public_html/24/rainbow-six-siege-dokkaebi-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/06/rainbow-six-siege-dokkaebi-preview.mp4",
        "rainbow-six-siege-tactical-soldier|https://wallpaperwaves.com/download.php?video=public_html/24/rainbow-six-siege-tactical-soldier-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2025/07/rainbow-six-siege-tactical-soldier-ww-preview.mp4",
        "red-dead-redemption-2-arthur-and-john|https://wallpaperwaves.com/download.php?video=/24/red-dead-redemption-2-arthur-and-john-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/06/red-dead-redemption-2-arthur-and-john-preview.mp4",
        "revenant-apex-legends-red-shadow|https://wallpaperwaves.com/download.php?video=public_html/25/revenant-apex-legends-red-shadow-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2026/04/revenant-apex-legends-red-shadow-preview.mp4",
        "riven-exile-sword-league-of-legends|https://wallpaperwaves.com/download.php?video=/public_html/24/riven-exile-sword-league-of-legends-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/06/riven-exile-sword-league-of-legends-preview.mp4",
        "sanguinius-and-horus-showdown|https://wallpaperwaves.com/download.php?video=public_html/24/sanguinius-and-horus-showdown-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2025/07/sanguinius-and-horus-showdown-preview.mp4",
        "saros-celestial-dominion|https://wallpaperwaves.com/download.php?video=public_html/25/saros-celestial-dominion-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2026/06/saros-celestial-dominion-preview.mp4",
        "scorpion-mortal-kombat|https://wallpaperwaves.com/download.php?video=/public_html/24/scorpion-mortal-kombat-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/06/scorpion-mortal-kombat-preview.mp4",
        "sekiro-shadows-die-twice-flames|https://wallpaperwaves.com/download.php?video=/24/sekiro-shadows-die-twice-flames-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/06/sekiro-shadows-die-twice-flames-preview.mp4",
        "shadow-fiend-dota-2|https://wallpaperwaves.com/download.php?video=/public_html/24/shadow-fiend-dota-2-wallpaperwaves-com.mp4|https://wallpaperwaves.com/wp-content/uploads/2024/12/shadow-fiend-dota-2-preview.mp4",
    ].compactMap { raw in
        let parts = raw.split(separator: "|", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { return nil }
        let name = parts[0].replacingOccurrences(of: "-", with: " ").capitalized
        return LibraryItem(title: "WallpaperWaves · \(name)", kind: .directURL,
                           urlString: parts[1], thumbnailURLString: parts[2])
    }

    private static func deduplicated(_ items: [LibraryItem]) -> [LibraryItem] {
        var seen = Set<String>()
        return items.filter { item in
            let key = item.urlString ?? item.title
            return seen.insert(key).inserted
        }
    }
    
    func stop() { controller.stop(); isRunning = false; isPaused = false; runningItemID = nil; setStatus("Live wallpaper stopped.", error: false) }

    func togglePlay() {
        guard isRunning else { return }
        if isPaused { controller.play(); isPaused = false } else { controller.pause(); isPaused = true }
    }

    func setMuted(_ m: Bool) { muted = m; controller.setMuted(m) }
    func setVolume(_ v: Double) { volume = v; controller.setVolume(Float(v)) }
    func setScaling(_ s: ScalingMode) { scaling = s; controller.setScaling(s) }

    func addLocal() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let bookmark = try? url.bookmarkData(options: [.withSecurityScope],
                                             includingResourceValuesForKeys: nil, relativeTo: nil)
        let item = LibraryItem(title: url.deletingPathExtension().lastPathComponent, kind: .localVideo,
                               bookmark: bookmark, urlString: url.absoluteString)
        library.add(item); section = .myWallpapers; selectedID = item.id; showAdd = false
        setStatus("Added “\(item.title)”. Double-click it to go live.", error: false)
    }

    func addFromURLField() {
        let text = addURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            setStatus("Enter a valid direct video URL.", error: true)
            showInputError("Enter a valid direct video URL. YouTube links are not supported.")
            return
        }
        if YouTubeParser.videoID(from: text) != nil {
            setStatus("YouTube links are not supported. Choose a local video or paste a direct video URL.", error: true)
            showInputError("YouTube links are not supported. Use a local MP4/MOV or a direct video file URL.")
            return
        }
        let item = LibraryItem(title: url.lastPathComponent.isEmpty ? "Remote video" : url.lastPathComponent,
                               kind: .directURL, urlString: text)
        library.add(item); section = .myWallpapers; selectedID = item.id; addURLText = ""; showAdd = false
        setStatus("Added “\(item.title)”. Double-click it to go live.", error: false)
    }

    private func showInputError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Can’t add wallpaper"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }


    func remove(_ item: LibraryItem) {
        library.remove(item.id)
        if runningItemID == item.id { stop() }
        if selectedID == item.id { selectedID = nil }
    }

    private func setStatus(_ s: String, error: Bool) { status = s; isError = error }
}

// MARK: - Liquid-glass building blocks

/// Real window-behind vibrancy (translucent frosted glass that samples the desktop).
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material; v.blendingMode = blending; v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material; v.blendingMode = blending; v.state = .active
    }
}

extension View {
    /// Frosted glass card with a hairline edge highlight and soft depth.
    func glassCard(_ radius: CGFloat = 22) -> some View {
        self
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1))
            .shadow(color: .black.opacity(0.16), radius: 16, y: 8)
    }
}

struct PrimaryGlassButtonStyle: ButtonStyle {
    var enabled = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.vertical, 12).padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .background(
                Capsule().fill(LinearGradient(colors: enabled ? [.blue, .indigo] : [.gray, .gray],
                                              startPoint: .topLeading, endPoint: .bottomTrailing)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
            .shadow(color: (enabled ? Color.blue : .clear).opacity(0.4), radius: 12, y: 6)
            .opacity(enabled ? 1 : 0.5)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct GlassButtonStyle: ButtonStyle {
    var tint: Color = .primary
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium, design: .rounded))
            .foregroundStyle(tint)
            .padding(.vertical, 10).padding(.horizontal, 14)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// iOS-style glass segmented control.
struct GlassSegmented: View {
    let options: [ScalingMode]
    @Binding var selection: ScalingMode
    var body: some View {
        HStack(spacing: 3) {
            ForEach(options, id: \.self) { opt in
                Text(opt.rawValue)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .padding(.vertical, 6).frame(maxWidth: .infinity)
                    .foregroundStyle(selection == opt ? .white : .secondary)
                    .background {
                        if selection == opt {
                            Capsule().fill(Color.accentColor)
                                .shadow(color: .accentColor.opacity(0.4), radius: 5, y: 2)
                        }
                    }
                    .contentShape(Capsule())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { selection = opt }
                    }
            }
        }
        .padding(3)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }
}

// MARK: - Root

struct ControlPanelView: View {
    @ObservedObject var vm: WallpaperViewModel
    @ObservedObject var library: LibraryStore

    var body: some View {
        ZStack {
            VisualEffectView(material: .underWindowBackground, blending: .behindWindow)
                .ignoresSafeArea()
            LinearGradient(colors: [.blue.opacity(0.10), .clear, .purple.opacity(0.08)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            HStack(spacing: 0) {
                sidebar.frame(width: 256)
                detail
            }
            if vm.isDownloading {
                Color.black.opacity(0.28).ignoresSafeArea()
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text("Please wait").font(.system(size: 18, weight: .semibold, design: .rounded))
                    Text("Downloading \(vm.downloadTitle)…").font(.system(size: 13, design: .rounded)).foregroundStyle(.secondary)
                }
                .padding(28).frame(width: 300)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(radius: 20)
            }
        }
        .sheet(isPresented: $vm.showAdd) { AddSheet(vm: vm) }
    }

    // Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 34, height: 34)
                    .overlay(Image(systemName: "sparkles.tv")
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white))
                    .shadow(color: .blue.opacity(0.4), radius: 6, y: 2)
                Text("LiveWall").font(.system(size: 21, weight: .bold, design: .rounded))
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 40).padding(.bottom, 14)

            searchField.padding(.horizontal, 12)

            VStack(spacing: 3) {
                ForEach(SidebarSection.allCases) { navRow($0) }
                Button { vm.showAdd = true } label: {
                    Label("Add Locally", systemImage: "plus.circle.fill")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).padding(.horizontal, 8)
            }
            .padding(.top, 12)

            Divider().padding(.vertical, 14).padding(.horizontal, 16).opacity(0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    displaysSection
                    playbackSection
                }
                .padding(.horizontal, 14)
            }

            Spacer(minLength: 8)
            actionButtons.padding(14)
        }
        .background(VisualEffectView(material: .sidebar, blending: .behindWindow).ignoresSafeArea())
        .overlay(alignment: .trailing) { Rectangle().fill(.white.opacity(0.08)).frame(width: 1).ignoresSafeArea() }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 13))
            TextField("Search", text: $vm.search)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .rounded))
        }
        .padding(.horizontal, 11).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }

    private func navRow(_ s: SidebarSection) -> some View {
        Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { vm.section = s } } label: {
            Label(s.rawValue, systemImage: s.icon)
                .font(.system(size: 14, weight: vm.section == s ? .semibold : .medium, design: .rounded))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background {
                    if vm.section == s {
                        Capsule().fill(Color.accentColor.opacity(0.22))
                            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1))
                    }
                }
                .foregroundStyle(vm.section == s ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain).padding(.horizontal, 8)
    }

    private var displaysSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DISPLAYS").font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary).tracking(0.6)
            ForEach(vm.displays) { d in
                Button { vm.toggleDisplay(d.id) } label: {
                    HStack(spacing: 9) {
                        Image(systemName: d.isMain ? "menubar.dock.rectangle" : "display")
                            .foregroundStyle(.blue).font(.system(size: 13))
                        Text("\(d.name)\(d.isMain ? " • Main" : "")")
                            .font(.system(size: 12.5, design: .rounded)).lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: vm.selectedDisplayIDs.contains(d.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(vm.selectedDisplayIDs.contains(d.id) ? Color.accentColor : Color.secondary)
                    }
                    .padding(.vertical, 7).padding(.horizontal, 10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var playbackSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PLAYBACK").font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary).tracking(0.6)
            Toggle(isOn: $vm.loops) {
                Label("Loop", systemImage: "repeat").font(.system(size: 13, design: .rounded))
            }.toggleStyle(.switch).tint(.accentColor)
            HStack(spacing: 8) {
                Button { vm.setMuted(!vm.muted) } label: {
                    Image(systemName: vm.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(vm.muted ? Color.secondary : Color.blue)
                }.buttonStyle(.plain)
                Slider(value: Binding(get: { vm.volume }, set: { vm.setVolume($0) }), in: 0...1)
                    .controlSize(.small).disabled(vm.muted).tint(.accentColor)
            }
            GlassSegmented(options: ScalingMode.allCases,
                           selection: Binding(get: { vm.scaling }, set: { vm.setScaling($0) }))
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 9) {
            Button { vm.applySelected() } label: {
                Label("Set as Live Wallpaper", systemImage: "sparkles.tv.fill")
            }
            .buttonStyle(PrimaryGlassButtonStyle(enabled: vm.selectedItem != nil))
            .disabled(vm.selectedItem == nil)

            HStack(spacing: 9) {
                Button { vm.togglePlay() } label: {
                    Image(systemName: vm.showAsPlaying ? "pause.fill" : "play.fill")
                }.buttonStyle(GlassButtonStyle()).disabled(!vm.canTogglePlay)
                Button { vm.stop() } label: {
                    Label("Stop", systemImage: "stop.fill")
                }.buttonStyle(GlassButtonStyle(tint: .red)).disabled(!vm.isRunning)
            }
        }
    }

    // Detail (grid)

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(vm.section.rawValue).font(.system(size: 28, weight: .bold, design: .rounded))
                    Text(vm.section == .newWallpapers
                         ? "The newest five additions from MotionBGS."
                         : vm.section == .gallery
                         ? "Curated live wallpapers — a desktop-level overlay, not the system wallpaper."
                         : "Your added videos and links.")
                        .font(.system(size: 13, design: .rounded)).foregroundStyle(.secondary)
                }
                Spacer()
                if vm.section == .myWallpapers {
                    Button { vm.showAdd = true } label: { Label("Add", systemImage: "plus") }
                        .buttonStyle(PrimaryGlassButtonStyle()).fixedSize()
                }
            }
            .padding(.horizontal, 24).padding(.top, 40).padding(.bottom, 16)

            statusBar.padding(.horizontal, 24)

            if vm.section == .gallery || vm.section == .newWallpapers {
                categoryBar.padding(.horizontal, 24).padding(.top, 10)
            }

            grid
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Image(systemName: vm.isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(vm.isError ? .orange : .blue)
            Text(vm.status).font(.system(size: 12.5, design: .rounded))
                .foregroundStyle(.secondary).lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .glassCard(14)
    }

    private var categoryBar: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(vm.categories, id: \.self) { category in
                    Button(category) { vm.categoryFilter = category }
                }
            } label: {
                Label(vm.categoryFilter, systemImage: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Color.accentColor, in: Capsule())
            }
            .menuStyle(.borderlessButton)

            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 8) {
                    ForEach(vm.categories, id: \.self) { category in
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { vm.categoryFilter = category }
                        } label: {
                            Text(category)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(vm.categoryFilter == category ? .white : .secondary)
                                .padding(.horizontal, 13).padding(.vertical, 7)
                                .background(vm.categoryFilter == category ? Color.accentColor : Color.white.opacity(0.08), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 34)
        }
        .frame(height: 36)
    }

    private var grid: some View {
        ScrollView {
            if vm.section == .gallery && vm.currentItems.isEmpty {
                EmptyStateView(
                    icon: "square.grid.2x2",
                    title: vm.search.isEmpty ? "No templates yet" : "No matches",
                    subtitle: vm.search.isEmpty
                        ? "Template wallpapers will appear here. For now, switch to “My Wallpapers” and add your own."
                        : "Try a different search.",
                    actionTitle: vm.search.isEmpty ? "Go to My Wallpapers" : nil,
                    action: { withAnimation { vm.section = .myWallpapers } })
                .frame(maxWidth: .infinity, minHeight: 380)
            } else if vm.section == .myWallpapers && vm.currentItems.isEmpty && vm.search.isEmpty {
                VStack(spacing: 4) {
                    LazyVGrid(columns: columns, spacing: 18) { addTile }.padding(24)
                    EmptyStateView(icon: "plus.rectangle.on.rectangle",
                                   title: "Add your first wallpaper",
                                   subtitle: "Tap the + tile to add a local video or a direct video URL.",
                                   actionTitle: nil, action: {})
                    .frame(maxWidth: .infinity, minHeight: 150)
                }
            } else {
                LazyVGrid(columns: columns, spacing: 18) {
                    if vm.section == .myWallpapers && vm.search.isEmpty { addTile }
                    ForEach(vm.currentItems) { item in
                        WallpaperTile(item: item,
                                      isSelected: vm.selectedID == item.id,
                                      isRunning: vm.runningItemID == item.id)
                            .onTapGesture(count: 2) { vm.apply(item) }
                            .onTapGesture { withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { vm.select(item) } }
                            .contextMenu {
                                Button { vm.apply(item) } label: { Label("Set as Live Wallpaper", systemImage: "sparkles.tv") }
                                if vm.section == .myWallpapers {
                                    Button(role: .destructive) { vm.remove(item) } label: { Label("Remove", systemImage: "trash") }
                                }
                            }
                    }
                }
                .padding(24)
            }
        }
    }

    private var columns: [GridItem] { [GridItem(.adaptive(minimum: 236, maximum: 340), spacing: 18)] }

    private var addTile: some View {
        Button { vm.showAdd = true } label: {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .foregroundStyle(Color.accentColor.opacity(0.55)))
                .overlay(
                    VStack(spacing: 9) {
                        Image(systemName: "plus").font(.system(size: 30, weight: .semibold))
                        Text("Add Wallpaper").font(.system(size: 14, weight: .medium, design: .rounded))
                    }.foregroundStyle(Color.accentColor))
                .aspectRatio(16.0/9.0, contentMode: .fill)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Tile

struct WallpaperTile: View {
    let item: LibraryItem
    let isSelected: Bool
    let isRunning: Bool
    @State private var nsThumb: NSImage?
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.black.opacity(0.9))
            thumbnail
            LinearGradient(colors: [.clear, .black.opacity(0.78)], startPoint: .center, endPoint: .bottom)

            HStack {
                Image(systemName: item.kind.badgeIcon)
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                    .padding(6).background(.ultraThinMaterial, in: Circle())
                Spacer()
                if isRunning {
                    HStack(spacing: 5) {
                        Circle().fill(.green).frame(width: 7, height: 7)
                        Text("LIVE").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                }
            }
            .padding(9).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            if hovering {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 44)).foregroundStyle(.white, .black.opacity(0.35))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity.combined(with: .scale))
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white).lineLimit(1)
                Text(item.subtitle).font(.system(size: 11.5, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75)).lineLimit(1)
            }
            .padding(11)
        }
        .aspectRatio(16.0/9.0, contentMode: .fill)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(isSelected ? Color.accentColor : Color.white.opacity(0.10),
                          lineWidth: isSelected ? 3 : 1))
        .shadow(color: isSelected ? .accentColor.opacity(0.35) : .black.opacity(0.22),
                radius: isSelected ? 14 : 8, y: 5)
        .scaleEffect(hovering ? 1.02 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovering)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
        .onHover { hovering = $0 }
        .task(id: "\(item.id)-\(item.kind.rawValue)") { await loadThumb() }
    }

    @ViewBuilder private var thumbnail: some View {
        if let url = item.youTubeThumbnailURL {
            AsyncImage(url: url) { img in img.resizable().aspectRatio(contentMode: .fill) }
                placeholder: { placeholderFill }
        } else if !item.remoteThumbnailURLs.isEmpty {
            RemotePosterView(urls: item.remoteThumbnailURLs, fallback: placeholderFill)
        } else if let nsThumb {
            Image(nsImage: nsThumb).resizable().aspectRatio(contentMode: .fill)
        } else {
            placeholderFill
        }
    }

    private var placeholderFill: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.17), Color(white: 0.07)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: item.kind.badgeIcon).font(.system(size: 30)).foregroundStyle(.white.opacity(0.35))
        }
    }

    private func loadThumb() async {
        // Never open remote 4K files just to make a grid thumbnail. Doing that
        // for 150 templates makes the Gallery feel slow and starts many large
        // network reads at once. Local files can be thumbnailed immediately.
        guard item.kind == .localVideo, nsThumb == nil, let kind = item.wallpaperKind() else { return }
        let url: URL?
        switch kind {
        case .localVideo(let u): url = u
        case .directURL(let u):  url = u
        case .youTube:           url = nil
        case .web:               url = nil
        }
        if let url { nsThumb = await ThumbnailGenerator.frame(url: url) }
    }
}

private struct RemotePosterView<Fallback: View>: View {
    let urls: [URL]
    let fallback: Fallback
    @State private var index = 0

    var body: some View {
        AsyncImage(url: urls[index]) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
            case .failure:
                if index + 1 < urls.count {
                    Color.clear.onAppear { index += 1 }
                } else {
                    fallback
                }
            default:
                fallback.opacity(0.55)
            }
        }
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    let icon: String
    let title: String
    let subtitle: String
    let actionTitle: String?
    let action: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 92, height: 92)
                .background(LinearGradient(colors: [.blue.opacity(0.7), .purple.opacity(0.7)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: .blue.opacity(0.3), radius: 14, y: 6)
            Text(title).font(.system(size: 19, weight: .semibold, design: .rounded))
            Text(subtitle).font(.system(size: 13.5, design: .rounded)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(PrimaryGlassButtonStyle()).fixedSize().padding(.top, 4)
            }
        }
        .padding(40)
    }
}

// MARK: - Add sheet

struct AddSheet: View {
    @ObservedObject var vm: WallpaperViewModel

    var body: some View {
        ZStack {
            VisualEffectView(material: .hudWindow, blending: .behindWindow).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 11) {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 38, height: 38)
                        .overlay(Image(systemName: "plus").font(.system(size: 18, weight: .bold)).foregroundStyle(.white))
                    Text("Add Wallpaper").font(.system(size: 22, weight: .bold, design: .rounded))
                }

                Button(action: vm.addLocal) {
                    Label("Choose Local Video…", systemImage: "folder.fill")
                }
                .buttonStyle(PrimaryGlassButtonStyle())

                HStack { rule; Text("or").foregroundStyle(.secondary).font(.system(size: 12, design: .rounded)); rule }

                Text("Paste a direct video link").font(.system(size: 13, weight: .medium, design: .rounded))
                HStack(spacing: 8) {
                    Image(systemName: "link").foregroundStyle(.secondary)
                    TextField("https://…/video.mp4", text: $vm.addURLText)
                        .textFieldStyle(.plain).font(.system(size: 13, design: .rounded))
                        .onSubmit(vm.addFromURLField)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
                Button {
                    vm.addFromURLField()
                } label: {
                    Label("Add Link", systemImage: "plus.circle.fill")
                }
                .buttonStyle(GlassButtonStyle(tint: .blue))
                .keyboardShortcut(.defaultAction)

                Text("YouTube links are not supported. Choose a local MP4/MOV or paste a direct video file URL.")
                    .font(.system(size: 11.5, design: .rounded)).foregroundStyle(.secondary)

                HStack { Spacer(); Button("Done") { vm.showAdd = false }.keyboardShortcut(.cancelAction) }
            }
            .padding(24)
        }
        .frame(width: 480)
    }

    private var rule: some View { VStack { Divider() } }
}
