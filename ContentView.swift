import AppKit
import AVKit
import UniformTypeIdentifiers

/// The control panel window's content. Pure AppKit so it builds without a SwiftUI module.
final class ContentView: NSView {
    private let controller: WallpaperController
    private let displays: DisplayObserver

    private let subtitleLabel = NSTextField(labelWithString:
        "A desktop-level live-wallpaper overlay — LiveWall does not replace the macOS system wallpaper.")
    private let urlField = NSTextField()
    private let preview = AVPlayerView()
    private let statusLabel = NSTextField(labelWithString:
        "Choose a local video or paste a video / YouTube URL to begin.")

    private let playButton = NSButton(title: "Play", target: nil, action: nil)
    private let muteButton = NSButton(title: "Unmute", target: nil, action: nil)
    private let loopCheckbox = NSButton(checkboxWithTitle: "Loop", target: nil, action: nil)
    private let scalingPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let volumeSlider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let displaysStack = NSStackView()

    private var previewPlayer: AVPlayer?
    private var draftKind: WallpaperKind?
    private var muted = true
    private var selectedDisplayIDs = Set<CGDirectDisplayID>()

    init(controller: WallpaperController, displays: DisplayObserver, frame: NSRect) {
        self.controller = controller
        self.displays = displays
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        build()
        displays.addHandler { [weak self] in self?.rebuildDisplayList() }
        rebuildDisplayList()
        updateButtons()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        let title = NSTextField(labelWithString: "LiveWall")
        title.font = .systemFont(ofSize: 30, weight: .bold)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.maximumNumberOfLines = 2

        let chooseButton = NSButton(title: "Choose Local Video…", target: self, action: #selector(chooseVideo))
        chooseButton.bezelStyle = .rounded
        urlField.placeholderString = "https://youtube.com/watch?v=…   or   https://…/video.mp4"
        urlField.lineBreakMode = .byTruncatingHead
        urlField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let addURLButton = NSButton(title: "Add URL", target: self, action: #selector(addURL))
        addURLButton.bezelStyle = .rounded
        let sourceRow = NSStackView(views: [chooseButton, urlField, addURLButton])
        sourceRow.orientation = .horizontal
        sourceRow.spacing = 8

        preview.controlsStyle = .floating
        preview.wantsLayer = true

        playButton.bezelStyle = .rounded
        playButton.target = self; playButton.action = #selector(togglePlay)
        muteButton.bezelStyle = .rounded
        muteButton.target = self; muteButton.action = #selector(toggleMute)
        loopCheckbox.state = .on
        scalingPopup.addItems(withTitles: ScalingMode.allCases.map { $0.rawValue })
        scalingPopup.selectItem(withTitle: ScalingMode.fill.rawValue)
        scalingPopup.target = self; scalingPopup.action = #selector(scalingChanged)
        volumeSlider.target = self; volumeSlider.action = #selector(volumeChanged)
        let scalingLabel = NSTextField(labelWithString: "Scaling"); scalingLabel.textColor = .secondaryLabelColor
        let volumeLabel = NSTextField(labelWithString: "Volume");  volumeLabel.textColor = .secondaryLabelColor
        let controlsRow = NSStackView(views: [playButton, muteButton, loopCheckbox,
                                              scalingLabel, scalingPopup, volumeLabel, volumeSlider])
        controlsRow.orientation = .horizontal
        controlsRow.spacing = 10

        let displaysTitle = NSTextField(labelWithString: "Displays")
        displaysTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        displaysStack.orientation = .vertical
        displaysStack.alignment = .leading
        displaysStack.spacing = 4

        let setButton = NSButton(title: "Set as Live Wallpaper", target: self, action: #selector(setWallpaper))
        setButton.bezelStyle = .rounded
        setButton.keyEquivalent = "\r"
        let stopButton = NSButton(title: "Stop Wallpaper", target: self, action: #selector(stopWallpaper))
        stopButton.bezelStyle = .rounded
        let actionRow = NSStackView(views: [setButton, stopButton])
        actionRow.orientation = .horizontal
        actionRow.spacing = 10

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 2

        let stack = NSStackView(views: [title, subtitleLabel, sourceRow, preview, controlsRow,
                                        displaysTitle, displaysStack, actionRow, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -24),
            sourceRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            preview.widthAnchor.constraint(equalTo: stack.widthAnchor),
            preview.heightAnchor.constraint(equalToConstant: 320),
            actionRow.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        volumeSlider.widthAnchor.constraint(equalToConstant: 120).isActive = true
    }

    // MARK: - Actions

    @objc private func chooseVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draftKind = .localVideo(url)
        loadPreview(url: url)
        status("Loaded “\(url.lastPathComponent)”. Press “Set as Live Wallpaper”, or adjust options first.")
    }

    @objc private func addURL() {
        let text = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            status("Enter a valid http(s) video or YouTube URL.")
            return
        }
        if let id = YouTubeParser.videoID(from: text) {
            draftKind = .youTube(id)
            previewPlayer?.pause(); previewPlayer = nil; preview.player = nil
            status("YouTube video ready (\(id)). It plays on the wallpaper — press “Set as Live Wallpaper”.")
        } else {
            draftKind = .directURL(url)
            loadPreview(url: url)
            status("Loaded remote video. Press “Set as Live Wallpaper”.")
        }
        updateButtons()
    }

    private func loadPreview(url: URL) {
        previewPlayer?.pause()
        let p = AVPlayer(url: url)
        p.isMuted = muted
        p.volume = Float(volumeSlider.doubleValue)
        previewPlayer = p
        preview.player = p
        p.play()
        updateButtons()
    }

    @objc private func togglePlay() {
        if controller.isRunning {
            controller.isPaused ? controller.play() : controller.pause()
        } else if let p = previewPlayer {
            p.rate == 0 ? p.play() : p.pause()
        }
        updateButtons()
    }

    @objc private func toggleMute() {
        muted.toggle()
        previewPlayer?.isMuted = muted
        controller.setMuted(muted)
        updateButtons()
    }

    @objc private func scalingChanged() {
        if let mode = ScalingMode(rawValue: scalingPopup.titleOfSelectedItem ?? "") {
            controller.setScaling(mode)
        }
    }

    @objc private func volumeChanged() {
        let v = Float(volumeSlider.doubleValue)
        previewPlayer?.volume = v
        controller.setVolume(v)
    }

    @objc private func setWallpaper() {
        guard let kind = draftKind else { status("Choose a local video or add a URL first."); return }
        let ids = selectedDisplayIDs
        let request = WallpaperController.Request(
            kind: kind,
            muted: muted,
            volume: Float(volumeSlider.doubleValue),
            loops: loopCheckbox.state == .on,
            scaling: ScalingMode(rawValue: scalingPopup.titleOfSelectedItem ?? "") ?? .fill,
            displayIDs: ids)
        controller.setWallpaper(request)
        let count = max(ids.count, 1)
        status("Live wallpaper running on \(count) display\(count == 1 ? "" : "s"). Close this window to keep it playing.")
        updateButtons()
    }

    @objc private func stopWallpaper() {
        controller.stop()
        status("Live wallpaper stopped.")
        updateButtons()
    }

    // MARK: - Displays

    private func rebuildDisplayList() {
        displaysStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let screens = displays.screens
        let availIDs = Set(screens.map { DisplayObserver.displayID(for: $0) })
        selectedDisplayIDs.formIntersection(availIDs)
        if selectedDisplayIDs.isEmpty, let main = NSScreen.main ?? screens.first {
            selectedDisplayIDs = [DisplayObserver.displayID(for: main)]
        }
        for screen in screens {
            let id = DisplayObserver.displayID(for: screen)
            let w = Int(screen.frame.width), h = Int(screen.frame.height)
            let isMain = (screen == NSScreen.main)
            let cb = NSButton(checkboxWithTitle: "\(DisplayObserver.name(for: screen)) — \(w)×\(h)\(isMain ? "  (Main)" : "")",
                              target: self, action: #selector(displayToggled(_:)))
            cb.state = selectedDisplayIDs.contains(id) ? .on : .off
            cb.tag = Int(id)
            displaysStack.addArrangedSubview(cb)
        }
    }

    @objc private func displayToggled(_ sender: NSButton) {
        let id = CGDirectDisplayID(sender.tag)
        if sender.state == .on { selectedDisplayIDs.insert(id) } else { selectedDisplayIDs.remove(id) }
    }

    // MARK: - State

    private func updateButtons() {
        muteButton.title = muted ? "Unmute" : "Mute"
        if controller.isRunning {
            playButton.title = controller.isPaused ? "Play" : "Pause"
        } else if let p = previewPlayer {
            playButton.title = p.rate == 0 ? "Play" : "Pause"
        } else {
            playButton.title = "Play"
        }
    }

    private func status(_ text: String) { statusLabel.stringValue = text }
}
