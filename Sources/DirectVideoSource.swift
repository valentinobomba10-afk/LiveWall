import Foundation

struct DirectVideoSource: WallpaperSource {
    let id: UUID
    let name: String
    let url: URL
    var sourceType: WallpaperSourceType { .directVideoURL }
}
