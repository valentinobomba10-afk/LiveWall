import OSLog

enum AppLogger {
    static let general = Logger(subsystem: "com.livewall.app", category: "general")
    static let playback = Logger(subsystem: "com.livewall.app", category: "playback")
}
