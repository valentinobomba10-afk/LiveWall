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
            exclude: ["docs", "LiveWall.app", "README.md", "SPEC.md", "project.yml"],
            sources: [
                "LiveWallApp.swift",
                "AppDelegate.swift",
                "ControlPanelView.swift",
                "BrowseView.swift",
                "CommunityService.swift",
                "SignUpView.swift",
                "Library.swift",
                "Support.swift",
                "DesktopWindow.swift",
                "DisplayObserver.swift",
                "Renderers.swift",
                "WallpaperController.swift",
                "DownloadService.swift",
                "PowerMonitor.swift",
                "StatusMenu.swift",
                "Rotation.swift",
                "Services/LaunchAtLoginService.swift",
                "Services/FullscreenDetectionService.swift",
                "StaticWallpaperService.swift",
                "UpdateService.swift"
            ]
        )
    ]
)
