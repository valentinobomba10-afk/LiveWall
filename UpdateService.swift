import Foundation
import AppKit

/// GitHub Releases is the shared update channel for every LiveWall install.
/// A release only needs a `vX.Y.Z` tag and a `LiveWall.zip` asset.
enum GitHubUpdateService {
    private static let repository = "valentinobomba10-afk/LiveWall"

    struct Release: Decodable {
        let tagName: String
        let htmlURL: URL
        let assets: [Asset]
        enum CodingKeys: String, CodingKey { case tagName = "tag_name", htmlURL = "html_url", assets }
    }

    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL
        enum CodingKeys: String, CodingKey { case name, browserDownloadURL = "browser_download_url" }
    }

    static func latestRelease() async throws -> Release {
        let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
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
        var errorDescription: String? { "No LiveWall release is available yet." }
    }
}
