import Foundation

/// Reads MotionBGS's public catalog pages. Only the small catalog metadata is
/// loaded here; the MP4 is downloaded by WallpaperDownloadService when chosen.
enum MotionBGSService {
    static let baseURL = URL(string: "https://motionbgs.com")!

    // The site's main category pages are paginated. Loading one page per
    // category gives a broad catalog quickly; the view model can request the
    // next page without making startup wait for the whole site.
    static let categorySlugs = [
        // Original set
        "anime", "games", "superhero", "nature", "car", "tv", "holiday",
        "animal", "fantasy", "space", "horror", "technology", "football", "japan",
        // Broader coverage. A tag the site does not have simply returns nothing,
        // so an unknown slug costs one failed request and never breaks loading.
        "abstract", "city", "minecraft", "music", "movie", "aesthetic",
        "dark", "neon", "sport", "flower", "sky", "ocean", "winter", "sunset",
        "girl", "cyberpunk", "forest", "mountain", "water", "art"
    ]

    static func fetchPage(category: String, page: Int) async throws -> [LibraryItem] {
        let path = page <= 1 ? "/tag:\(category)/" : "/tag:\(category)/\(page)/"
        var request = URLRequest(url: baseURL.appendingPathComponent(String(path.dropFirst())))
        request.setValue("LiveWall macOS wallpaper catalog", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else {
            throw NSError(domain: "LiveWall.MotionBGS", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "MotionBGS catalog could not be loaded."])
        }
        guard let html = String(data: data, encoding: .utf8) else { return [] }
        return parse(html: html, category: category)
    }

    /// Human-readable name for a MotionBGS tag slug.
    static func displayName(for slug: String) -> String {
        switch slug {
        case "car":       return "Cars"
        case "superhero": return "Superheroes"
        case "tv":        return "TV & Film"
        case "animal":    return "Animals"
        case "game", "games": return "Games"
        case "girl":      return "Characters"
        case "movie":     return "TV & Film"
        case "sport":     return "Sports"
        case "art":       return "Abstract"
        default:          return slug.prefix(1).uppercased() + slug.dropFirst()
        }
    }

    private static func parse(html: String, category: String) -> [LibraryItem] {
        // The catalog cards contain title, detail-page slug, and a small poster
        // image. The HTML is intentionally parsed narrowly so navigation links
        // and category menus are not mistaken for wallpaper cards.
        let pattern = #"(?s)<a\s+title="([^"]+?)\s+live wallpaper"\s+href=([^\s>]+).*?<img[^>]+src=([^\s>]+)"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var output: [LibraryItem] = []
        var seen = Set<String>()

        for match in expression.matches(in: html, range: range) {
            guard match.numberOfRanges == 4,
                  let title = html.substring(match.range(at: 1)),
                  let imagePath = html.substring(match.range(at: 3)) else { continue }
            let normalizedImage = imagePath.hasPrefix("http") ? imagePath : baseURL.absoluteString + imagePath
            guard let imageURL = URL(string: normalizedImage),
                  let id = imageURL.pathComponents.first(where: { $0.allSatisfy({ $0.isNumber }) }),
                  !id.isEmpty, seen.insert(id).inserted else { continue }

            output.append(LibraryItem(
                title: "MotionBGS · \(title.trimmingCharacters(in: .whitespacesAndNewlines))",
                kind: .directURL,
                urlString: "https://motionbgs.com/dl/4k/\(id)",
                thumbnailURLString: normalizedImage,
                category: displayName(for: category)
            ))
        }
        return output
    }
}

private extension String {
    func substring(_ range: NSRange) -> String? {
        guard let swiftRange = Range(range, in: self) else { return nil }
        return String(self[swiftRange])
    }
}
