import Foundation

struct YouTubeSource: WallpaperSource {
    let id: UUID
    let name: String
    let videoID: String
    var sourceType: WallpaperSourceType { .youtube }
}
