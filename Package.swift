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
            exclude: ["WindowsApp", "docs", "LiveWall.app", "README.md", "SPEC.md", "project.yml"],
            sources: [
                "LiveWallApp.swift",
                "AppDelegate.swift",
                "ControlPanelView.swift",
                "BrowseView.swift",
                "Library.swift",
                "Support.swift",
                "DesktopWindow.swift",
                "DisplayObserver.swift",
                "Renderers.swift",
                "WallpaperController.swift",
                "DownloadService.swift",
                "PowerMonitor.swift",
                "StatusMenu.swift",
                "Rotation.swift"
            ]
        )
    ]
)
