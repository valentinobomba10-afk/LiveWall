import Foundation

/// Turns share links from services like Google Drive into direct media URLs that
/// AVPlayer can actually stream.
enum RemoteLink {

    /// True for a Google Drive *folder* link, which can't be used directly — a
    /// folder isn't a single video.
    static func isGoogleDriveFolder(_ raw: String) -> Bool {
        let s = raw.lowercased()
        return s.contains("drive.google.com") && s.contains("/folders/")
    }

    /// Rewrites a Google Drive *file* share link into its direct-download form:
    ///   https://drive.google.com/file/d/ID/view  →  https://drive.google.com/uc?export=download&id=ID
    /// Non-Drive URLs are returned unchanged.
    static func normalized(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.lowercased().contains("drive.google.com"), let id = driveFileID(s) else { return s }
        // usercontent + confirm=t serves the bytes directly and skips the
        // "can't scan this large file" warning page that breaks big videos.
        return "https://drive.usercontent.google.com/download?id=\(id)&export=download&confirm=t"
    }

    /// Extracts the Drive file id from the two common link shapes.
    static func driveFileID(_ s: String) -> String? {
        if let r = s.range(of: "/file/d/") {
            let id = s[r.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            if id.count > 10 { return String(id) }
        }
        if let comps = URLComponents(string: s),
           let id = comps.queryItems?.first(where: { $0.name == "id" })?.value,
           id.count > 10 {
            return id
        }
        return nil
    }
}
