import Foundation

struct LocalVideoSource: WallpaperSource {
    let id: UUID
    let name: String
    let url: URL
    var sourceType: WallpaperSourceType { .localVideo }
    init(item: WallpaperItem) { id = item.id; name = item.name; url = item.resolvedURL! }
}
