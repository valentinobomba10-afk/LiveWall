import AVFoundation
import AppKit

final class LocalVideoRenderer: WallpaperRenderer {
    private var player: AVPlayer?
    func load(source: WallpaperSource) async throws { let url: URL; if let local = source as? LocalVideoSource { url = local.url } else if let remote = source as? DirectVideoSource { url = remote.url } else { throw NSError(domain: "LiveWall", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid video source"]) }; player = AVPlayer(url: url) }
    func play() { player?.play() }; func pause() { player?.pause() }; func stop() { player?.pause(); player = nil }
    func setMuted(_ muted: Bool) { player?.isMuted = muted }; func setVolume(_ volume: Float) { player?.volume = volume }
}
