import AppKit
import AVFoundation
import ScreenSaver

/// Screen saver companion for LiveWall.
///
/// macOS gives third-party apps no way to draw on the lock screen — `loginwindow`
/// owns that surface and the user session is not composited while locked. A screen
/// saver *is* hosted by `loginwindow`, so this bundle is how the same wallpaper
/// reaches the lock screen.
///
/// Everything it plays lives inside this bundle's own `Resources` (written by
/// `LockScreenService` in the main app), because the screen saver host runs
/// sandboxed and cannot read the user's Movies/Pictures folders.
@objc(LiveWallSaverView)
final class LiveWallSaverView: ScreenSaverView {

    /// Written next to the media by the main app. Missing/invalid config == show black.
    private struct Config: Decodable {
        var kind: String            // "video" | "image"
        var file: String            // file name inside Contents/Resources
        var scaling: String?        // Fill | Fit | Stretch | Centre
        var muted: Bool?
        var volume: Float?
        var brightness: Double?
        var saturation: Double?

        var gravity: AVLayerVideoGravity {
            switch scaling {
            case "Fit", "Centre": return .resizeAspect
            case "Stretch":       return .resize
            default:              return .resizeAspectFill
            }
        }
        var contentsGravity: CALayerContentsGravity {
            switch scaling {
            case "Fit", "Centre": return .resizeAspect
            case "Stretch":       return .resize
            default:              return .resizeAspectFill
            }
        }
    }

    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?          // strong ref required or looping stops
    private var playerLayer: AVPlayerLayer?
    private var imageLayer: CALayer?

    // MARK: - Lifecycle

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        // AVPlayerLayer drives its own frames; we never need -animateOneFrame.
        animationTimeInterval = 1.0 / 4.0
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        loadContent()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        animationTimeInterval = 1.0 / 4.0
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        loadContent()
    }

    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }

    override func startAnimation() {
        super.startAnimation()
        player?.play()
    }

    override func stopAnimation() {
        super.stopAnimation()
        player?.pause()
    }

    override func animateOneFrame() { /* content layers redraw themselves */ }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)   // no implicit fade when the host resizes us
        playerLayer?.frame = bounds
        imageLayer?.frame = bounds
        CATransaction.commit()
    }

    // MARK: - Content

    private func loadContent() {
        let bundle = Bundle(for: type(of: self))
        guard let configURL = bundle.url(forResource: "livewall-config", withExtension: "json"),
              let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(Config.self, from: data) else { return }

        let media = bundle.bundleURL
            .appendingPathComponent("Contents/Resources", isDirectory: true)
            .appendingPathComponent(config.file)
        guard FileManager.default.fileExists(atPath: media.path) else { return }

        switch config.kind {
        case "video": installVideo(media, config: config)
        case "image": installImage(media, config: config)
        default:      return
        }
        applyColorControls(brightness: config.brightness ?? 1, saturation: config.saturation ?? 1)
    }

    private func installVideo(_ url: URL, config: Config) {
        let item = AVPlayerItem(url: url)
        let queue = AVQueuePlayer()
        queue.isMuted = config.muted ?? true          // lock-screen audio is off unless asked for
        queue.volume = config.volume ?? 1
        queue.actionAtItemEnd = .advance
        looper = AVPlayerLooper(player: queue, templateItem: item)

        let layer = AVPlayerLayer(player: queue)
        layer.videoGravity = config.gravity
        layer.frame = bounds
        layer.backgroundColor = NSColor.black.cgColor
        self.layer?.addSublayer(layer)

        player = queue
        playerLayer = layer
        // The preview thumbnail in System Settings gets a frame without animating.
        if isPreview { queue.play() }
    }

    private func installImage(_ url: URL, config: Config) {
        guard let image = NSImage(contentsOf: url),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let layer = CALayer()
        layer.contents = cg
        layer.contentsGravity = config.contentsGravity
        layer.masksToBounds = true
        layer.frame = bounds
        self.layer?.addSublayer(layer)
        imageLayer = layer
    }

    /// Mirrors the brightness/saturation sliders in the main app.
    private func applyColorControls(brightness: Double, saturation: Double) {
        guard brightness != 1 || saturation != 1,
              let filter = CIFilter(name: "CIColorControls") else { return }
        filter.setValue(brightness - 1, forKey: kCIInputBrightnessKey)
        filter.setValue(saturation, forKey: kCIInputSaturationKey)
        layer?.filters = [filter]
    }
}
