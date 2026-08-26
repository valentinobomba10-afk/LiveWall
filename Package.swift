// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LiveWall",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "LiveWall", targets: ["LiveWall"])],
    targets: [
        .executableTarget(
            name: "LiveWall",
            path: ".",
            exclude: ["docs", "LiveWall.app", "README.md", "SPEC.md", "project.yml", "LockScreen"],
            sources: [
                "LiveWallApp.swift",
                "AppDelegate.swift",
                "ControlPanelView.swift",
                "BrowseView.swift",
                "SignUpView.swift",
                "Library.swift",
                "Movie.swift",
                "MovieCatalog.generated.swift",
                "RemoteVideoAssetLoader.swift",
                "Support.swift",
                "DesktopWindow.swift",
                "DisplayObserver.swift",
                "Renderers.swift",
                "WallpaperController.swift",
                "DownloadService.swift",
                "MotionBGSService.swift",
                "PowerMonitor.swift",
                "StatusMenu.swift",
                "Rotation.swift",
                "Services/LaunchAtLoginService.swift",
                "Services/FullscreenDetectionService.swift",
                "StaticWallpaperService.swift",
                "WidgetSystem.swift",
                "SecretKeys.swift",
                "Analytics.swift",
                "AuthService.swift",
                "Submissions.swift",
                "RemoteLink.swift",
                "AdBlocker.swift",
                "HotKey.swift",
                "UpdateInstaller.swift",
                "AdminPanel.swift",
                "LockScreenService.swift",
                "UpdateService.swift"
            ]
        )
    ]
)
