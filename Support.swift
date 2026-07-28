import Foundation
import AVFoundation

/// What kind of content a wallpaper is.
enum WallpaperKind {
    case localVideo(URL)
    case directURL(URL)
    case youTube(String)   // canonical video id
    case web(URL)          // bundled or local interactive HTML/WebGL wallpaper
}

/// How video content is fitted into the display.
enum ScalingMode: String, CaseIterable {
    case fill = "Fill"       // crop to cover
    case fit = "Fit"         // letterbox
    case stretch = "Stretch" // distort to fill
    case center = "Centre"   // no scaling (approximated by aspect fit)

    var gravity: AVLayerVideoGravity {
        switch self {
        case .fill:    return .resizeAspectFill
        case .fit:     return .resizeAspect
        case .stretch: return .resize
        case .center:  return .resizeAspect
        }
    }
}

/// Extracts a canonical YouTube video id from the common URL shapes.
enum YouTubeParser {
    static func videoID(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let rawHost = url.host?.lowercased() else { return nil }
        let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
        if host == "youtu.be" {
            return clean(url.pathComponents.dropFirst().first)
        }
        guard host == "youtube.com" || host.hasSuffix(".youtube.com") || host == "youtube-nocookie.com" || host.hasSuffix(".youtube-nocookie.com") else { return nil }
        let parts = url.pathComponents
        if let marker = parts.first(where: { ["embed", "shorts", "live", "v"].contains($0.lowercased()) }),
           let markerIndex = parts.firstIndex(of: marker), markerIndex + 1 < parts.count {
            return clean(parts[parts.index(after: markerIndex)])
        }
        let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "v" })?.value
        return clean(v)
    }

    static func isLive(_ input: String) -> Bool {
        input.lowercased().contains("/live/")
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let id = value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard id.count >= 6, id.count <= 20,
              id.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return nil }
        return id
    }
}
