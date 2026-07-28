import SwiftUI

struct WallpaperLibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    var body: some View {
        List(library.items) { item in
            libraryRow(item)
        }
        .navigationTitle("Library")
    }
    private func libraryRow(_ item: WallpaperItem) -> some View {
        HStack {
            Image(systemName: item.sourceType.icon).frame(width: 24)
            VStack(alignment: .leading) {
                Text(item.name)
                Text(item.sourceType.rawValue).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(item.dateAdded, style: .date).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
