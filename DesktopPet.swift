import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum DesktopPetKind: String, Codable, CaseIterable, Identifiable {
    case cat, dog, robot, ghost, custom
    var id: String { rawValue }
    var symbol: String { switch self { case .cat: "cat.fill"; case .dog: "dog.fill"; case .robot: "cpu.fill"; case .ghost: "aqi.medium"; case .custom: "person.crop.square" } }
    var title: String { rawValue.capitalized }
}

enum PetActivation: String, Codable, CaseIterable, Identifiable { case single, double
    var id: String { rawValue }
    var title: String { self == .single ? "Single click" : "Double click" }
}

private enum PetMotion { case idle, walking, sleeping, jumping, clicked }
extension Notification.Name { static let liveWallOpenPets = Notification.Name("LiveWallOpenPets") }

struct DesktopPet: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var kind: DesktopPetKind
    var customImagePath: String?
    var target: String?
    var activation: PetActivation = .single
    var size: Double = 92
    var movementSpeed: Double = 1
    var animationSpeed: Double = 1
    var automaticMovement = true
    var alwaysOnTop = false
    var clickThrough = false
    var hidden = false
    var screenID: UInt32
    var relativeX: Double = 0.5
    var relativeY: Double = 0.5
}

@MainActor final class DesktopPetManager: NSObject, ObservableObject {
    @Published private(set) var pets: [DesktopPet] = []
    private var panels: [UUID: NSPanel] = [:]
    private var timer: Timer?
    private var motions: [UUID: PetMotion] = [:]
    private var tick = 0
    private let displays: DisplayObserver
    private let storageKey = "desktopPets.v1"

    init(displays: DisplayObserver) {
        self.displays = displays
        super.init()
        load()
        displays.addHandler { [weak self] in self?.syncPanels() }
    }

    func start() { syncPanels(); startTimerIfNeeded() }
    func stop() { timer?.invalidate(); timer = nil; panels.values.forEach { $0.orderOut(nil) }; panels.removeAll() }

    func add(kind: DesktopPetKind) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let pet = DesktopPet(name: kind.title, kind: kind, screenID: screen.map(DisplayObserver.displayID(for:)) ?? 0,
                             relativeX: Double.random(in: 0.2...0.75), relativeY: Double.random(in: 0.18...0.75))
        pets.append(pet); save(); syncPanels()
    }

    func remove(_ id: UUID) { pets.removeAll { $0.id == id }; panels.removeValue(forKey: id)?.orderOut(nil); save(); startTimerIfNeeded() }
    func hide(_ id: UUID) { mutate(id) { $0.hidden = true } }
    func show(_ id: UUID) { mutate(id) { $0.hidden = false } }
    func toggleHidden(_ id: UUID) { mutate(id) { $0.hidden.toggle() } }

    func update(_ pet: DesktopPet) { guard let index = pets.firstIndex(where: { $0.id == pet.id }) else { return }; pets[index] = pet; save(); syncPanels(); startTimerIfNeeded() }

    func chooseTarget(for id: UUID) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.applicationBundle, .folder, .item]
        panel.allowsMultipleSelection = false; panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        mutate(id) { $0.target = url.absoluteString }
    }

    func chooseCustomImage(for id: UUID) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false; panel.prompt = "Choose Character"
        guard panel.runModal() == .OK, let source = panel.url else { return }
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("LiveWall/Pets", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent("\(UUID().uuidString).\(source.pathExtension.isEmpty ? "png" : source.pathExtension)")
        guard (try? FileManager.default.copyItem(at: source, to: destination)) != nil else { return }
        mutate(id) { $0.kind = .custom; $0.customImagePath = destination.path; $0.name = source.deletingPathExtension().lastPathComponent }
    }

    func move(_ id: UUID, translation: CGSize) {
        guard let pet = pets.first(where: { $0.id == id }), let screen = screen(for: pet) else { return }
        let available = screen.visibleFrame
        mutate(id, sync: false) {
            $0.relativeX = min(1, max(0, $0.relativeX + translation.width / max(1, available.width - $0.size)))
            $0.relativeY = min(1, max(0, $0.relativeY + translation.height / max(1, available.height - $0.size)))
        }
        save(); syncPanel(id)
    }

    func activate(_ id: UUID) {
        motions[id] = .clicked; syncPanel(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in self?.motions[id] = self?.pets.first(where: { $0.id == id })?.automaticMovement == true ? .walking : .idle; self?.syncPanel(id) }
        guard let pet = pets.first(where: { $0.id == id }), let raw = pet.target, let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
    }

    func showSettings() { NSApp.activate(ignoringOtherApps: true); NotificationCenter.default.post(name: .liveWallOpenPets, object: nil) }

    private func mutate(_ id: UUID, sync: Bool = true, _ change: (inout DesktopPet) -> Void) {
        guard let index = pets.firstIndex(where: { $0.id == id }) else { return }
        change(&pets[index]); save(); if sync { syncPanels(); startTimerIfNeeded() }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey), let saved = try? JSONDecoder().decode([DesktopPet].self, from: data) else { return }
        pets = saved
    }
    private func save() { if let data = try? JSONEncoder().encode(pets) { UserDefaults.standard.set(data, forKey: storageKey) } }
    private func screen(for pet: DesktopPet) -> NSScreen? { displays.screens.first { DisplayObserver.displayID(for: $0) == pet.screenID } ?? NSScreen.main }

    private func startTimerIfNeeded() {
        let needsTimer = pets.contains { !$0.hidden && $0.automaticMovement }
        if needsTimer && timer == nil { timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in self?.step() } }
        if !needsTimer { timer?.invalidate(); timer = nil }
    }
    private func step() {
        tick += 1
        var changed = false
        for index in pets.indices where !pets[index].hidden && pets[index].automaticMovement {
            motions[pets[index].id] = tick.isMultiple(of: 180) ? .jumping : .walking
            let delta = 0.0014 * pets[index].movementSpeed
            let next = pets[index].relativeX + delta
            pets[index].relativeX = next > 0.92 ? 0.08 : next
            changed = true; syncPanel(pets[index].id)
        }
        if changed { save() }
    }

    private func syncPanels() {
        let current = Set(pets.map(\.id))
        for (id, panel) in panels where !current.contains(id) { panel.orderOut(nil); panels.removeValue(forKey: id) }
        pets.forEach { syncPanel($0.id) }
    }

    private func syncPanel(_ id: UUID) {
        guard let pet = pets.first(where: { $0.id == id }), let screen = screen(for: pet) else { return }
        let panel: NSPanel
        if let existing = panels[id] { panel = existing }
        else {
            panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false; panel.isMovable = false
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
            panels[id] = panel
        }
        let frame = petFrame(pet, screen: screen)
        panel.level = pet.alwaysOnTop ? .floating : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        panel.ignoresMouseEvents = pet.clickThrough
        panel.setFrame(frame, display: false)
        let motion = motions[id] ?? (pet.automaticMovement ? .walking : .idle)
        panel.contentView = NSHostingView(rootView: DesktopPetView(pet: pet, motion: motion,
            onDrag: { [weak self] delta in self?.move(id, translation: delta) },
            onActivate: { [weak self] in self?.activate(id) },
            onOpen: { [weak self] in self?.activate(id) },
            onChangeTarget: { [weak self] in self?.chooseTarget(for: id) },
            onHide: { [weak self] in self?.hide(id) }, onSettings: { [weak self] in self?.showSettings() }, onRemove: { [weak self] in self?.remove(id) }))
        if pet.hidden { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }

    private func petFrame(_ pet: DesktopPet, screen: NSScreen) -> NSRect {
        let area = screen.visibleFrame, side = CGFloat(pet.size)
        return NSRect(x: area.minX + (area.width - side) * pet.relativeX, y: area.minY + (area.height - side) * pet.relativeY, width: side, height: side)
    }
}

private struct DesktopPetView: View {
    let pet: DesktopPet
    let motion: PetMotion
    let onDrag: (CGSize) -> Void
    let onActivate: () -> Void
    let onOpen: () -> Void
    let onChangeTarget: () -> Void
    let onHide: () -> Void
    let onSettings: () -> Void
    let onRemove: () -> Void
    @State private var drag = CGSize.zero
    @State private var pulse = false

    var body: some View {
        Group {
            if pet.kind == .custom, let path = pet.customImagePath, let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: pet.kind.symbol).resizable().scaledToFit().symbolRenderingMode(.hierarchical)
                    .foregroundStyle(LinearGradient(colors: [.white, .cyan, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .padding(8)
            }
        }
        .scaleEffect(motion == .clicked ? 0.86 : (pulse ? 1.06 : 1))
        .rotationEffect(motion == .sleeping ? .degrees(-8) : .zero)
        .offset(x: drag.width, y: drag.height + (motion == .jumping ? 18 : (motion == .walking && pulse ? 3 : 0)))
        .animation(.easeInOut(duration: max(0.12, 0.45 / pet.animationSpeed)).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = true }
        .contentShape(Rectangle())
        .gesture(DragGesture().onChanged { drag = $0.translation }.onEnded { value in onDrag(value.translation); drag = .zero })
        .onTapGesture(count: pet.activation == .double ? 2 : 1, perform: onActivate)
        .contextMenu {
            Button("Open", action: onOpen)
            Button("Change App…", action: onChangeTarget)
            Button("Pet Settings", action: onSettings)
            Button("Hide", action: onHide)
            Divider()
            Button("Remove", role: .destructive, action: onRemove)
        }
    }
}

struct PetsSettingsView: View {
    @ObservedObject var pets: DesktopPetManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack { VStack(alignment: .leading) { Text("Desktop Pets").font(.system(size: 38, weight: .semibold, design: .serif)); Text("Animated companions above your live wallpaper.").foregroundStyle(.secondary) }; Spacer() }
                HStack(spacing: 10) { ForEach([DesktopPetKind.cat, .dog, .robot, .ghost], id: \.self) { kind in Button { pets.add(kind: kind) } label: { Label("Add \(kind.title)", systemImage: kind.symbol) }.buttonStyle(GlassButtonStyle(tint: .purple)) } }
                if pets.pets.isEmpty { Text("Add a pet to get started. You can also replace it with your own character image.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 200) }
                ForEach(pets.pets) { pet in PetSettingsCard(pet: pet, manager: pets) }
            }.padding(24).padding(.top, 82).foregroundStyle(.white)
        }
    }
}

private struct PetSettingsCard: View {
    let pet: DesktopPet
    @ObservedObject var manager: DesktopPetManager
    @State private var draft: DesktopPet
    init(pet: DesktopPet, manager: DesktopPetManager) { self.pet = pet; self.manager = manager; _draft = State(initialValue: pet) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Image(systemName: draft.kind.symbol).font(.system(size: 24)).foregroundStyle(.cyan); TextField("Pet name", text: $draft.name).textFieldStyle(.roundedBorder); Spacer(); Button(draft.hidden ? "Show" : "Hide") { manager.toggleHidden(draft.id) }; Button(role: .destructive) { manager.remove(draft.id) } label: { Image(systemName: "trash") } }
            HStack { Button("Choose App, File or Folder…") { manager.chooseTarget(for: draft.id) }; TextField("Website, app, file, folder or shortcut", text: Binding(get: { draft.target ?? "" }, set: { draft.target = $0.isEmpty ? nil : $0 })).textFieldStyle(.roundedBorder); Button("Use Custom Character…") { manager.chooseCustomImage(for: draft.id) } }
            Picker("Activate", selection: $draft.activation) { ForEach(PetActivation.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
            Toggle("Move around automatically", isOn: $draft.automaticMovement); Toggle("Keep above other windows", isOn: $draft.alwaysOnTop); Toggle("Click-through when inactive", isOn: $draft.clickThrough)
            HStack { Text("Size"); Slider(value: $draft.size, in: 48...180); Text("\(Int(draft.size))") }; HStack { Text("Movement"); Slider(value: $draft.movementSpeed, in: 0.2...3); Text("Animation"); Slider(value: $draft.animationSpeed, in: 0.4...2.5) }
            HStack { Spacer(); Button("Save Pet") { manager.update(draft) }.buttonStyle(PrimaryGlassButtonStyle()) }
        }
        .padding(18).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.1)))
    }
}
