import Foundation
import SwiftUI
import AppKit

enum MovieKind: String, Codable, CaseIterable {
    case localMP4
    case remoteMP4
    case website
}

struct MovieItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var kind: MovieKind
    var urlString: String
    var dateAdded = Date()
    var requiresSignIn: Bool? = nil
    var posterURLString: String? = nil
    /// The catalog URL that produced a downloaded local copy. This keeps the
    /// downloaded card paired with its online entry across app launches.
    var sourceURLString: String? = nil

    /// A stable Google Drive page suitable for sharing or pasting into a
    /// browser. Downloaded items retain their original catalog URL in
    /// `sourceURLString`, so this also works after the movie is saved locally.
    var googleDriveShareURL: URL? {
        let source = sourceURLString ?? urlString
        guard let url = URL(string: source) else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var fileID = components?.queryItems?.first(where: { $0.name == "id" })?.value
        if fileID?.isEmpty != false {
            let parts = url.pathComponents
            if let index = parts.firstIndex(of: "d"), parts.index(after: index) < parts.endIndex {
                fileID = parts[parts.index(after: index)]
            }
        }
        guard let fileID, !fileID.isEmpty else { return nil }
        return URL(string: "https://drive.google.com/file/d/\(fileID)/view")
    }
}

enum MovieCatalog { }

@MainActor final class MovieStore: ObservableObject {
    @Published private(set) var items: [MovieItem] = []
    private let fileURL: URL
    private let movieDirectory: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("LiveWall", isDirectory: true)
        movieDirectory = directory.appendingPathComponent("Movies", isDirectory: true)
        fileURL = directory.appendingPathComponent("movies.json")
        try? FileManager.default.createDirectory(at: movieDirectory, withIntermediateDirectories: true)
        load()
    }

    @discardableResult
    func importMP4(from source: URL) -> MovieItem? {
        let ext = source.pathExtension.isEmpty ? "mp4" : source.pathExtension
        let safeName = source.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "/", with: "-")
        let destination = movieDirectory.appendingPathComponent("\(safeName)-\(UUID().uuidString.prefix(8)).\(ext)")
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            let item = MovieItem(title: source.deletingPathExtension().lastPathComponent,
                                 kind: .localMP4,
                                 urlString: destination.path)
            items.insert(item, at: 0)
            save()
            return item
        } catch {
            return nil
        }
    }

    /// Adds a movie without copying a potentially multi-gigabyte file. This is
    /// useful when the movie already has a permanent location on this Mac.
    @discardableResult
    func addLocalReference(from source: URL) -> MovieItem? {
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        if let existing = items.first(where: { $0.kind == .localMP4 && $0.urlString == source.path }) {
            return existing
        }
        let item = MovieItem(title: source.deletingPathExtension().lastPathComponent,
                             kind: .localMP4,
                             urlString: source.path)
        items.insert(item, at: 0)
        save()
        return item
    }

    @discardableResult
    func addWebsite(title: String, url: URL, posterURL: URL? = nil) -> MovieItem? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        let item = MovieItem(title: title.isEmpty ? (url.host ?? "Movie website") : title,
                             kind: .website,
                             urlString: url.absoluteString,
                             posterURLString: posterURL?.absoluteString)
        items.insert(item, at: 0)
        save()
        return item
    }

    func remove(_ item: MovieItem) {
        if item.kind == .localMP4 { try? FileManager.default.removeItem(atPath: item.urlString) }
        items.removeAll { $0.id == item.id }
        save()
    }

    func downloadedCopy(for item: MovieItem) -> MovieItem? {
        items.first {
            $0.kind == .localMP4 && $0.sourceURLString == item.urlString &&
            FileManager.default.fileExists(atPath: $0.urlString)
        }
    }

    func saveDownloaded(_ item: MovieItem) {
        if let source = item.sourceURLString {
            items.removeAll { $0.sourceURLString == source }
        }
        items.insert(item, at: 0)
        save()
    }

    func url(for item: MovieItem) -> URL? {
        if item.kind == .localMP4 { return URL(fileURLWithPath: item.urlString) }
        return URL(string: item.urlString)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([MovieItem].self, from: data) else { return }
        items = decoded.filter { item in
            // Old builds saved private Google Drive preview pages as website
            // cards. They cannot stream as wallpapers, so remove them rather
            // than leaving a locked/broken movie in the library.
            if item.kind == .website && item.urlString.contains("drive.google.com") { return false }
            if item.kind == .website && item.urlString.contains("1flex.org") { return false }
            return item.kind != .localMP4 || FileManager.default.fileExists(atPath: item.urlString)
        }
        if items.count != decoded.count { save() }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

enum MovieDownloadService {
    static func download(_ item: MovieItem, progress: @escaping @Sendable (Double) -> Void) async throws -> MovieItem {
        guard item.kind == .remoteMP4, let catalogURL = URL(string: item.urlString) else {
            throw failure("This movie does not have a downloadable video.")
        }
        let sourceURL = try await playableMP4URL(for: catalogURL)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = base.appendingPathComponent("LiveWall/Movies", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sourceID = driveFileID(from: catalogURL) ?? item.id.uuidString
        let safeTitle = item.title
            .replacingOccurrences(of: "[^A-Za-z0-9 -]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let destination = folder.appendingPathComponent("\(safeTitle.isEmpty ? "Movie" : safeTitle)-\(sourceID).mp4")

        if !FileManager.default.fileExists(atPath: destination.path) {
            let temporary = folder.appendingPathComponent(".\(UUID().uuidString).download")
            do {
                let (bytes, response) = try await URLSession.shared.bytes(from: sourceURL)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw failure("The movie download could not be started.")
                }
                let type = http.mimeType?.lowercased() ?? ""
                guard !type.contains("text/html") else {
                    throw failure("Google Drive returned a webpage instead of the movie.")
                }
                FileManager.default.createFile(atPath: temporary.path, contents: nil)
                let handle = try FileHandle(forWritingTo: temporary)
                let expected = response.expectedContentLength
                var received: Int64 = 0
                var buffer = Data()
                buffer.reserveCapacity(1024 * 1024)
                do {
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        buffer.append(byte)
                        received += 1
                        if buffer.count >= 1024 * 1024 {
                            try handle.write(contentsOf: buffer)
                            buffer.removeAll(keepingCapacity: true)
                            if expected > 0 { progress(min(Double(received) / Double(expected), 1)) }
                        }
                    }
                    if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
                    try handle.close()
                } catch {
                    try? handle.close()
                    throw error
                }
                try FileManager.default.moveItem(at: temporary, to: destination)
                progress(1)
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                throw error
            }
        } else {
            progress(1)
        }

        return MovieItem(id: item.id, title: item.title, kind: .localMP4,
                         urlString: destination.path, dateAdded: Date(),
                         requiresSignIn: false, posterURLString: item.posterURLString,
                         sourceURLString: item.urlString)
    }

    /// Drive's original can be MKV, which AVPlayer cannot decode. Its preview
    /// metadata supplies a signed progressive MP4 rendition that can be saved
    /// and played natively on macOS.
    private static func playableMP4URL(for catalogURL: URL) async throws -> URL {
        guard let fileID = driveFileID(from: catalogURL),
              let infoURL = URL(string: "https://drive.google.com/get_video_info?docid=\(fileID)") else {
            return catalogURL
        }
        let (data, response) = try await URLSession.shared.data(from: infoURL)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let body = String(data: data, encoding: .utf8) else {
            throw failure("Google Drive could not prepare this movie for download.")
        }
        var components = URLComponents()
        components.percentEncodedQuery = body
        let items = components.queryItems ?? []
        guard items.first(where: { $0.name == "status" })?.value == "ok" else {
            throw failure("This Google Drive movie is unavailable or private.")
        }
        if let responseJSON = items.first(where: { $0.name == "player_response" })?.value,
           let jsonData = responseJSON.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
           let streaming = json["streamingData"] as? [String: Any],
           let formats = streaming["formats"] as? [[String: Any]] {
            let playable = formats.compactMap { format -> (Int, URL)? in
                guard let value = format["url"] as? String, let url = URL(string: value) else { return nil }
                return (format["height"] as? Int ?? 0, url)
            }
            if let best = playable.max(by: { $0.0 < $1.0 }) { return best.1 }
        }
        if let map = items.first(where: { $0.name == "fmt_stream_map" })?.value {
            for entry in map.split(separator: ",") {
                let pair = entry.split(separator: "|", maxSplits: 1).map(String.init)
                if pair.count == 2, let url = URL(string: pair[1]) { return url }
            }
        }
        throw failure("Google Drive did not provide a compatible MP4 for this movie.")
    }

    private static func driveFileID(from url: URL) -> String? {
        if let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "id" })?.value, !id.isEmpty { return id }
        let parts = url.pathComponents
        if let index = parts.firstIndex(of: "d"), parts.index(after: index) < parts.endIndex {
            return parts[parts.index(after: index)]
        }
        return nil
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "LiveWall.MovieDownload", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
