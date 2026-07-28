import Foundation

enum WallpaperSourceType: String, Codable, CaseIterable, Identifiable {
    case localVideo = "Local video"
    case directVideoURL = "Direct video URL"
    case youtube = "YouTube"
    var id: String { rawValue }
    var icon: String { self == .youtube ? "play.rectangle" : "film" }
}
