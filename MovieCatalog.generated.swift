import Foundation

// LiveWall movie catalog — curated direct video links.
//
// Each entry is a direct URL to a video file. Clicking a card downloads it
// locally, then it can be played or set as a live background.
//
// IMPORTANT — format: the macOS video engine (AVFoundation) plays **.mp4 / .mov
// (H.264 or HEVC)**. It does NOT play .mkv containers or AV1-encoded video, so
// those download but won't play. Prefer 1080p MP4/H.264 links.
extension MovieCatalog {
    static let driveMovies: [MovieItem] = [
        MovieItem(
            title: "Cars (2006)",
            kind: .remoteMP4,
            urlString: "https://a.111477.xyz/movies/Cars%20(2006)/Cars.2006.1080p.BluRay.x265.DD+5.1-Pahe.in.mkv",
            requiresSignIn: false,
            posterURLString: nil
        ),
        MovieItem(
            title: "John Wick (2014)",
            kind: .remoteMP4,
            urlString: "https://a.111477.xyz/movies/John%20Wick%20(2014)/John.Wick.2014.1080p.BluRay.DDP.7.1.x265-EDGE2020.mkv-[N-Z-B]-xpost.mkv",
            requiresSignIn: false,
            posterURLString: nil
        ),
        MovieItem(
            title: "A Minecraft Movie (2025)",
            kind: .remoteMP4,
            urlString: "https://a.111477.xyz/movies/A%20Minecraft%20Movie%20(2025)/A.Minecraft.Movie.2025.1080p.WEBRip.DDP.Atmos.5.1.10bit.H.265-iVy.mkv",
            requiresSignIn: false,
            posterURLString: nil
        ),
        MovieItem(
            title: "Pixeldrain Movie",
            kind: .remoteMP4,
            urlString: "https://pixeldrain.dev/u/wHFztK9A",
            requiresSignIn: false,
            posterURLString: nil
        ),
    ]
}
