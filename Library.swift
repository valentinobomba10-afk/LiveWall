import AppKit
import AVFoundation

/// A saved wallpaper (template or user-added).
enum ItemKind: String, Codable {
    case localVideo, localImage, directURL, youTube, web

    var badgeIcon: String {
        switch self {
        case .localVideo: return "film.fill"
        case .localImage: return "photo.fill"
        case .directURL:  return "link"
        case .youTube:    return "play.rectangle.fill"
        case .web:        return "sparkles.rectangle.stack.fill"
        }
    }
}

struct LibraryItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var kind: ItemKind
    var bookmark: Data?
    var urlString: String?
    var thumbnailURLString: String?
    var youTubeID: String?
    var category: String?          // set when the source tells us (e.g. MotionBGS tag)
    var dateAdded = Date()

    init(id: UUID = UUID(), title: String, kind: ItemKind, bookmark: Data? = nil,
         urlString: String? = nil, thumbnailURLString: String? = nil,
         youTubeID: String? = nil, category: String? = nil, dateAdded: Date = Date()) {
        self.id = id; self.title = title; self.kind = kind; self.bookmark = bookmark
        self.urlString = urlString; self.thumbnailURLString = thumbnailURLString
        self.youTubeID = youTubeID; self.category = category; self.dateAdded = dateAdded
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, kind, bookmark, urlString, thumbnailURLString, youTubeID, category, dateAdded
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decode(String.self, forKey: .title)
        kind = try c.decode(ItemKind.self, forKey: .kind)
        bookmark = try c.decodeIfPresent(Data.self, forKey: .bookmark)
        urlString = try c.decodeIfPresent(String.self, forKey: .urlString)
        thumbnailURLString = try c.decodeIfPresent(String.self, forKey: .thumbnailURLString)
        youTubeID = try c.decodeIfPresent(String.self, forKey: .youTubeID)
        category = try c.decodeIfPresent(String.self, forKey: .category)
        dateAdded = try c.decodeIfPresent(Date.self, forKey: .dateAdded) ?? Date()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(title, forKey: .title); try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(bookmark, forKey: .bookmark); try c.encodeIfPresent(urlString, forKey: .urlString)
        try c.encodeIfPresent(thumbnailURLString, forKey: .thumbnailURLString)
        try c.encodeIfPresent(youTubeID, forKey: .youTubeID); try c.encodeIfPresent(category, forKey: .category)
        try c.encode(dateAdded, forKey: .dateAdded)
    }

    var subtitle: String {
        switch kind {
        case .localVideo: return "Local video"
        case .localImage: return "Picture background"
        case .directURL:  return URL(string: urlString ?? "")?.host ?? "Remote video"
        case .youTube:    return "YouTube"
        case .web:        return "Interactive"
        }
    }

    /// Resolve to a playable kind for the renderer, or nil if unavailable (moved file, bad URL).
    func wallpaperKind() -> WallpaperKind? {
        switch kind {
        case .localVideo:
            if let bookmark {
                var stale = false
                if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope],
                                      relativeTo: nil, bookmarkDataIsStale: &stale) {
                    _ = url.startAccessingSecurityScopedResource()
                    return .localVideo(url)
                }
            }
            if let s = urlString, let url = URL(string: s), url.isFileURL { return .localVideo(url) }
            return nil
        case .localImage:
            if let bookmark {
                var stale = false
                if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope],
                                      relativeTo: nil, bookmarkDataIsStale: &stale) {
                    _ = url.startAccessingSecurityScopedResource()
                    return .localImage(url)
                }
            }
            if let s = urlString, let url = URL(string: s), url.isFileURL { return .localImage(url) }
            return nil
        case .directURL:
            guard let s = urlString, let url = URL(string: s) else { return nil }
            return .directURL(url)
        case .youTube:
            guard let id = youTubeID else { return nil }
            return .youTube(id)
        case .web:
            guard let s = urlString, let url = URL(string: s) else { return nil }
            return .web(url)
        }
    }

    /// Standard YouTube thumbnail image (a normal image request — not stream extraction).
    var youTubeThumbnailURL: URL? {
        guard kind == .youTube, let id = youTubeID else { return nil }
        return URL(string: "https://img.youtube.com/vi/\(id)/hqdefault.jpg")
    }

    /// MotionBGS serves small poster images separately from the large 4K video.
    /// Use those for the Gallery so cards load quickly without opening videos.
    var remoteThumbnailURLs: [URL] {
        if let thumbnailURLString {
            // WallpaperWaves exposes a preview MP4 and a matching still image.
            // AsyncImage must receive the still image, never the MP4 preview.
            let imageString = thumbnailURLString.replacingOccurrences(of: "-preview.mp4", with: "-wallpaperwaves-com.webp")
            if let imageURL = URL(string: imageString) { return [imageURL] }
        }
        guard kind == .directURL, let source = urlString, let sourceURL = URL(string: source),
              sourceURL.host?.contains("motionbgs.com") == true else { return [] }
        let parts = sourceURL.pathComponents
        guard let id = parts.last, id.allSatisfy({ $0.isNumber }) else { return [] }
        let prefix = title.replacingOccurrences(of: "MotionBGS · ", with: "")
        let slug = prefix.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        guard !slug.isEmpty else { return [] }

        // MotionBGS occasionally uses a slightly different slug than its title.
        // Try common filename variants before showing the generated fallback.
        var slugs = [slug]
        let compact = slug.replacingOccurrences(of: "-", with: "")
        if compact != slug { slugs.append(compact) }
        let simplified = slug
            .replacingOccurrences(of: "-wallpaper", with: "")
            .replacingOccurrences(of: "-live-background", with: "")
        if simplified != slug { slugs.append(simplified) }
        return slugs.flatMap { slug in
            [
                "https://motionbgs.com/i/c/256x144/media/\(id)/\(slug).jpg",
                "https://motionbgs.com/i/c/256x144/media/\(id)/\(slug).jpg.webp",
                "https://motionbgs.com/i/c/256x144/media/\(id)/\(slug).3840x2160.jpg",
                "https://motionbgs.com/i/c/364x205/media/\(id)/\(slug).jpg"
            ].compactMap(URL.init(string:))
        }
    }

    var remoteThumbnailURL: URL? { remoteThumbnailURLs.first }
}

final class LibraryStore: ObservableObject {
    @Published private(set) var items: [LibraryItem] = []
    private let fileURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("LiveWall", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("library.json")
        load()
    }

    func add(_ item: LibraryItem) { items.insert(item, at: 0); save() }
    func remove(_ id: UUID) { items.removeAll { $0.id == id }; save() }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([LibraryItem].self, from: data) else { return }
        items = decoded
    }
    private func save() {
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: fileURL, options: .atomic) }
    }
}

/// Generates a still frame for local / direct video thumbnails.
enum ThumbnailGenerator {
    static func frame(url: URL) async -> NSImage? {
        // Only extract frames from local files. Opening a remote video just to
        // grab a poster frame stalls badly and was a source of UI freezes.
        guard url.isFileURL else { return nil }
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1600, height: 900)
        let time = CMTime(seconds: 1, preferredTimescale: 60)
        return await withCheckedContinuation { (cont: CheckedContinuation<NSImage?, Never>) in
            gen.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, cg, _, _, _ in
                if let cg {
                    cont.resume(returning: NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }
}
