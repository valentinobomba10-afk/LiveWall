import Foundation

enum WallpaperScalingMode: String, Codable, CaseIterable, Identifiable {
    case fill = "Fill", fit = "Fit", stretch = "Stretch", center = "Centre"
    var id: String { rawValue }
    var videoGravity: String { self == .fill ? "resizeAspectFill" : self == .stretch ? "resize" : "resizeAspect" }
}

struct WallpaperItem: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var sourceType: WallpaperSourceType
    var url: URL?
    var bookmark: Data?
    var scalingMode: WallpaperScalingMode = .fill
    var loops = true
    var muted = true
    var volume: Float = 0.8
    var displayIDs: [String] = []
    var dateAdded = Date()
    var resolvedURL: URL? {
        if let bookmark, let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: nil) { return resolved }
        return url
    }
}

protocol WallpaperSource {
    var id: UUID { get }
    var name: String { get }
    var sourceType: WallpaperSourceType { get }
}

extension WallpaperItem: WallpaperSource {}
