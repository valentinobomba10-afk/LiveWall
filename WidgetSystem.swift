import AppKit
import SwiftUI

// MARK: - Model

/// The kinds of widget a user can place on the desktop.
enum WidgetKind: String, Codable, CaseIterable, Identifiable {
    case clock, image, appLauncher, shortcut, todo
    var id: String { rawValue }

    var title: String {
        switch self {
        case .clock:       return "Clock"
        case .image:       return "Image"
        case .appLauncher: return "App Launcher"
        case .shortcut:    return "Shortcut"
        case .todo:        return "To-Do"
        }
    }

    var icon: String {
        switch self {
        case .clock:       return "clock"
        case .image:       return "photo"
        case .appLauncher: return "app.badge"
        case .shortcut:    return "arrow.up.right.square"
        case .todo:        return "checklist"
        }
    }

    var summary: String {
        switch self {
        case .clock:       return "Digital or analog, any timezone."
        case .image:       return "Any picture from your Mac."
        case .appLauncher: return "One click to open an app."
        case .shortcut:    return "Open a site, file or folder."
        case .todo:        return "A checklist that lives on your desktop."
        }
    }

    var defaultSize: CGSize {
        switch self {
        case .clock:       return CGSize(width: 260, height: 120)
        case .image:       return CGSize(width: 280, height: 180)
        case .appLauncher: return CGSize(width: 96,  height: 96)
        case .shortcut:    return CGSize(width: 180, height: 64)
        case .todo:        return CGSize(width: 260, height: 220)
        }
    }
}

/// Visual presets. Each maps to a concrete set of style values so a user can get
/// a good-looking widget without touching every slider.
enum WidgetPreset: String, Codable, CaseIterable, Identifiable {
    case glass, minimal, dark, light, transparent, macOS, windows
    var id: String { rawValue }

    var title: String {
        switch self {
        case .macOS:   return "macOS"
        case .windows: return "Windows"
        default:       return rawValue.capitalized
        }
    }

    /// (backgroundOpacity, cornerRadius, blur, borderWidth, shadow, lightText)
    var style: WidgetStyle {
        switch self {
        case .glass:       return WidgetStyle(backgroundOpacity: 0.22, cornerRadius: 18, blur: 22, borderWidth: 1,   shadow: true,  lightText: true)
        case .minimal:     return WidgetStyle(backgroundOpacity: 0,    cornerRadius: 0,  blur: 0,  borderWidth: 0,   shadow: false, lightText: true)
        case .dark:        return WidgetStyle(backgroundOpacity: 0.72, cornerRadius: 14, blur: 0,  borderWidth: 0,   shadow: true,  lightText: true)
        case .light:       return WidgetStyle(backgroundOpacity: 0.82, cornerRadius: 14, blur: 0,  borderWidth: 0,   shadow: true,  lightText: false)
        case .transparent: return WidgetStyle(backgroundOpacity: 0,    cornerRadius: 0,  blur: 0,  borderWidth: 0,   shadow: true,  lightText: true)
        case .macOS:       return WidgetStyle(backgroundOpacity: 0.30, cornerRadius: 22, blur: 30, borderWidth: 0.5, shadow: true,  lightText: true)
        case .windows:     return WidgetStyle(backgroundOpacity: 0.55, cornerRadius: 8,  blur: 14, borderWidth: 0,   shadow: true,  lightText: true)
        }
    }
}

struct WidgetStyle: Codable, Hashable {
    var backgroundOpacity: Double = 0.22
    var cornerRadius: Double = 18
    var blur: Double = 22
    var borderWidth: Double = 1
    var shadow: Bool = true
    var lightText: Bool = true
    var opacity: Double = 1.0          // whole-widget opacity
    var padding: Double = 14
    var fontSize: Double = 34
    var fontName: String? = nil        // nil == system font
    var alignment: String = "center"   // leading | center | trailing

    var textAlignment: Alignment {
        switch alignment {
        case "leading":  return .leading
        case "trailing": return .trailing
        default:         return .center
        }
    }
    var multilineAlignment: TextAlignment {
        switch alignment {
        case "leading":  return .leading
        case "trailing": return .trailing
        default:         return .center
        }
    }
}

/// One line on a to-do widget.
struct TodoItem: Codable, Hashable, Identifiable {
    var id = UUID()
    var text: String = ""
    var done: Bool = false
}

/// Settings specific to one widget kind. Kept in a single flat struct so the
/// whole widget stays trivially Codable.
struct WidgetSettings: Codable, Hashable {
    // Clock
    var analog = false
    var use24Hour = false
    var showSeconds = false
    var showDate = true
    var timeZoneID: String? = nil      // nil == current timezone

    // Image / launcher icon
    var imagePath: String? = nil
    var imageMode: String = "fill"     // fit | fill | stretch
    var opensOnClick = false

    // App launcher / shortcut
    var targetPath: String? = nil      // app bundle, file or folder
    var targetURL: String? = nil       // website or custom URL
    var label: String? = nil

    // To-do
    var todos: [TodoItem] = []
}

/// One placed widget. Position is stored in the display's own coordinate space so
/// a widget stays put when displays are rearranged.
struct DesktopWidget: Codable, Identifiable, Hashable {
    var id = UUID()
    var kind: WidgetKind
    var displayID: UInt32
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var z: Int = 0
    var enabled = true
    var locked = false
    var style: WidgetStyle
    var settings = WidgetSettings()

    var frame: CGRect {
        get { CGRect(x: x, y: y, width: width, height: height) }
        set { x = newValue.minX; y = newValue.minY; width = newValue.width; height = newValue.height }
    }

    var displayName: String {
        if let label = settings.label, !label.isEmpty { return label }
        return kind.title
    }

    static func make(kind: WidgetKind, displayID: UInt32, preset: WidgetPreset = .glass) -> DesktopWidget {
        let size = kind.defaultSize
        return DesktopWidget(kind: kind, displayID: displayID,
                             x: 80, y: 80, width: size.width, height: size.height,
                             style: preset.style)
    }
}

// MARK: - Store

/// Owns the widget list and persists it. Saves are debounced because dragging a
/// widget mutates state on every frame.
@MainActor
final class WidgetStore: ObservableObject {
    @Published var widgets: [DesktopWidget] = [] { didSet { scheduleSave() } }
    @Published var editMode = false
    @Published var snapToGrid = true
    /// Opt-in "always on top". Off by default — widgets belong on the desktop,
    /// not over your work. Clickability does not depend on this; see applyLevel().
    @Published var floatOnTop = UserDefaults.standard.object(forKey: "widgetsFloatOnTop") as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(floatOnTop, forKey: "widgetsFloatOnTop")
            NotificationCenter.default.post(name: .liveWallWidgetLevelChanged, object: nil)
        }
    }

    /// One store shared by the desktop layer and the Widgets tab, so edits in
    /// the window appear on the desktop immediately.
    static let shared = WidgetStore()

    static let gridSize: CGFloat = 16

    private var saveWorkItem: DispatchWorkItem?

    private var fileURL: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("LiveWall", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("widgets.json")
    }

    init() { load() }

    func add(_ widget: DesktopWidget) {
        var w = widget
        w.z = (widgets.map(\.z).max() ?? 0) + 1
        widgets.append(w)
    }

    func remove(_ id: UUID) { widgets.removeAll { $0.id == id } }

    func duplicate(_ id: UUID) {
        guard let original = widgets.first(where: { $0.id == id }) else { return }
        var copy = original
        copy.id = UUID()
        copy.x += 24
        copy.y += 24
        add(copy)
    }

    func update(_ id: UUID, _ change: (inout DesktopWidget) -> Void) {
        guard let index = widgets.firstIndex(where: { $0.id == id }) else { return }
        change(&widgets[index])
    }

    func bringForward(_ id: UUID) {
        update(id) { $0.z = (widgets.map(\.z).max() ?? 0) + 1 }
    }

    func sendBackward(_ id: UUID) {
        update(id) { $0.z = (widgets.map(\.z).min() ?? 0) - 1 }
    }

    func widgets(on displayID: CGDirectDisplayID) -> [DesktopWidget] {
        widgets.filter { $0.displayID == displayID && $0.enabled }.sorted { $0.z < $1.z }
    }

    /// Rounds a point to the grid when snapping is on.
    func snap(_ point: CGPoint) -> CGPoint {
        guard snapToGrid else { return point }
        let g = Self.gridSize
        return CGPoint(x: (point.x / g).rounded() * g, y: (point.y / g).rounded() * g)
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(widgets) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let items = try? JSONDecoder().decode([DesktopWidget].self, from: data) else { return }
        widgets = items
    }
}

// MARK: - Desktop window layer

/// A borderless window sitting one level above the wallpaper overlay, holding the
/// widgets for a single display.
///
/// When edit mode is off the window ignores the mouse everywhere except the
/// widgets themselves, so the desktop and its icons stay fully usable.
final class WidgetHostWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless],
                   backing: .buffered, defer: false)
        applyLevel()
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        isMovable = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        setFrame(screen.frame, display: false)
    }

    /// Sits just above the desktop icon layer: below every ordinary window, so
    /// widgets never cover your work, but high enough that the window server
    /// delivers clicks here instead of to Finder. Plain desktop level looks the
    /// same but is completely inert.
    func applyLevel() {
        if WidgetStore.shared.floatOnTop {
            level = .floating
        } else {
            level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        }
    }
}

extension Notification.Name {
    static let liveWallWidgetLevelChanged = Notification.Name("LiveWallWidgetLevelChanged")
}

/// Hosting view that acts on the very first click.
///
/// By default AppKit uses the first click on a non-key window only to bring that
/// window forward and swallows it, so every widget needed clicking twice.
/// Accepting first mouse makes the initial click reach the widget.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    required init(rootView: Content) { super.init(rootView: rootView) }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Creates and tears down one `WidgetHostWindow` per display, and keeps them in
/// step as displays come and go.
@MainActor
final class WidgetLayerController {
    private var windows: [CGDirectDisplayID: WidgetHostWindow] = [:]
    private let store: WidgetStore
    private let displays: DisplayObserver

    init(store: WidgetStore, displays: DisplayObserver) {
        self.store = store
        self.displays = displays
        displays.addHandler { [weak self] in Task { @MainActor in self?.reconcile() } }
        NotificationCenter.default.addObserver(forName: .liveWallWidgetLevelChanged,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.windows.values.forEach { $0.applyLevel() } }
        }
        reconcile()
    }

    func reconcile() {
        let screens = displays.screens
        let present = Set(screens.map { DisplayObserver.displayID(for: $0) })

        for id in Set(windows.keys).subtracting(present) {
            windows[id]?.orderOut(nil)
            windows[id]?.contentView = nil
            windows[id] = nil
        }

        for screen in screens {
            let id = DisplayObserver.displayID(for: screen)
            if let existing = windows[id] {
                existing.setFrame(screen.frame, display: true)
                continue
            }
            let window = WidgetHostWindow(screen: screen)
            let canvas = WidgetCanvas(displayID: id, screenSize: screen.frame.size)
                .environmentObject(store)
            window.contentView = FirstMouseHostingView(rootView: canvas)
            window.orderFrontRegardless()
            windows[id] = window
        }
    }

    /// The main display's ID — where newly added widgets land by default.
    var primaryDisplayID: CGDirectDisplayID {
        if let main = NSScreen.main ?? displays.screens.first {
            return DisplayObserver.displayID(for: main)
        }
        return 0
    }
}

// MARK: - Canvas

/// Lays out every widget belonging to one display and handles dragging.
struct WidgetCanvas: View {
    let displayID: CGDirectDisplayID
    let screenSize: CGSize
    @EnvironmentObject var store: WidgetStore
    @State private var dragging: UUID?
    @State private var dragOrigin: CGPoint = .zero
    @State private var resizing: UUID?
    @State private var resizeOrigin: CGSize = .zero
    @State private var hovered: UUID?

    var body: some View {
        ZStack(alignment: .topLeading) {
            // In edit mode a faint grid makes snapping legible; otherwise the
            // canvas is entirely transparent and click-through.
            if store.editMode {
                Color.black.opacity(0.18)
                GridOverlay(spacing: WidgetStore.gridSize)
            }

            ForEach(store.widgets(on: displayID)) { widget in
                WidgetView(widget: widget)
                    .frame(width: widget.width, height: widget.height)
                    .offset(x: widget.x, y: widget.y)
                    .opacity(widget.style.opacity)
                    .overlay {
                        if store.editMode {
                            RoundedRectangle(cornerRadius: widget.style.cornerRadius, style: .continuous)
                                .strokeBorder(widget.locked ? Color.orange : Color.accentColor,
                                              style: StrokeStyle(lineWidth: 1.5, dash: widget.locked ? [4] : []))
                                .frame(width: widget.width, height: widget.height)
                                .offset(x: widget.x, y: widget.y)
                                .allowsHitTesting(false)
                        }
                    }
                    .gesture(dragGesture(for: widget))
                    .onHover { hovered = $0 ? widget.id : (hovered == widget.id ? nil : hovered) }
                    .overlay {
                        if !widget.locked, hovered == widget.id || resizing == widget.id {
                            resizeHandles(for: widget)
                                .frame(width: widget.width, height: widget.height)
                                .offset(x: widget.x, y: widget.y)
                                // Handles sit outside the widget, so the hover
                                // region has to extend past its bounds too.
                                .padding(16)
                                .onHover { inside in
                                    if inside { hovered = widget.id }
                                }
                        }
                    }
                    .contextMenu { menu(for: widget) }
            }
        }
        .frame(width: screenSize.width, height: screenSize.height, alignment: .topLeading)
        .ignoresSafeArea()
    }

    private func dragGesture(for widget: DesktopWidget) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard !widget.locked else { return }
                if dragging != widget.id {
                    dragging = widget.id
                    dragOrigin = CGPoint(x: widget.x, y: widget.y)
                }
                let moved = CGPoint(x: dragOrigin.x + value.translation.width,
                                    y: dragOrigin.y + value.translation.height)
                let snapped = store.snap(moved)
                store.update(widget.id) {
                    $0.x = min(max(0, snapped.x), screenSize.width - $0.width)
                    $0.y = min(max(0, snapped.y), screenSize.height - $0.height)
                }
            }
            .onEnded { _ in dragging = nil }
    }

    /// Four corner handles. Dragging one resizes from that corner, so the
    /// opposite corner stays put — the behaviour people expect from a window.
    private func resizeHandles(for widget: DesktopWidget) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: widget.style.cornerRadius, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.9), lineWidth: 1.5)
            ForEach(0..<4, id: \.self) { corner in
                let left = corner == 0 || corner == 2
                let top  = corner < 2
                Circle()
                    .fill(.white)
                    .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2))
                    .shadow(color: .black.opacity(0.4), radius: 2)
                    .frame(width: 14, height: 14)
                    // A generous invisible hit area around each dot: the visible
                    // 14pt circle was far too small to grab reliably.
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
                    // Straddle the corner so the handle is reachable from
                    // outside the widget as well as inside it.
                    .offset(x: left ? -8 : 8, y: top ? -8 : 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: Alignment(horizontal: left ? .leading : .trailing,
                                                vertical: top ? .top : .bottom))
                    // Must beat the widget's own move gesture.
                    .highPriorityGesture(resizeGesture(for: widget, left: left, top: top))
            }
        }
    }

    private func resizeGesture(for widget: DesktopWidget, left: Bool, top: Bool) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard !widget.locked else { return }
                if resizing != widget.id {
                    resizing = widget.id
                    resizeOrigin = CGSize(width: widget.width, height: widget.height)
                    dragOrigin = CGPoint(x: widget.x, y: widget.y)
                }
                let dx = value.translation.width
                let dy = value.translation.height
                // Dragging a left or top handle moves the origin as well as
                // resizing, so the opposite edge stays anchored.
                var newW = resizeOrigin.width  + (left ? -dx : dx)
                var newH = resizeOrigin.height + (top  ? -dy : dy)
                newW = max(48, newW)
                newH = max(48, newH)
                store.update(widget.id) {
                    if left { $0.x = max(0, dragOrigin.x + (resizeOrigin.width  - newW)) }
                    if top  { $0.y = max(0, dragOrigin.y + (resizeOrigin.height - newH)) }
                    $0.width  = min(newW, screenSize.width  - $0.x)
                    $0.height = min(newH, screenSize.height - $0.y)
                }
            }
            .onEnded { _ in
                // Settle onto the grid once, at the end.
                if let id = resizing {
                    store.update(id) {
                        let snapped = store.snap(CGPoint(x: $0.width, y: $0.height))
                        $0.width  = max(48, snapped.x)
                        $0.height = max(48, snapped.y)
                    }
                }
                resizing = nil
            }
    }

    @ViewBuilder private func menu(for widget: DesktopWidget) -> some View {
        Button(store.editMode ? "Leave Edit Mode" : "Edit Widgets") { store.editMode.toggle() }
        Divider()
        Button("Duplicate") { store.duplicate(widget.id) }
        Button(widget.locked ? "Unlock Position" : "Lock Position") {
            store.update(widget.id) { $0.locked.toggle() }
        }
        Button("Bring Forward") { store.bringForward(widget.id) }
        Button("Send Backward") { store.sendBackward(widget.id) }
        Divider()
        Button("Remove", role: .destructive) { store.remove(widget.id) }
    }
}

private struct GridOverlay: View {
    let spacing: CGFloat
    var body: some View {
        Canvas { context, size in
            var path = Path()
            var x: CGFloat = 0
            while x < size.width { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height)); x += spacing }
            var y: CGFloat = 0
            while y < size.height { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)); y += spacing }
            context.stroke(path, with: .color(.white.opacity(0.06)), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Widget rendering

struct WidgetView: View {
    let widget: DesktopWidget

    var body: some View {
        content
            .padding(widget.style.padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: widget.style.textAlignment)
            .background {
                ZStack {
                    if widget.style.blur > 0 {
                        RoundedRectangle(cornerRadius: widget.style.cornerRadius, style: .continuous)
                            .fill(.ultraThinMaterial)
                    }
                    RoundedRectangle(cornerRadius: widget.style.cornerRadius, style: .continuous)
                        .fill((widget.style.lightText ? Color.black : Color.white)
                            .opacity(widget.style.backgroundOpacity))
                }
            }
            .overlay {
                if widget.style.borderWidth > 0 {
                    RoundedRectangle(cornerRadius: widget.style.cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.25), lineWidth: widget.style.borderWidth)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: widget.style.cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(widget.style.shadow ? 0.35 : 0),
                    radius: widget.style.shadow ? 14 : 0, y: 6)
            .foregroundStyle(widget.style.lightText ? .white : .black)
    }

    @ViewBuilder private var content: some View {
        switch widget.kind {
        case .clock:       ClockWidgetView(widget: widget)
        case .image:       ImageWidgetView(widget: widget)
        case .appLauncher: AppLauncherWidgetView(widget: widget)
        case .shortcut:    ShortcutWidgetView(widget: widget)
        case .todo:        TodoWidgetView(widget: widget)
        }
    }
}

/// Clock widget — digital or analog, any timezone, optional seconds and date.
struct ClockWidgetView: View {
    let widget: DesktopWidget
    @State private var now = Date()

    // One shared timer per widget. Ticks every second only when seconds or the
    // analog sweep are actually visible, otherwise every 20s — this is the main
    // lever on idle CPU use.
    private var tickInterval: TimeInterval {
        (widget.settings.showSeconds || widget.settings.analog) ? 1 : 20
    }

    private var timeZone: TimeZone {
        widget.settings.timeZoneID.flatMap(TimeZone.init(identifier:)) ?? .current
    }

    var body: some View {
        Group {
            if widget.settings.analog {
                AnalogClockFace(date: now, timeZone: timeZone, light: widget.style.lightText)
            } else {
                VStack(spacing: 2) {
                    Text(timeString)
                        .font(font(size: widget.style.fontSize))
                        .monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.2)
                    if widget.settings.showDate {
                        Text(dateString)
                            .font(font(size: max(11, widget.style.fontSize * 0.32)))
                            .opacity(0.75)
                            .lineLimit(1).minimumScaleFactor(0.3)
                    }
                }
                .multilineTextAlignment(widget.style.multilineAlignment)
            }
        }
        .onReceive(Timer.publish(every: tickInterval, on: .main, in: .common).autoconnect()) { now = $0 }
    }

    private func font(size: Double) -> Font {
        if let name = widget.style.fontName, !name.isEmpty {
            return .custom(name, size: size)
        }
        return .system(size: size, weight: .semibold)
    }

    private var timeString: String {
        let f = DateFormatter()
        f.timeZone = timeZone
        let base = widget.settings.use24Hour ? "HH:mm" : "h:mm"
        f.dateFormat = widget.settings.showSeconds ? base + ":ss" : base
        if !widget.settings.use24Hour { f.dateFormat! += " a" }
        return f.string(from: now)
    }

    private var dateString: String {
        let f = DateFormatter()
        f.timeZone = timeZone
        f.dateFormat = "EEEE, d MMMM"
        return f.string(from: now)
    }
}

private struct AnalogClockFace: View {
    let date: Date
    let timeZone: TimeZone
    let light: Bool

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let centre = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let tint = light ? Color.white : Color.black

            ZStack {
                Circle()
                    .strokeBorder(tint.opacity(0.35), lineWidth: 2)
                    .frame(width: size, height: size)

                ForEach(0..<12, id: \.self) { i in
                    Rectangle()
                        .fill(tint.opacity(0.5))
                        .frame(width: 2, height: size * 0.06)
                        .offset(y: -size * 0.42)
                        .rotationEffect(.degrees(Double(i) * 30))
                }

                hand(length: size * 0.26, width: 4, angle: hourAngle, tint: tint)
                hand(length: size * 0.36, width: 3, angle: minuteAngle, tint: tint)
                hand(length: size * 0.40, width: 1, angle: secondAngle, tint: .red)

                Circle().fill(tint).frame(width: 6, height: 6)
            }
            .position(centre)
        }
    }

    private func hand(length: CGFloat, width: CGFloat, angle: Double, tint: Color) -> some View {
        Capsule()
            .fill(tint)
            .frame(width: width, height: length)
            .offset(y: -length / 2)
            .rotationEffect(.degrees(angle))
    }

    private var components: DateComponents {
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        return calendar.dateComponents([.hour, .minute, .second], from: date)
    }
    private var hourAngle: Double {
        let h = Double(components.hour ?? 0).truncatingRemainder(dividingBy: 12)
        return h * 30 + Double(components.minute ?? 0) * 0.5
    }
    private var minuteAngle: Double { Double(components.minute ?? 0) * 6 }
    private var secondAngle: Double { Double(components.second ?? 0) * 6 }
}

/// Stand-in for the widget kinds that are modelled and placeable but whose
/// content is not implemented yet.
struct PlaceholderWidgetView: View {
    let widget: DesktopWidget
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: widget.kind.icon).font(.system(size: 22))
            Text(widget.displayName).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Text("Not built yet").font(.system(size: 10)).opacity(0.6)
        }
    }
}

// MARK: - Widgets tab

/// Manager + gallery. Lists every placed widget with an enable switch, and gives
/// the selected widget a theme picker and its kind-specific options.
struct WidgetsScreen: View {
    @ObservedObject var store = WidgetStore.shared
    let primaryDisplayID: UInt32
    @State private var selected: UUID?
    @State private var showGallery = false
    @State private var cornerMargin: Double = 24

    private var selectedWidget: DesktopWidget? {
        store.widgets.first { $0.id == selected }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Widgets")
                    .font(.system(size: 38, weight: .bold)).foregroundStyle(Palette.text)
                    .padding(.top, 72)

                HStack(spacing: 10) {
                    Button { showGallery = true } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus").font(.system(size: 14, weight: .semibold))
                            Text("Add Widget").font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundStyle(Palette.text)
                        .padding(.horizontal, 22).padding(.vertical, 13)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }.buttonStyle(.plain)

                    Toggle("Edit Mode", isOn: $store.editMode)
                        .toggleStyle(.switch).tint(.accentColor)
                        .font(.system(size: 13)).foregroundStyle(Palette.text)
                        .padding(.leading, 8)

                    Toggle("Float Above Windows", isOn: $store.floatOnTop)
                        .toggleStyle(.switch).tint(.accentColor)
                        .font(.system(size: 13)).foregroundStyle(Palette.text)

                    Toggle("Snap to Grid", isOn: $store.snapToGrid)
                        .toggleStyle(.switch).tint(.accentColor)
                        .font(.system(size: 13)).foregroundStyle(Palette.text)
                    Spacer()
                }

                if store.widgets.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "square.grid.2x2").font(.system(size: 34)).foregroundStyle(Palette.tertiary)
                        Text("No widgets yet").font(.system(size: 16, weight: .semibold)).foregroundStyle(Palette.text)
                        Text("Add one and it appears on your desktop, on top of the wallpaper.")
                            .font(.system(size: 12.5)).foregroundStyle(Palette.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 50)
                } else {
                    VStack(spacing: 8) {
                        ForEach(store.widgets) { widget in
                            row(widget)
                        }
                    }
                }

                if let widget = selectedWidget {
                    editor(widget)
                }
            }
            .padding(.horizontal, 28).padding(.bottom, 50)
        }
        .sheet(isPresented: $showGallery) { gallery }
    }

    private func row(_ widget: DesktopWidget) -> some View {
        let active = selected == widget.id
        return HStack(spacing: 12) {
            Image(systemName: widget.kind.icon)
                .font(.system(size: 15)).frame(width: 22)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(widget.displayName).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.text)
                Text("\(Int(widget.width))×\(Int(widget.height))  ·  Display \(widget.displayID)")
                    .font(.system(size: 11)).foregroundStyle(Palette.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { widget.enabled },
                set: { value in store.update(widget.id) { $0.enabled = value } }))
                .toggleStyle(.switch).tint(.accentColor).labelsHidden()
            Button { store.duplicate(widget.id) } label: {
                Image(systemName: "plus.square.on.square").foregroundStyle(Palette.secondary)
            }.buttonStyle(.plain)
            Button { store.remove(widget.id); if selected == widget.id { selected = nil } } label: {
                Image(systemName: "trash").foregroundStyle(Palette.secondary)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(active ? Palette.chipHover : Palette.chip,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { selected = active ? nil : widget.id }
    }

    // MARK: Editor

    @ViewBuilder private func editor(_ widget: DesktopWidget) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Theme").font(.system(size: 19, weight: .bold)).foregroundStyle(Palette.text)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 116, maximum: 180), spacing: 10)], spacing: 10) {
                ForEach(WidgetPreset.allCases) { preset in
                    themeSwatch(preset, for: widget)
                }
            }

            if widget.kind == .clock {
                Text("Clock").font(.system(size: 19, weight: .bold)).foregroundStyle(Palette.text).padding(.top, 4)
                VStack(spacing: 10) {
                    optionToggle("Analog face", widget.settings.analog) { v in
                        store.update(widget.id) { $0.settings.analog = v }
                    }
                    optionToggle("24-hour time", widget.settings.use24Hour) { v in
                        store.update(widget.id) { $0.settings.use24Hour = v }
                    }
                    optionToggle("Show seconds", widget.settings.showSeconds) { v in
                        store.update(widget.id) { $0.settings.showSeconds = v }
                    }
                    optionToggle("Show date", widget.settings.showDate) { v in
                        store.update(widget.id) { $0.settings.showDate = v }
                    }
                    HStack {
                        Text("Timezone").font(.system(size: 13)).foregroundStyle(Palette.text)
                        Spacer()
                        Picker("", selection: Binding(
                            get: { widget.settings.timeZoneID ?? "" },
                            set: { value in store.update(widget.id) { $0.settings.timeZoneID = value.isEmpty ? nil : value } })) {
                                Text("Current").tag("")
                                ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden().frame(width: 220)
                    }
                }
            }

            if widget.kind != .clock {
                Text(widget.kind.title).font(.system(size: 19, weight: .bold))
                    .foregroundStyle(Palette.text).padding(.top, 4)
                VStack(spacing: 10) {
                    if widget.kind == .image {
                        fileRow("Image", value: widget.settings.imagePath,
                                types: ["public.image"], chooseDirectories: false) { path in
                            WidgetOpener.invalidate(path)
                            store.update(widget.id) { $0.settings.imagePath = path }
                        }
                        pickerRow("Fit mode", options: ["fill", "fit", "stretch"],
                                  value: widget.settings.imageMode) { mode in
                            store.update(widget.id) { $0.settings.imageMode = mode }
                        }
                        optionToggle("Open original on click", widget.settings.opensOnClick) { v in
                            store.update(widget.id) { $0.settings.opensOnClick = v }
                        }
                    }

                    if widget.kind == .appLauncher {
                        fileRow("Application", value: widget.settings.targetPath,
                                types: ["com.apple.application-bundle"], chooseDirectories: false) { path in
                            store.update(widget.id) {
                                $0.settings.targetPath = path
                                if ($0.settings.label ?? "").isEmpty {
                                    $0.settings.label = WidgetOpener.defaultName(forPath: path)
                                }
                            }
                        }
                        fileRow("Custom icon", value: widget.settings.imagePath,
                                types: ["public.image"], chooseDirectories: false) { path in
                            WidgetOpener.invalidate(path)
                            store.update(widget.id) { $0.settings.imagePath = path }
                        }
                    }

                    if widget.kind == .todo {
                        ForEach(widget.settings.todos) { item in
                            HStack(spacing: 8) {
                                Button {
                                    store.update(widget.id) { w in
                                        guard let i = w.settings.todos.firstIndex(where: { $0.id == item.id }) else { return }
                                        w.settings.todos[i].done.toggle()
                                    }
                                } label: {
                                    Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(item.done ? Color.accentColor : Palette.secondary)
                                }.buttonStyle(.plain)

                                TextField("Item", text: Binding(
                                    get: { item.text },
                                    set: { text in
                                        store.update(widget.id) { w in
                                            guard let i = w.settings.todos.firstIndex(where: { $0.id == item.id }) else { return }
                                            w.settings.todos[i].text = text
                                        }
                                    }))
                                    .textFieldStyle(.roundedBorder).font(.system(size: 12))

                                Button {
                                    store.update(widget.id) { w in
                                        w.settings.todos.removeAll { $0.id == item.id }
                                    }
                                } label: {
                                    Image(systemName: "trash").foregroundStyle(Palette.secondary)
                                }.buttonStyle(.plain)
                            }
                        }

                        HStack(spacing: 10) {
                            Button {
                                store.update(widget.id) { $0.settings.todos.append(TodoItem()) }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                                    Text("Add item").font(.system(size: 12, weight: .medium))
                                }
                                .foregroundStyle(Color.accentColor)
                            }.buttonStyle(.plain)

                            if widget.settings.todos.contains(where: \.done) {
                                Button {
                                    store.update(widget.id) { $0.settings.todos.removeAll { $0.done } }
                                } label: {
                                    Text("Clear completed").font(.system(size: 12))
                                        .foregroundStyle(Palette.secondary)
                                }.buttonStyle(.plain)
                            }
                            Spacer()
                        }
                    }

                    if widget.kind == .shortcut {
                        textRow("Website / URL", value: widget.settings.targetURL ?? "",
                                placeholder: "example.com") { text in
                            store.update(widget.id) { $0.settings.targetURL = text }
                        }
                        fileRow("File, folder or app", value: widget.settings.targetPath,
                                types: nil, chooseDirectories: true) { path in
                            store.update(widget.id) { $0.settings.targetPath = path }
                        }
                        fileRow("Custom icon", value: widget.settings.imagePath,
                                types: ["public.image"], chooseDirectories: false) { path in
                            WidgetOpener.invalidate(path)
                            store.update(widget.id) { $0.settings.imagePath = path }
                        }
                    }

                    textRow("Name", value: widget.settings.label ?? "",
                            placeholder: widget.kind.title) { text in
                        store.update(widget.id) { $0.settings.label = text }
                    }
                }
            }

            Text("Position").font(.system(size: 19, weight: .bold)).foregroundStyle(Palette.text).padding(.top, 4)
            HStack(alignment: .top, spacing: 16) {
                cornerPicker(widget)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Snap the widget to a corner, edge or the centre of its display.")
                        .font(.system(size: 12)).foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Text("Margin").font(.system(size: 12)).foregroundStyle(Palette.text)
                        Slider(value: $cornerMargin, in: 0...120).frame(width: 150)
                        Text("\(Int(cornerMargin))").font(.system(size: 12)).monospacedDigit()
                            .foregroundStyle(Palette.secondary)
                    }
                }
                Spacer()
            }

            Text("Size & Look").font(.system(size: 19, weight: .bold)).foregroundStyle(Palette.text).padding(.top, 4)
            slider("Width",   widget.width, 60...900) { v in store.update(widget.id) { $0.width = v } }
            slider("Height",  widget.height, 60...700) { v in store.update(widget.id) { $0.height = v } }
            slider("Text size", widget.style.fontSize, 10...120) { v in store.update(widget.id) { $0.style.fontSize = v } }
            slider("Opacity", widget.style.opacity, 0.1...1) { v in store.update(widget.id) { $0.style.opacity = v } }
            slider("Background", widget.style.backgroundOpacity, 0...1) { v in store.update(widget.id) { $0.style.backgroundOpacity = v } }
            slider("Blur", widget.style.blur, 0...40) { v in store.update(widget.id) { $0.style.blur = v } }
            slider("Corner radius", widget.style.cornerRadius, 0...40) { v in store.update(widget.id) { $0.style.cornerRadius = v } }
            slider("Border", widget.style.borderWidth, 0...6) { v in store.update(widget.id) { $0.style.borderWidth = v } }
            slider("Padding", widget.style.padding, 0...50) { v in store.update(widget.id) { $0.style.padding = v } }
            optionToggle("Shadow", widget.style.shadow) { v in store.update(widget.id) { $0.style.shadow = v } }
            optionToggle("Light text", widget.style.lightText) { v in store.update(widget.id) { $0.style.lightText = v } }
        }
        .padding(18)
        .background(Palette.chip, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// A live preview of the preset, rendered with the real widget view so the
    /// swatch always matches what lands on the desktop.
    private func themeSwatch(_ preset: WidgetPreset, for widget: DesktopWidget) -> some View {
        var preview = widget
        preview.style = merged(preset.style, keeping: widget.style)
        return Button {
            store.update(widget.id) { $0.style = merged(preset.style, keeping: $0.style) }
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    LinearGradient(colors: [.purple.opacity(0.55), .blue.opacity(0.45)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    WidgetView(widget: preview).frame(width: 104, height: 52)
                }
                .frame(height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(preset.title).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.text)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(isCurrent(preset, widget) ? 1 : 0), lineWidth: 2))
        }.buttonStyle(.plain)
    }

    /// Applying a preset changes the look, not the things the user has sized by
    /// hand — text size, padding and whole-widget opacity are carried over.
    private func merged(_ preset: WidgetStyle, keeping current: WidgetStyle) -> WidgetStyle {
        var style = preset
        style.fontSize = current.fontSize
        style.fontName = current.fontName
        style.padding = current.padding
        style.opacity = current.opacity
        style.alignment = current.alignment
        return style
    }

    private func isCurrent(_ preset: WidgetPreset, _ widget: DesktopWidget) -> Bool {
        let a = preset.style, b = widget.style
        return a.backgroundOpacity == b.backgroundOpacity && a.cornerRadius == b.cornerRadius
            && a.blur == b.blur && a.borderWidth == b.borderWidth && a.lightText == b.lightText
    }

    /// Nine-point anchor picker: corners, edge midpoints and centre.
    private func cornerPicker(_ widget: DesktopWidget) -> some View {
        let rows: [[(String, Double, Double)]] = [
            [("arrow.up.left", 0, 0),   ("arrow.up", 0.5, 0),   ("arrow.up.right", 1, 0)],
            [("arrow.left", 0, 0.5),    ("circle", 0.5, 0.5),   ("arrow.right", 1, 0.5)],
            [("arrow.down.left", 0, 1), ("arrow.down", 0.5, 1), ("arrow.down.right", 1, 1)],
        ]
        return VStack(spacing: 6) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 6) {
                    ForEach(rows[r].indices, id: \.self) { c in
                        let (icon, ax, ay) = rows[r][c]
                        Button { place(widget, anchorX: ax, anchorY: ay) } label: {
                            Image(systemName: icon)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Palette.text)
                                .frame(width: 32, height: 32)
                                .background(Palette.chipHover, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// Moves the widget to an anchor on its own display, honouring the margin.
    /// Centre anchors ignore the margin so the widget lands truly centred.
    private func place(_ widget: DesktopWidget, anchorX: Double, anchorY: Double) {
        let screen = NSScreen.screens.first {
            (($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0) == widget.displayID
        } ?? NSScreen.main
        guard let size = screen?.frame.size else { return }
        let m = cornerMargin

        func coordinate(_ anchor: Double, span: Double, extent: Double) -> Double {
            switch anchor {
            case 0:   return m
            case 1:   return extent - span - m
            default:  return (extent - span) / 2
            }
        }

        store.update(widget.id) {
            $0.x = max(0, min(coordinate(anchorX, span: $0.width,  extent: size.width),  size.width  - $0.width))
            $0.y = max(0, min(coordinate(anchorY, span: $0.height, extent: size.height), size.height - $0.height))
        }
    }

    /// A row that opens an NSOpenPanel and stores the chosen path.
    private func fileRow(_ title: String, value: String?, types: [String]?,
                         chooseDirectories: Bool, _ set: @escaping (String) -> Void) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 13)).foregroundStyle(Palette.text)
                .frame(width: 130, alignment: .leading)
            Text(value.map { ($0 as NSString).lastPathComponent } ?? "None")
                .font(.system(size: 12)).foregroundStyle(Palette.secondary).lineLimit(1)
            Spacer(minLength: 6)
            if value != nil {
                Button("Clear") { set("") }
                    .buttonStyle(.plain).font(.system(size: 12))
                    .foregroundStyle(Palette.secondary)
            }
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = chooseDirectories
                panel.allowsMultipleSelection = false
                if let types { panel.allowedFileTypes = types }
                if panel.runModal() == .OK, let url = panel.url { set(url.path) }
            }
            .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.accentColor)
        }
    }

    private func textRow(_ title: String, value: String, placeholder: String,
                         _ set: @escaping (String) -> Void) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 13)).foregroundStyle(Palette.text)
                .frame(width: 130, alignment: .leading)
            TextField(placeholder, text: Binding(get: { value }, set: set))
                .textFieldStyle(.roundedBorder).font(.system(size: 12))
        }
    }

    private func pickerRow(_ title: String, options: [String], value: String,
                           _ set: @escaping (String) -> Void) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 13)).foregroundStyle(Palette.text)
                .frame(width: 130, alignment: .leading)
            Picker("", selection: Binding(get: { value }, set: set)) {
                ForEach(options, id: \.self) { Text($0.capitalized).tag($0) }
            }
            .labelsHidden().pickerStyle(.segmented).frame(width: 220)
            Spacer(minLength: 0)
        }
    }

    private func optionToggle(_ title: String, _ value: Bool, _ set: @escaping (Bool) -> Void) -> some View {
        HStack {
            Text(title).font(.system(size: 13)).foregroundStyle(Palette.text)
            Spacer()
            Toggle("", isOn: Binding(get: { value }, set: set))
                .toggleStyle(.switch).tint(.accentColor).labelsHidden()
        }
    }

    private func slider(_ title: String, _ value: Double, _ range: ClosedRange<Double>,
                        _ set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 13)).foregroundStyle(Palette.text).frame(width: 110, alignment: .leading)
            Slider(value: Binding(get: { value }, set: set), in: range)
            Text(value < 10 ? String(format: "%.2f", value) : "\(Int(value))")
                .font(.system(size: 12)).monospacedDigit()
                .foregroundStyle(Palette.secondary).frame(width: 44, alignment: .trailing)
        }
    }

    // MARK: Gallery

    private var gallery: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Add a Widget").font(.system(size: 22, weight: .bold))
                Spacer()
                Button("Done") { showGallery = false }.keyboardShortcut(.cancelAction)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 168, maximum: 260), spacing: 12)], spacing: 12) {
                ForEach(WidgetKind.allCases) { kind in
                    Button {
                        let widget = DesktopWidget.make(kind: kind, displayID: primaryDisplayID)
                        store.add(widget)
                        selected = widget.id
                        store.editMode = true
                        showGallery = false
                    } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            Image(systemName: kind.icon).font(.system(size: 21)).foregroundStyle(Color.accentColor)
                            Text(kind.title).font(.system(size: 14, weight: .semibold))
                            Text(kind.summary).font(.system(size: 11.5)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }.buttonStyle(.plain)
                }
            }
        }
        .padding(20).frame(width: 580)
    }
}

// MARK: - Opening things

/// Shared launch behaviour for the launcher and shortcut widgets.
enum WidgetOpener {
    /// Opens whatever the widget points at. A URL wins over a path when both
    /// are set, since only the shortcut widget uses URLs at all.
    static func open(_ settings: WidgetSettings) {
        if let raw = settings.targetURL?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            let text = raw.contains("://") ? raw : "https://" + raw
            if let url = URL(string: text) { NSWorkspace.shared.open(url) }
            return
        }
        if let path = settings.targetPath, !path.isEmpty {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }

    /// Decoded images, kept in memory.
    ///
    /// These are read from `body`, which SwiftUI re-evaluates on every frame of
    /// a drag. Without a cache, moving a photo widget re-read and re-decoded the
    /// file from disk ~60 times a second and froze the app. NSCache is
    /// thread-safe and evicts under memory pressure.
    private static let imageCache = NSCache<NSString, NSImage>()

    /// The icon macOS itself uses for a file, folder or application.
    static func systemIcon(forPath path: String?) -> NSImage? {
        guard let path, !path.isEmpty else { return nil }
        let key = ("icon:" + path) as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: path)
        imageCache.setObject(icon, forKey: key)
        return icon
    }

    static func loadImage(_ path: String?) -> NSImage? {
        guard let path, !path.isEmpty else { return nil }
        let key = ("img:" + path) as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        imageCache.setObject(image, forKey: key)
        return image
    }

    /// Drops a path from the cache so a re-picked file is re-read.
    static func invalidate(_ path: String?) {
        guard let path else { return }
        imageCache.removeObject(forKey: ("img:" + path) as NSString)
        imageCache.removeObject(forKey: ("icon:" + path) as NSString)
    }

    /// Name shown under a launcher when the user hasn't set their own label.
    static func defaultName(forPath path: String?) -> String {
        guard let path, !path.isEmpty else { return "Choose…" }
        return (path as NSString).lastPathComponent
            .replacingOccurrences(of: ".app", with: "")
    }
}

private extension View {
    /// Applies the widget's fit / fill / stretch mode to an image.
    @ViewBuilder func imageMode(_ mode: String) -> some View {
        switch mode {
        case "fit":     self.aspectRatio(contentMode: .fit)
        case "stretch": self
        default:        self.aspectRatio(contentMode: .fill)
        }
    }
}

// MARK: - Image widget

struct ImageWidgetView: View {
    let widget: DesktopWidget

    var body: some View {
        Group {
            if let image = WidgetOpener.loadImage(widget.settings.imagePath) {
                Image(nsImage: image)
                    .resizable()
                    .imageMode(widget.settings.imageMode)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "photo").font(.system(size: 22))
                    Text("Choose an image").font(.system(size: 11)).opacity(0.7)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // Optional: clicking opens the original file in the default viewer.
            guard widget.settings.opensOnClick, let path = widget.settings.imagePath else { return }
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }
}

// MARK: - App launcher widget

struct AppLauncherWidgetView: View {
    let widget: DesktopWidget
    @State private var pressed = false

    /// A custom image replaces the app's own icon when one is set.
    private var icon: NSImage? {
        WidgetOpener.loadImage(widget.settings.imagePath)
            ?? WidgetOpener.systemIcon(forPath: widget.settings.targetPath)
    }

    var body: some View {
        VStack(spacing: 6) {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: 26))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let label = widget.settings.label, !label.isEmpty {
                Text(label)
                    .font(.system(size: max(9, widget.style.fontSize * 0.3), weight: .medium))
                    .lineLimit(1).minimumScaleFactor(0.4)
            }
        }
        .scaleEffect(pressed ? 0.92 : 1)
        .animation(.easeOut(duration: 0.12), value: pressed)
        .contentShape(Rectangle())
        .onTapGesture {
            pressed = true
            WidgetOpener.open(widget.settings)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { pressed = false }
        }
    }
}

// MARK: - Shortcut widget

struct ShortcutWidgetView: View {
    let widget: DesktopWidget
    @State private var pressed = false

    private var title: String {
        if let label = widget.settings.label, !label.isEmpty { return label }
        if let url = widget.settings.targetURL, !url.isEmpty {
            return URL(string: url.contains("://") ? url : "https://" + url)?.host ?? url
        }
        return WidgetOpener.defaultName(forPath: widget.settings.targetPath)
    }

    private var icon: some View {
        Group {
            if let image = WidgetOpener.loadImage(widget.settings.imagePath)
                ?? WidgetOpener.systemIcon(forPath: widget.settings.targetPath) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: (widget.settings.targetURL?.isEmpty == false)
                      ? "globe" : "arrow.up.right.square")
                    .resizable().aspectRatio(contentMode: .fit).padding(3)
            }
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 28, height: 28)
            Text(title)
                .font(.system(size: max(11, widget.style.fontSize * 0.38), weight: .medium))
                .lineLimit(1).minimumScaleFactor(0.4)
            Spacer(minLength: 0)
        }
        .scaleEffect(pressed ? 0.95 : 1)
        .animation(.easeOut(duration: 0.12), value: pressed)
        .contentShape(Rectangle())
        .onTapGesture {
            pressed = true
            WidgetOpener.open(widget.settings)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { pressed = false }
        }
    }
}

// MARK: - To-do widget

/// A checklist on the desktop. Items are ticked here; the text is edited in the
/// Widgets tab, because a desktop-level window is a poor place to type.
struct TodoWidgetView: View {
    let widget: DesktopWidget
    @ObservedObject private var store = WidgetStore.shared

    /// Read straight from the store so a tick redraws immediately.
    private var items: [TodoItem] {
        store.widgets.first { $0.id == widget.id }?.settings.todos ?? widget.settings.todos
    }

    private var titleSize: Double { max(11, widget.style.fontSize * 0.42) }
    private var rowSize: Double { max(10, widget.style.fontSize * 0.34) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(widget.settings.label?.isEmpty == false ? widget.settings.label! : "To-Do")
                    .font(.system(size: titleSize, weight: .bold))
                    .lineLimit(1).minimumScaleFactor(0.4)
                Spacer(minLength: 4)
                let done = items.filter(\.done).count
                if !items.isEmpty {
                    Text("\(done)/\(items.count)")
                        .font(.system(size: rowSize * 0.9, weight: .medium))
                        .opacity(0.6)
                        .lineLimit(1).minimumScaleFactor(0.5)
                }
            }

            if items.isEmpty {
                Text("Add items in the Widgets tab.")
                    .font(.system(size: rowSize)).opacity(0.55)
                    .lineLimit(2).minimumScaleFactor(0.5)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(items) { item in
                            row(item)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(_ item: TodoItem) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: rowSize))
                .foregroundStyle(item.done ? Color.accentColor : .secondary)
            Text(item.text.isEmpty ? "Untitled" : item.text)
                .font(.system(size: rowSize))
                .strikethrough(item.done)
                .opacity(item.done ? 0.5 : 1)
                .lineLimit(2).minimumScaleFactor(0.5)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { toggle(item) }
    }

    private func toggle(_ item: TodoItem) {
        store.update(widget.id) { w in
            guard let i = w.settings.todos.firstIndex(where: { $0.id == item.id }) else { return }
            w.settings.todos[i].done.toggle()
        }
    }
}
