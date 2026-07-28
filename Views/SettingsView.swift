import SwiftUI

struct SettingsView: View {
    @StateObject private var settings = SettingsService.shared
    var body: some View {
        Form {
            behaviorSection
            appearanceSection
            aboutSection
        }
        .padding(24)
        .frame(width: 480)
        .navigationTitle("Settings")
    }
    private var behaviorSection: some View {
        Section("Behavior") {
            Toggle("Restore wallpaper when LiveWall starts", isOn: $settings.restoreOnLaunch)
            Toggle("Pause on battery", isOn: $settings.pauseOnBattery)
            Toggle("Pause while another app is fullscreen", isOn: $settings.pauseOnFullscreen)
            Toggle("Mute by default", isOn: $settings.defaultMuted)
            Toggle("Show menu-bar item", isOn: $settings.showMenuBarItem)
        }
    }
    private var appearanceSection: some View {
        Section("Appearance") {
            Picker("Default scaling", selection: $settings.defaultScaling) {
                ForEach(WallpaperScalingMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
            }
        }
    }
    private var aboutSection: some View {
        Section("About") {
            Text("LiveWall uses public macOS desktop window APIs. It cannot replace the native wallpaper image API with video.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
