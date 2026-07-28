import Foundation

@MainActor final class SettingsService: ObservableObject {
    static let shared = SettingsService()
    @Published var launchAtLogin = false
    @Published var restoreOnLaunch = true
    @Published var pauseOnBattery = false
    @Published var pauseOnFullscreen = true
    @Published var defaultMuted = true
    @Published var defaultScaling: WallpaperScalingMode = .fill
    @Published var showMenuBarItem = true
    private init() {}
}
