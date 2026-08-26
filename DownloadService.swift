import Foundation
import AVFoundation

enum WallpaperDownloadService {
    static func download(_ item: LibraryItem, progress: @escaping (Double) -> Void = { _ in }) async throws -> LibraryItem {
        guard item.kind == .directURL, let source = item.urlString, let url = URL(string: source) else {
            throw NSError(domain: "LiveWall", code: 10, userInfo: [NSLocalizedDescriptionKey: "This template has no downloadable video URL."])
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let folder = base.appendingPathComponent("LiveWall/Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safe = item.title.replacingOccurrences(of: "[^A-Za-z0-9 -]", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        // MotionBGS provides separate HD and 4K endpoints. Keep a quality suffix
        // so older HD downloads are not accidentally reused after upgrading.
        let destination = folder.appendingPathComponent((safe.isEmpty ? UUID().uuidString : safe) + " 4K.mp4")
        if !FileManager.default.fileExists(atPath: destination.path) {
            let temporary = folder.appendingPathComponent(".\(UUID().uuidString).download")
            let (bytes, response) = try await URLSession.shared.bytes(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode < 400 else { throw NSError(domain: "LiveWall", code: 11, userInfo: [NSLocalizedDescriptionKey: "The download failed."]) }
            let type = http.mimeType?.lowercased() ?? ""
            let disposition = http.value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
            let sourceLooksLikeMP4 = source.lowercased().contains(".mp4")
            let responseNamesMP4 = disposition.contains(".mp4")
            // Cloud hosts (Google Drive, Dropbox, Supabase Storage) serve video
            // as octet-stream or via a redirect, so trust those hosts too.
            let host = (url.host ?? "").lowercased()
            let trustedHost = host.contains("google") || host.contains("dropbox")
                || host.contains("supabase") || host.contains("googleusercontent")
            // An HTML response means a login/scan page, not a video — a clear
            // sign the file isn't shared publicly.
            if type.contains("text/html") {
                throw NSError(domain: "LiveWall", code: 13, userInfo: [NSLocalizedDescriptionKey:
                    "That link returned a web page, not a video. Make sure the file is shared with “Anyone with the link.”"])
            }
            guard type.hasPrefix("video/") || type.contains("mpegurl") || type.contains("mp4")
                    || sourceLooksLikeMP4 || responseNamesMP4 || trustedHost || type.contains("octet-stream") else {
                throw NSError(domain: "LiveWall", code: 12, userInfo: [NSLocalizedDescriptionKey: "That URL is not a direct video file."])
            }
            FileManager.default.createFile(atPath: temporary.path, contents: nil)
            let handle = try FileHandle(forWritingTo: temporary)
            let expected = response.expectedContentLength
            var received: Int64 = 0
            var buffer = Data()
            buffer.reserveCapacity(1024 * 1024)
            do {
                for try await byte in bytes {
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
                try? FileManager.default.removeItem(at: temporary)
                throw error
            }
            try FileManager.default.moveItem(at: temporary, to: destination)
            progress(1)

            // Cap background videos at 3 hours. A longer file is almost never a
            // wallpaper and would sit huge on disk.
            let asset = AVURLAsset(url: destination)
            let seconds = CMTimeGetSeconds(asset.duration)
            if seconds.isFinite, seconds > 3 * 3600 {
                try? FileManager.default.removeItem(at: destination)
                throw NSError(domain: "LiveWall", code: 14, userInfo: [NSLocalizedDescriptionKey:
                    "That video is longer than 3 hours. Please use a shorter clip."])
            }
        }
        let bookmark = try? destination.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        return LibraryItem(title: item.title, kind: .localVideo, bookmark: bookmark, urlString: destination.absoluteString)
    }
}
