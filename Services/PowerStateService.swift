import Foundation
import IOKit.pwr_mgt

@MainActor final class PowerStateService: ObservableObject {
    @Published private(set) var isOnBattery = false
    init() { NotificationCenter.default.addObserver(forName: NSNotification.Name("NSProcessInfoPowerStateDidChange"), object: nil, queue: .main) { [weak self] _ in self?.refresh() }; refresh() }
    func refresh() { isOnBattery = ProcessInfo.processInfo.isLowPowerModeEnabled }
}
