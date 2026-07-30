import Foundation
import AppKit

/// A small public Hostinger endpoint only exposes the current version. The app
/// archive itself can remain in the private GitHub repository, so the updater
/// works without embedding a GitHub credential in every copy of LiveWall.
enum GitHubUpdateService {
    private static let updateFeed = "https://palevioletred-barracuda-314738.hostingersite.com/livewall-api/api.php?action=update"

    struct Release: Decodable {
        let version: String
        let downloadURL: URL
        let releaseURL: URL
        var tagName: String { "v\(version)" }
    }

    static func latestRelease() async throws -> Release {
        let url = URL(string: updateFeed)!
        var request = URLRequest(url: url)
        request.setValue("LiveWall", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw UpdateError.noRelease }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    static func isNewer(_ tag: String, than installed: String) -> Bool {
        let remote = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let a = remote.split(separator: ".").compactMap { Int($0) }
        let b = installed.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    enum UpdateError: LocalizedError { case noRelease
        var errorDescription: String? { "The LiveWall update service is not available yet. Ask the app owner to finish the Hostinger update setup." }
    }
}
