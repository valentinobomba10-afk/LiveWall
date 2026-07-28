import Foundation

@MainActor final class LibraryStore: ObservableObject {
    @Published private(set) var items: [WallpaperItem] = []
    private let key = "livewall.library"
    init() { if let data = UserDefaults.standard.data(forKey: key), let decoded = try? JSONDecoder().decode([WallpaperItem].self, from: data) { items = decoded } }
    func add(_ item: WallpaperItem) { items.insert(item, at: 0); save() }
    private func save() { if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: key) } }
}
