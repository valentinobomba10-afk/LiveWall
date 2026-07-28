import Foundation

/// Cycles through a set of wallpapers on a timer (a "playlist").
final class RotationEngine: ObservableObject {
    @Published var isRunning = false
    @Published var interval: Double = 300      // seconds between switches

    /// Applies a wallpaper (wired to the view model).
    var apply: ((LibraryItem) -> Void)?

    private var timer: Timer?
    private var pool: [LibraryItem] = []
    private var index = 0

    func start(pool: [LibraryItem]) {
        guard !pool.isEmpty else { return }
        self.pool = pool
        index = 0
        isRunning = true
        apply?(pool[0])
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self, !self.pool.isEmpty else { return }
            self.index = (self.index + 1) % self.pool.count
            self.apply?(self.pool[self.index])
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
    }
}
