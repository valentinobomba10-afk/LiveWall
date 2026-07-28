import Foundation

enum YouTubeURLParser {
    static func videoID(from input: String) -> String? {
        guard let url = URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host?.lowercased() else { return nil }
        if host.contains("youtu.be") { return clean(url.pathComponents.last) }
        guard host.contains("youtube.com") || host.contains("youtube-nocookie.com") else { return nil }
        if url.pathComponents.contains("embed") || url.pathComponents.contains("shorts") || url.pathComponents.contains("live") {
            return clean(url.pathComponents.last)
        }
        return clean(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value)
    }
    private static func clean(_ value: String?) -> String? {
        guard let value, value.count >= 6, value.count <= 20,
              value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return nil }
        return value
    }
}
