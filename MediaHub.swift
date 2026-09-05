import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

struct MediaHubTrack: Identifiable, Codable, Hashable {
    let id: String
    let title: String
    let artist: String
    let artwork: String
    let genre: String
    let fileName: String
    let localPath: String?

    init(id: String, title: String, artist: String, artwork: String = "",
         genre: String, fileName: String, localPath: String? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.artwork = artwork
        self.genre = genre
        self.fileName = fileName
        self.localPath = localPath
    }

    var downloadURL: URL? {
        guard localPath == nil else { return nil }
        var components = URLComponents(string: "https://drive.usercontent.google.com/download")
        components?.queryItems = [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "export", value: "download"),
            URLQueryItem(name: "confirm", value: "t")
        ]
        return components?.url
    }
}

/// Downloads a selected Drive song once, keeps it in LiveWall's Application
/// Support folder, and plays the local copy with native AVFoundation audio.
@MainActor final class MusicPlaybackController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = MusicPlaybackController()

    @Published private(set) var currentTrack: MediaHubTrack?
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published var volume: Double = 0.75 {
        didSet { audioPlayer?.volume = Float(volume) }
    }

    private var queue: [MediaHubTrack] = []
    private var audioPlayer: AVAudioPlayer?
    private var loadID = UUID()
    private var loadTask: Task<Void, Never>?

    private override init() {
        super.init()
    }

    func play(_ track: MediaHubTrack, in tracks: [MediaHubTrack]) {
        loadTask?.cancel()
        queue = tracks.isEmpty ? MediaHubCatalog.tracks : tracks
        currentTrack = track
        errorMessage = nil
        isLoading = true
        isPlaying = false
        audioPlayer?.stop()

        let requestID = UUID()
        loadID = requestID
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let localURL = try await self.localFile(for: track)
                guard self.loadID == requestID, self.currentTrack?.id == track.id else { return }
                let player = try AVAudioPlayer(contentsOf: localURL)
                player.delegate = self
                player.volume = Float(self.volume)
                player.prepareToPlay()
                guard player.play() else { throw MusicPlaybackError.couldNotPlay }
                self.audioPlayer = player
                self.isLoading = false
                self.isPlaying = true
            } catch {
                guard self.loadID == requestID else { return }
                self.isLoading = false
                self.isPlaying = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func togglePlayback() {
        guard currentTrack != nil else {
            if let first = MediaHubCatalog.tracks.first { play(first, in: MediaHubCatalog.tracks) }
            return
        }
        if isPlaying {
            audioPlayer?.pause()
            isPlaying = false
        } else {
            if audioPlayer?.play() == true { isPlaying = true }
        }
    }

    func next() { move(by: 1) }
    func previous() { move(by: -1) }

    func stop() {
        loadTask?.cancel()
        loadTask = nil
        loadID = UUID()
        audioPlayer?.stop()
        audioPlayer = nil
        currentTrack = nil
        isPlaying = false
        isLoading = false
        errorMessage = nil
    }

    private func move(by offset: Int) {
        guard !queue.isEmpty else { return }
        let current = currentTrack.flatMap { item in queue.firstIndex { $0.id == item.id } } ?? 0
        let target = (current + offset + queue.count) % queue.count
        play(queue[target], in: queue)
    }

    func isDownloaded(_ track: MediaHubTrack) -> Bool {
        FileManager.default.fileExists(atPath: track.localPath ?? cachedURL(for: track).path)
    }

    /// Where downloaded songs live. Derived directly rather than from
    /// `tracks[0]`, which would trap if the catalog were ever empty.
    private var musicFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LiveWall", isDirectory: true)
            .appendingPathComponent("Music", isDirectory: true)
    }

    private var downloadedMusicFiles: [URL] {
        let folder = musicFolder
        return ((try? FileManager.default.contentsOfDirectory(at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { $0.pathExtension.lowercased() == "mp3" &&
                (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }

    var downloadedMusicBytes: Int64 {
        downloadedMusicFiles.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /// Moves every downloaded song to the Trash and reports how many went.
    ///
    /// Imported MP3s are untouched: those carry a `localPath` pointing outside
    /// this folder, so they are never in `downloadedMusicFiles`.
    @discardableResult
    func clearDownloadedMusic() throws -> Int {
        // Cancel first, so an in-flight download cannot repopulate the folder
        // moments after we empty it.
        if currentTrack?.localPath == nil { stop() }
        var cleared = 0
        var firstFailure: Error?
        for file in downloadedMusicFiles {
            do { try FileManager.default.trashItem(at: file, resultingItemURL: nil); cleared += 1 }
            catch { if firstFailure == nil { firstFailure = error } }
        }
        objectWillChange.send()
        if let firstFailure, cleared == 0 { throw firstFailure }
        return cleared
    }

    private func localFile(for track: MediaHubTrack) async throws -> URL {
        if let path = track.localPath {
            let localURL = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: localURL.path) else {
                throw MusicPlaybackError.missingLocalFile
            }
            return localURL
        }
        let destination = cachedURL(for: track)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        guard let remoteURL = track.downloadURL else { throw MusicPlaybackError.invalidLink }

        let (temporaryURL, response) = try await URLSession.shared.download(from: remoteURL)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              response.mimeType?.lowercased().hasPrefix("audio/") == true else {
            throw MusicPlaybackError.invalidDownload
        }
        let folder = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    private func cachedURL(for track: MediaHubTrack) -> URL {
        musicFolder.appendingPathComponent("\(track.id).mp3")
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            if flag { self?.next() }
            else { self?.isPlaying = false }
        }
    }
}

struct MusicDownloadSettings: View {
    @ObservedObject private var player = MusicPlaybackController.shared
    @ObservedObject private var mine = UserMusicLibrary.shared
    @State private var confirmsClear = false
    @State private var message: String?

    private var sizeText: String {
        ByteCountFormatter.string(fromByteCount: player.downloadedMusicBytes, countStyle: .file)
    }

    var body: some View {
        VStack(spacing: 0) {
            row("Downloaded music", sizeText.hasPrefix("Zero") ? "Nothing downloaded yet" : "\(sizeText) on disk") {
                Text(sizeText)
                    .font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(DS.ink)
            }
            Divider().overlay(DS.hairline)
            row("Imported MP3s", "Your own files. These are never cleared.") {
                Text("\(mine.tracks.count)")
                    .font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(DS.ink)
            }
            Divider().overlay(DS.hairline)
            row("Clear downloads",
                "Moves saved songs to the Trash. They download again next time you play them.") {
                Button("Clear…") { confirmsClear = true }
                    .buttonStyle(DSGlassButton())
                    .disabled(player.downloadedMusicBytes == 0)
            }
            if let message {
                Divider().overlay(DS.hairline)
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.live)
                        .font(.system(size: 12))
                    Text(message).font(.system(size: 11.5)).foregroundStyle(DS.ink2)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 11)
            }
        }
        .padding(.horizontal, DS.gap)
        .glass()
        .alert("Clear downloaded music?", isPresented: $confirmsClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Downloads", role: .destructive) {
                do {
                    let n = try player.clearDownloadedMusic()
                    message = n == 0 ? "Nothing to clear."
                        : "Moved \(n) song\(n == 1 ? "" : "s") to the Trash. Imported MP3s kept."
                } catch {
                    message = "Couldn't clear: \(error.localizedDescription)"
                }
            }
        } message: {
            Text("Downloaded songs stop playing and their files move to the Trash. Your imported MP3s are kept.")
        }
    }

    private func row<C: View>(_ title: String, _ subtitle: String?, @ViewBuilder control: () -> C) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(DS.ink)
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(DS.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            control()
        }
        .padding(.vertical, 12)
    }
}

private enum MusicPlaybackError: LocalizedError {
    case invalidLink, invalidDownload, couldNotPlay, missingLocalFile
    var errorDescription: String? {
        switch self {
        case .invalidLink: return "This song's Google Drive link is invalid."
        case .invalidDownload: return "Google Drive did not return playable audio. The file may be private or its download quota may be temporarily exceeded; try again later."
        case .couldNotPlay: return "LiveWall downloaded the song but macOS could not play it."
        case .missingLocalFile: return "This custom MP3 is missing. Add it to LiveWall again."
        }
    }
}

@MainActor final class UserMusicLibrary: ObservableObject {
    static let shared = UserMusicLibrary()
    @Published private(set) var tracks: [MediaHubTrack] = []
    private let defaultsKey = "livewall.customMusic.v1"

    private init() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([MediaHubTrack].self, from: data) else { return }
        tracks = decoded.filter { $0.localPath.map(FileManager.default.fileExists(atPath:)) == true }
    }

    func chooseAndImport() {
        let panel = NSOpenPanel()
        panel.title = "Add MP3 Files to LiveWall"
        panel.prompt = "Add Music"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.mp3, .mpeg4Audio, .audio]
        guard panel.runModal() == .OK else { return }

        for source in panel.urls { importFile(source) }
        save()
    }

    private func importFile(_ source: URL) {
        let folder = musicFolder.appendingPathComponent("Custom", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let ext = source.pathExtension.isEmpty ? "mp3" : source.pathExtension.lowercased()
            let destination = folder.appendingPathComponent("\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: source, to: destination)

            let base = source.deletingPathExtension().lastPathComponent
            let pieces = base.components(separatedBy: " - ")
            let artist = pieces.count > 1 ? pieces[0] : "My Music"
            let title = pieces.count > 1 ? pieces.dropFirst().joined(separator: " - ") : base
            tracks.append(.init(id: "custom-\(UUID().uuidString)", title: title, artist: artist,
                                genre: "My Music", fileName: source.lastPathComponent,
                                localPath: destination.path))
        } catch {
            NSSound.beep()
        }
    }

    private var musicFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LiveWall", isDirectory: true)
            .appendingPathComponent("Music", isDirectory: true)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(tracks) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

struct MediaHubApp: Identifiable {
    let id: String
    let title: String
    let url: String
    let cover: String

    var pageURL: URL? { URL(string: url) }
}

enum MediaHubCatalog {
    // Google Drive music supplied for LiveWall. Songs download only when selected.
    static let tracks: [MediaHubTrack] = [
        .init(id: "1FTB47gJR7S7tJKJlViqCZmCCLEUBaVXV", title: "Gangsta's Paradise", artist: "Coolio", artwork: "https://cdn-images.dzcdn.net/images/cover/a123b2c32996a8c8664a82cb4219ce0c/500x500-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "Coolio - Gangsta's Paradise.mp3"),
        .init(id: "1sbFc5RjQxHzqQz-bjBE53GnhvVn2mVaZ", title: "She Knows (feat. Amber Coffman & Cults)", artist: "J. Cole", artwork: "https://cdn-images.dzcdn.net/images/cover/8c9d7505ab6c7f3dccc5a4dc0ddfd79e/500x500-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "J. Cole - She Knows (feat. Amber Coffman & Cults).mp3"),
        .init(id: "1TxcTKqeTK5QrWkk8HrBX0syoebB7SdrV", title: "Stronger", artist: "Kanye West", artwork: "https://cdn-images.dzcdn.net/images/cover/15012d974c6263aec95e52e6d86cba23/500x500-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "Kanye West - Stronger.mp3"),
        .init(id: "1nkOx95QodLD2KlRPqnyxrAkWCQYN3szr", title: "goosebumps", artist: "Travis Scott", artwork: "https://cdn-images.dzcdn.net/images/cover/a2f66f08468fb9897019e82ffb7a5fcb/500x500-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "Travis Scott - goosebumps.mp3"),
        .init(id: "1MKVeG3ItEwdMLFh5RsFG7HWkt2ejSBDl", title: "Feel It (From “Invincible”)", artist: "d4vd", artwork: "https://cdn-images.dzcdn.net/images/cover/bf27c2009c90ed650e627f3f01d18d45/500x500-000000-80-0-0.jpg", genre: "Alternative", fileName: "d4vd - Feel It (From “Invincible”).mp3"),
        .init(id: "1inufKD552D1peQusLs06oCKxj8iwm-ew", title: "Goosebumps (Remix)", artist: "Travis Scott, HVME", artwork: "https://cdn-images.dzcdn.net/images/cover/6b149002c49dbb6a6056512dbfcb5e95/500x500-000000-80-0-0.jpg", genre: "Dance", fileName: "Travis Scott, HVME - Goosebumps (Remix).mp3"),
        .init(id: "19I2ATU3NHGbQyZkernUFejivaKvXin_8", title: "Perfect (Exceeder)", artist: "Mason, Princess Superstar", artwork: "https://cdn-images.dzcdn.net/images/cover/a51454cfa17238041ebdb3875cf847ce/500x500-000000-80-0-0.jpg", genre: "Dance", fileName: "Mason, Princess Superstar - Perfect (Exceeder).mp3"),
        .init(id: "1v0ITObjhaPxY0uCqmcba8wMo4I7jx72g", title: "Sugar On My Tongue", artist: "Tyler, The Creator", artwork: "https://cdn-images.dzcdn.net/images/cover/d79052872c09468fd80bd288928962c9/500x500-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "Tyler, The Creator - Sugar On My Tongue.mp3"),
        .init(id: "1l51WIud2SLuJCFGHxQA0m7jYwYB24NUI", title: "See You Again (feat. Kali Uchis)", artist: "Tyler, The Creator", artwork: "https://cdn-images.dzcdn.net/images/cover/a7a16b8f63b1ec0e9fbd327619966737/500x500-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "Tyler, The Creator - See You Again (feat. Kali Uchis).mp3"),
        .init(id: "1e41VR364ifP4Bt-6NswbOYI5cK2QbD8c", title: "luther", artist: "Kendrick Lamar", artwork: "https://cdn-images.dzcdn.net/images/cover/da5256ff8cacfe9ad90521f6e3792259/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "001. Kendrick Lamar - luther.mp3"),
        .init(id: "1IhYxOA_93PDb9AIPhMQOrR7Z1Slfr1cj", title: "Die With A Smile", artist: "Lady Gaga", artwork: "https://cdn-images.dzcdn.net/images/cover/4bd5903f4ce8f2601916bfadb44efe8a/1000x1000-000000-80-0-0.jpg", genre: "Pop", fileName: "002. Lady Gaga - Die With A Smile.mp3"),
        .init(id: "1fU2jnZdd-PkVt-2Sy4TSOtjNNo4aPXYA", title: "Ordinary", artist: "Alex Warren", artwork: "https://cdn-images.dzcdn.net/images/cover/f4246416b5e3e71a35adf1e2cbe98bfb/1000x1000-000000-80-0-0.jpg", genre: "Pop", fileName: "003. Alex Warren - Ordinary.mp3"),
        .init(id: "1eSIJH2tdzjOracBKoXmVs_7r_noqGZk_", title: "NOKIA", artist: "Drake", artwork: "https://cdn-images.dzcdn.net/images/cover/478562cdbafe4faa1515bd457042cc4a/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "004. Drake - NOKIA.mp3"),
        .init(id: "1UlxLWHNEwzTRYYkPk0qlVd4QNv8vJ8js", title: "A Bar Song (Tipsy)", artist: "Shaboozey", artwork: "https://cdn-images.dzcdn.net/images/cover/d4f0d9289d6f68204dee8a22fe777c70/1000x1000-000000-80-0-0.jpg", genre: "Country", fileName: "005. Shaboozey - A Bar Song (Tipsy).mp3"),
        .init(id: "1tDFxjOg4CYSIvPxmjDXHjcuyoADg6J4S", title: "Pink Pony Club", artist: "Chappell Roan", artwork: "https://cdn-images.dzcdn.net/images/cover/71486ce8b24f612c4887efa0f79a9f66/1000x1000-000000-80-0-0.jpg", genre: "Pop", fileName: "006. Chappell Roan - Pink Pony Club.mp3"),
        .init(id: "1DgAuVW8eOcwxDp-MBzAtAMnmh00IFJH0", title: "I'm The Problem", artist: "Morgan Wallen", artwork: "https://cdn-images.dzcdn.net/images/cover/c0a95c46e56018109a6786f9e795acb6/1000x1000-000000-80-0-0.jpg", genre: "Country", fileName: "007. Morgan Wallen - I_m The Problem.mp3"),
        .init(id: "1OTtH0nO9N8VJxBpDOb0okDesB_P2qvbT", title: "I Ain't Comin' Back", artist: "Morgan Wallen", artwork: "https://cdn-images.dzcdn.net/images/cover/22c6d080209e45ef58cca3596bf95e71/1000x1000-000000-80-0-0.jpg", genre: "Country", fileName: "008. Morgan Wallen - I Ain_t Comin_ Back.mp3"),
        .init(id: "1IAz7mRsXzUPrHp_taQ2wZbsoQho7WhnJ", title: "Lose Control", artist: "Teddy Swims", artwork: "https://cdn-images.dzcdn.net/images/cover/fb2f549900acdfaefeee8c718e42037b/1000x1000-000000-80-0-0.jpg", genre: "Pop", fileName: "009. Teddy Swims - Lose Control.mp3"),
        .init(id: "1gdqyJSdhVUo4tUFGrk4x8J4j2hjs7Z2r", title: "Beautiful Things", artist: "Benson Boone", artwork: "https://cdn-images.dzcdn.net/images/cover/ab1ae3011977aa3c7f0a5f025a99cac9/1000x1000-000000-80-0-0.jpg", genre: "Pop", fileName: "010. Benson Boone - Beautiful Things.mp3"),
        .init(id: "1U9pQFQxGLW28Dyagr2Fg7zbVbPdkO3ed", title: "All The Way (feat. Bailey Zimmerman)", artist: "BigXthaPlug", artwork: "https://cdn-images.dzcdn.net/images/cover/c7f63c071b03c20a69e588d5a90696cb/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "011. BigXthaPlug - All The Way (feat. Bailey Zimmerman).mp3"),
        .init(id: "1ExdGkXI59xQtPVrp4pgmoOMDVaZmOlTS", title: "Anxiety", artist: "Doechii", artwork: "https://cdn-images.dzcdn.net/images/cover/a86cc99df85173d25b3b8a5e52b10a1f/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "012. Doechii - Anxiety.mp3"),
        .init(id: "1aQxMRwRFbuPVpHbd3jV1kMVu9bWEj-El", title: "BIRDS OF A FEATHER", artist: "Billie Eilish", artwork: "https://cdn-images.dzcdn.net/images/cover/5d284b31cb9ddeb1a0c79aede5a94e1c/1000x1000-000000-80-0-0.jpg", genre: "Alternative", fileName: "013. Billie Eilish - BIRDS OF A FEATHER.mp3"),
        .init(id: "1zEUGJPEaTrVXEQ0r2AFDspQa2QSiu-sg", title: "Just In Case", artist: "Morgan Wallen", artwork: "https://cdn-images.dzcdn.net/images/cover/22c6d080209e45ef58cca3596bf95e71/1000x1000-000000-80-0-0.jpg", genre: "Country", fileName: "014. Morgan Wallen - Just In Case.mp3"),
        .init(id: "1ZhMQ3NLRyaauFVDOrL3mz1n96QXfEq1x", title: "I Had Some Help", artist: "Post Malone", artwork: "https://cdn-images.dzcdn.net/images/cover/b9c8cc4fd597a9bc516445e6573501cf/1000x1000-000000-80-0-0.jpg", genre: "Pop", fileName: "015. Post Malone - I Had Some Help.mp3"),
        .init(id: "1Mv8Fb-L5XLnY59vzev8RRZ1OFmeLQZD_", title: "APT", artist: "ROSÉ", artwork: "https://cdn-images.dzcdn.net/images/cover/258e6042338ce64bb4157c0c94b232ac/1000x1000-000000-80-0-0.jpg", genre: "Pop", fileName: "016. ROSÉ - APT.mp3"),
        .init(id: "15HYt6kcwljjRekIan1i1XYxw3MElu5tG", title: "Love Somebody", artist: "Morgan Wallen", artwork: "https://cdn-images.dzcdn.net/images/cover/473abf39f40221437fb7c590e36b7282/1000x1000-000000-80-0-0.jpg", genre: "Country", fileName: "017. Morgan Wallen - Love Somebody.mp3"),
        .init(id: "12neiO-Pk6xbo9I9HgTSf3ylNbXuN9W46", title: "MUTT", artist: "Leon Thomas", artwork: "https://cdn-images.dzcdn.net/images/cover/1c318762a31c79bd28e9f7951bdab5b4/1000x1000-000000-80-0-0.jpg", genre: "R&B", fileName: "018. Leon Thomas - MUTT.mp3"),
        .init(id: "1uXUPb5OzbaCcUoFM3Wmo_-tlni_lfKtS", title: "Espresso", artist: "Sabrina Carpenter", artwork: "https://cdn-images.dzcdn.net/images/cover/e3221287a77eb262944e6528766eeba4/1000x1000-000000-80-0-0.jpg", genre: "Pop", fileName: "019. Sabrina Carpenter - Espresso.mp3"),
        .init(id: "1sj56ljU0ZCHuzbeUHTSJ5pwCMZ3PlC4l", title: "That's So True", artist: "Gracie Abrams", artwork: "https://cdn-images.dzcdn.net/images/cover/967769c4612d74e8f5c7da8798b28e13/1000x1000-000000-80-0-0.jpg", genre: "Pop", fileName: "020. Gracie Abrams - That_s So True.mp3"),
        .init(id: "1ZDNlDIsa_wdS66KVJVXFpl6qgHAm7r9J", title: "Not Like Us", artist: "Kendrick Lamar", artwork: "https://cdn-images.dzcdn.net/images/cover/84345d29bc2ed8e713112425f8417e97/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "021. Kendrick Lamar - Not Like Us.mp3"),
        .init(id: "17vf1Q_YDsyDmVnDhQ_5vxoRKnRrVRlFP", title: "Messy", artist: "Lola Young", artwork: "https://cdn-images.dzcdn.net/images/cover/41b98b2c9cf64689c4c77569610e3cf1/1000x1000-000000-80-0-0.jpg", genre: "Pop", fileName: "022. Lola Young - Messy.mp3"),
        .init(id: "1rQTMZxEjfD6mPW8MWAlf-373kNE6hjAc", title: "tv off", artist: "Kendrick Lamar", artwork: "https://cdn-images.dzcdn.net/images/cover/da5256ff8cacfe9ad90521f6e3792259/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "023. Kendrick Lamar - tv off.mp3"),
        .init(id: "1uI5FRYhVu3nhYGPDaljE9xVnEMWRdlhv", title: "30 For 30 (with Kendrick Lamar)", artist: "SZA", artwork: "https://cdn-images.dzcdn.net/images/cover/992cc838b5f0cf0eebbd83011a979571/1000x1000-000000-80-0-0.jpg", genre: "Pop", fileName: "024. SZA - 30 For 30 (with Kendrick Lamar).mp3"),
        .init(id: "1aIMTosxIOx_kc2mPnK6TZLsdeWSi3kei", title: "Sports car", artist: "Tate McRae", artwork: "https://cdn-images.dzcdn.net/images/cover/74a47f9832735b37a41d8fd49cd23354/1000x1000-000000-80-0-0.jpg", genre: "Pop", fileName: "025. Tate McRae - Sports car.mp3"),
        .init(id: "1jWH5MvNtJQhQI8ZZuE28HCDuH3nyryTX", title: "Abracadabra", artist: "Lady Gaga", artwork: "https://cdn-images.dzcdn.net/images/cover/2a769f6f0cce0ca9e129ce4b61f83973/1000x1000-000000-80-0-0.jpg", genre: "Pop", fileName: "026. Lady Gaga - Abracadabra.mp3"),
        .init(id: "1FQ9q1F-q-PCknrze3wci6D-7vpi0v4f7", title: "squabble up", artist: "Kendrick Lamar", artwork: "https://cdn-images.dzcdn.net/images/cover/da5256ff8cacfe9ad90521f6e3792259/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "027. Kendrick Lamar - squabble up.mp3"),
        .init(id: "1XsIze_glFCHK7etRn0dnc9E9HCeTWeYT", title: "Stargazing", artist: "Myles Smith", artwork: "https://cdn-images.dzcdn.net/images/cover/eaf89238495473e9d78eb75e7a181322/1000x1000-000000-80-0-0.jpg", genre: "Alternative", fileName: "028. Myles Smith - Stargazing.mp3"),
        .init(id: "19nhBzbncm946qOxSP3WG5e_n7OMWkp9m", title: "No One Noticed", artist: "The Marías", artwork: "https://cdn-images.dzcdn.net/images/cover/574bd156ad04b9af443cdf6775cfa8c3/1000x1000-000000-80-0-0.jpg", genre: "R&B", fileName: "029. The Marías - No One Noticed.mp3"),
        .init(id: "1QPktUYPsBNtA53qvuSbBrZWIWaJacRJJ", title: "Bad Dreams", artist: "Teddy Swims", artwork: "https://cdn-images.dzcdn.net/images/cover/ebb148dd7d9d124ea9fbe39d4576fa46/1000x1000-000000-80-0-0.jpg", genre: "Pop", fileName: "030. Teddy Swims - Bad Dreams.mp3"),
        .init(id: "1_OCKA6ofjYTm_BycQbjbESStxjDSpee-", title: "I Never Lie", artist: "Zach Top", artwork: "https://cdn-images.dzcdn.net/images/cover/9ce9a94e525026b517d33ea6a9dddbdf/1000x1000-000000-80-0-0.jpg", genre: "Country", fileName: "031. Zach Top - I Never Lie.mp3"),
        .init(id: "1jlz0Rz9tfk825kebIdaxctFFUg5ZCxLE", title: "Timeless", artist: "The Weeknd", artwork: "https://cdn-images.dzcdn.net/images/cover/e4b16c1afe136140bba34368357e8f05/1000x1000-000000-80-0-0.jpg", genre: "R&B", fileName: "032. The Weeknd - Timeless.mp3"),
        .init(id: "128SX7l5flKHJgLruKRqT38XqyGtjgjTQ", title: "Taste", artist: "Sabrina Carpenter", artwork: "https://cdn-images.dzcdn.net/images/cover/0fd6e3b346b959a8781ccfa89b63607a/1000x1000-000000-80-0-0.jpg", genre: "Pop", fileName: "033. Sabrina Carpenter - Taste.mp3"),
        .init(id: "1n0PdYNhs90vef3HlsydSlXD-lD6swAEy", title: "Sorry I'm Here For Someone Else", artist: "Benson Boone", artwork: "https://cdn-images.dzcdn.net/images/cover/6c868cb8dcbb7066f2f224707cef59f2/1000x1000-000000-80-0-0.jpg", genre: "Pop", fileName: "034. Benson Boone - Sorry I_m Here For Someone Else.mp3"),
        .init(id: "1s6Oi8QMoB53k3VlO1SNeGxyDm_4gHCvq", title: "Blue Strips", artist: "Jessie Murph", artwork: "https://cdn-images.dzcdn.net/images/cover/e454cbe12cec1e89a8bec00aaeca454d/1000x1000-000000-80-0-0.jpg", genre: "Pop", fileName: "035. Jessie Murph - Blue Strips.mp3"),
        .init(id: "1z_NjijgaFlk2c9hbVix8_hHVJUI9-yxP", title: "Worst Way", artist: "Riley Green", artwork: "https://cdn-images.dzcdn.net/images/cover/f28720755e161626ade4dc91c33e1dea/1000x1000-000000-80-0-0.jpg", genre: "Pop", fileName: "036. Riley Green - Worst Way.mp3"),
        .init(id: "1q4-Yp56F2fNhQCJzKEkArORPXuK75Uu3", title: "Good News", artist: "Shaboozey", artwork: "https://cdn-images.dzcdn.net/images/cover/d5777636ec076cc1e663183b4c4069e9/1000x1000-000000-80-0-0.jpg", genre: "Country", fileName: "037. Shaboozey - Good News.mp3"),
        .init(id: "1FPfXO8NKyQ85Hc53yER2-q4NNfwc6pHS", title: "Sailor Song", artist: "Gigi Perez", artwork: "https://cdn-images.dzcdn.net/images/cover/a1d1e955d73e18821b5d3f3d22fceb6a/1000x1000-000000-80-0-0.jpg", genre: "Alternative", fileName: "038. Gigi Perez - Sailor Song.mp3"),
        .init(id: "1Vz53_xp8yOv7gdIXDKo-YmvM4vSg92Zw", title: "weren't for the wind", artist: "Ella Langley", artwork: "https://cdn-images.dzcdn.net/images/cover/fb07342ae2ca9e11f9275716163797ec/1000x1000-000000-80-0-0.jpg", genre: "Country", fileName: "039. Ella Langley - weren_t for the wind.mp3"),
        .init(id: "1hwe_peidkzpN7X-QnTbfqesRfEpPBfZ_", title: "Hard Fought Hallelujah", artist: "Brandon Lake", artwork: "https://cdn-images.dzcdn.net/images/cover/b71f4c9be0b377f6062be503098ed3f4/1000x1000-000000-80-0-0.jpg", genre: "Pop", fileName: "040. Brandon Lake - Hard Fought Hallelujah.mp3"),
        .init(id: "1nvlV2ktVJJ7auVQ_t9afjHag7jTABSpW", title: "I'm A Little Crazy", artist: "Morgan Wallen", artwork: "https://cdn-images.dzcdn.net/images/cover/c0a95c46e56018109a6786f9e795acb6/1000x1000-000000-80-0-0.jpg", genre: "Country", fileName: "041. Morgan Wallen - I_m A Little Crazy.mp3"),
        .init(id: "1kChNBP-qNrIpsF4bkchFhzW03uLQJgHR", title: "Azizam", artist: "Ed Sheeran", artwork: "https://cdn-images.dzcdn.net/images/cover/5cead25b9f21b10393427a0c463ae170/1000x1000-000000-80-0-0.jpg", genre: "Pop", fileName: "042. Ed Sheeran - Azizam.mp3"),
        .init(id: "1gXfyT16EqJZN3Izq2tgtrplCfTBpXraQ", title: "WILDFLOWER", artist: "Billie Eilish", artwork: "https://cdn-images.dzcdn.net/images/cover/5d284b31cb9ddeb1a0c79aede5a94e1c/1000x1000-000000-80-0-0.jpg", genre: "Alternative", fileName: "043. Billie Eilish - WILDFLOWER.mp3"),
        .init(id: "1zGK47qJBVDuypNlGGc324ygen0bV94s2", title: "Cry For Me", artist: "The Weeknd", artwork: "https://cdn-images.dzcdn.net/images/cover/e4b16c1afe136140bba34368357e8f05/1000x1000-000000-80-0-0.jpg", genre: "R&B", fileName: "044. The Weeknd - Cry For Me.mp3"),
        .init(id: "1FJRtix5HcmIf2KYk90O8IS-aBw64doNi", title: "Dark Thoughts", artist: "Lil Tecca", artwork: "https://cdn-images.dzcdn.net/images/cover/60a2a934343f79bc072539eac02526f0/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "045. Lil Tecca - Dark Thoughts.mp3"),
        .init(id: "1dR4ZPSj2nOZE-8X5QFjDbc68ZKxIpIK0", title: "Residuals", artist: "Chris Brown", artwork: "https://cdn-images.dzcdn.net/images/cover/d40b73f50ac9badee18d53685c838aba/1000x1000-000000-80-0-0.jpg", genre: "R&B", fileName: "046. Chris Brown - Residuals.mp3"),
        .init(id: "1mvzZBSWiA9i544Yh4fCGG97TBFe06b8F", title: "DENIAL IS A RIVER", artist: "Doechii", artwork: "https://cdn-images.dzcdn.net/images/cover/6859bfeb4c552a6e9de93b5eec59098c/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "047. Doechii - DENIAL IS A RIVER.mp3"),
        .init(id: "1WZpdkb0bauQSnmbnGACT3t7QtNxb7Tis", title: "DtMF", artist: "Bad Bunny", artwork: "https://cdn-images.dzcdn.net/images/cover/d98eaccfbb945bdf68241d6de7fe6a49/1000x1000-000000-80-0-0.jpg", genre: "Pop", fileName: "048. Bad Bunny - DtMF.mp3"),
        .init(id: "1IRvryEuuVEidy96Icef0R88PddBZZmIM", title: "Indigo (feat. Avery Anna)", artist: "Sam Barber", artwork: "https://cdn-images.dzcdn.net/images/cover/9fd9060352b773f6de7ebdf377e72698/1000x1000-000000-80-0-0.jpg", genre: "Country", fileName: "049. Sam Barber - Indigo (feat. Avery Anna).mp3"),
        .init(id: "1oMoMeuUdaPR9Nr37N28-FoSJLYvdm4mF", title: "Am I Okay?", artist: "Megan Moroney", artwork: "https://cdn-images.dzcdn.net/images/artist/80e2b4588aa126ca5f55ce341ed8bc1c/1000x1000-000000-80-0-0.jpg", genre: "Country", fileName: "050. Megan Moroney - Am I Okay_.mp3"),
        .init(id: "1I5RL4KZIQ4Ee4sRnSDeQf_o8FB5JX_yw", title: "Janice STFU", artist: "Drake", artwork: "https://cdn-images.dzcdn.net/images/cover/478562cdbafe4faa1515bd457042cc4a/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "01. [SpotiSoft] Janice STFU - Drake.mp3"),
        .init(id: "10LydoJj7Vl-BOMNgncZoO03XcmpPeJZ4", title: "One Dance", artist: "Drake, Wizkid & Kyla", artwork: "https://cdn-images.dzcdn.net/images/cover/478562cdbafe4faa1515bd457042cc4a/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "02. [SpotiSoft] One Dance - Drake, Wizkid, Kyla.mp3"),
        .init(id: "1MyxpSdEvsUdxBUC4Xkj9DvsrdzVw5AZK", title: "Headlines", artist: "Drake", artwork: "https://cdn-images.dzcdn.net/images/cover/e008e6fa86dd3da7de39549da18e48bc/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "05. [SpotiSoft] Headlines - Drake.mp3"),
        .init(id: "1ZER97qvzAxIsyIrBo1hbM2uH_p7xrbnI", title: "God's Plan", artist: "Drake", artwork: "https://cdn-images.dzcdn.net/images/cover/478562cdbafe4faa1515bd457042cc4a/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "06. [SpotiSoft] God's Plan - Drake.mp3"),
        .init(id: "1DeC4Q0ELQ4ssB_UGhoRvFQLW21L-g_eC", title: "Shabang", artist: "Drake", artwork: "https://cdn-images.dzcdn.net/images/cover/478562cdbafe4faa1515bd457042cc4a/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "07. [SpotiSoft] Shabang - Drake.mp3"),
        .init(id: "1jkyXDA1U6IHK8oPSRhN_OyfBgmM4N3HX", title: "Whisper My Name", artist: "Drake", artwork: "https://cdn-images.dzcdn.net/images/cover/478562cdbafe4faa1515bd457042cc4a/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "09. [SpotiSoft] Whisper My Name - Drake.mp3"),
        .init(id: "1Z11r94x5bT9e1gQRcaCFY5Ur8D_p7S8S", title: "Hotline Bling", artist: "Drake", artwork: "https://cdn-images.dzcdn.net/images/cover/478562cdbafe4faa1515bd457042cc4a/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "Drake - Hotline Bling.mp3"),
        .init(id: "1kTl11wALET7Fkc_nvMXWAOBrI57A_C17", title: "Passionfruit", artist: "Drake", artwork: "https://cdn-images.dzcdn.net/images/cover/478562cdbafe4faa1515bd457042cc4a/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "Passionfruit.mp3"),
        .init(id: "1NVEjrqGLZXcn_mYn4aC_n3QzHEQyve8i", title: "2SEATER (feat. Aaron Shaw, Samantha Nelson & Austin Feinstein)", artist: "Tyler, The Creator", artwork: "https://cdn-images.dzcdn.net/images/cover/d79052872c09468fd80bd288928962c9/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "2SEATER (feat. Aaron Shaw, Samantha Nelson & Austin Feinstein).mp3"),
        .init(id: "1VrixphflWPmLhDF086XuZoMq5WL2px6d", title: "48", artist: "Tyler, The Creator", artwork: "https://cdn-images.dzcdn.net/images/cover/d79052872c09468fd80bd288928962c9/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "48.mp3"),
        .init(id: "1spj6Soc_s4ikFaFYLV30_jzEv02LayDV", title: "435", artist: "Tyler, The Creator", artwork: "https://cdn-images.dzcdn.net/images/cover/d79052872c09468fd80bd288928962c9/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "435.mp3"),
        .init(id: "1g8XkbfeKwu2HDOCMfSI9Bwp46m0Os_-f", title: "Analog", artist: "Tyler, The Creator", artwork: "https://cdn-images.dzcdn.net/images/cover/d79052872c09468fd80bd288928962c9/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "Analog.mp3"),
        .init(id: "1DRI_dXv4lZBE56rC_HUw9ZzMSiFd9VKu", title: "Answer", artist: "Tyler, The Creator", artwork: "https://cdn-images.dzcdn.net/images/cover/d79052872c09468fd80bd288928962c9/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "Answer.mp3"),
        .init(id: "1ejDtN3z97tGC0jrPOcEccVRHq-WiTkAm", title: "AU79", artist: "Tyler, The Creator", artwork: "https://cdn-images.dzcdn.net/images/cover/d79052872c09468fd80bd288928962c9/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "AU79.mp3"),
        .init(id: "1wIxJtJzkiJOq4SI_iTfr_Nkrm9_EoY6h", title: "Awkward", artist: "Tyler, The Creator", artwork: "https://cdn-images.dzcdn.net/images/cover/d79052872c09468fd80bd288928962c9/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "Awkward.mp3"),
        .init(id: "1Wga-LQd8bEdrZ5g_OPDHLoEdmEEkZM72", title: "B.S.D.", artist: "Tyler, The Creator", artwork: "https://cdn-images.dzcdn.net/images/cover/d79052872c09468fd80bd288928962c9/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "B.S.D..mp3"),
        .init(id: "1z7hAdUV-iaUOkiDynngSaPAb5syTp8wF", title: "Bastard", artist: "Tyler, The Creator", artwork: "https://cdn-images.dzcdn.net/images/cover/d79052872c09468fd80bd288928962c9/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "Bastard.mp3"),
        .init(id: "1KheDAK-eRLO5HK-xawcrXE4VKE7WxvQo", title: "BEST INTEREST", artist: "Tyler, The Creator", artwork: "https://cdn-images.dzcdn.net/images/cover/d79052872c09468fd80bd288928962c9/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "BEST INTEREST.mp3"),
        .init(id: "1jieeyPZTiXSSdlRPh5Iq6UH1ISvr1Vu7", title: "Big Bag", artist: "Tyler, The Creator", artwork: "https://cdn-images.dzcdn.net/images/cover/d79052872c09468fd80bd288928962c9/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "Big Bag.mp3"),
        .init(id: "1giycozcx4PRvYnDDq4H6oMPAyCAMnxmV", title: "BLOW MY LOAD (feat. Wanya Morris, Dâm-Funk, Austin Feinstein & Sydney Bennett)", artist: "Tyler, The Creator", artwork: "https://cdn-images.dzcdn.net/images/cover/502b157c53630785c3f499fd032baf96/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "BLOW MY LOAD (feat. Wanya Morris, Dâm-Funk, Austin Feinstein & Sydney Bennett).mp3"),
        .init(id: "17AMSIJKJ5hkHBNABxNQeY72HDzi8nCe7", title: "Boredom (feat. Rex Orange County & Anna of the North)", artist: "Tyler, The Creator", artwork: "https://cdn-images.dzcdn.net/images/cover/a7a16b8f63b1ec0e9fbd327619966737/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "Boredom (feat. Rex Orange County & Anna of the North).mp3"),
        .init(id: "1FZjzpL3RwgoQ7L25nPqeiDaVnCq7hV7-", title: "BUFFALO (feat. Shane Powers)", artist: "Tyler, The Creator", artwork: "https://cdn-images.dzcdn.net/images/cover/502b157c53630785c3f499fd032baf96/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "BUFFALO (feat. Shane Powers).mp3"),
        .init(id: "1nbSXHUhXVDO4GBtBbtfCKcnyW-TbGBb9", title: "Burger", artist: "Tyler, The Creator", artwork: "https://cdn-images.dzcdn.net/images/cover/65d4a36d03918097176d42f8f55900af/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "Burger.mp3"),
        .init(id: "193oqNpAJrFhiLct3P3IAuQXu-jiR19gU", title: "CHERRY BOMB", artist: "Tyler, The Creator", artwork: "https://cdn-images.dzcdn.net/images/cover/b3b7c63cc6d67688fe9c2f56b62f2197/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "CHERRY BOMB.mp3"),
        .init(id: "16HGhEjvkNT-mcJHEc1TQsx4xx0EyR_yW", title: "Cindy Lou's Wish", artist: "Tyler, The Creator", artwork: "https://cdn-images.dzcdn.net/images/cover/d79052872c09468fd80bd288928962c9/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "Cindy Lou's Wish.mp3"),
        .init(id: "1sVZNB889LhhR8TmAe6RR6mYzNr5uETsx", title: "Colossus", artist: "Tyler, The Creator", artwork: "https://cdn-images.dzcdn.net/images/cover/243cc17e7688cb2f9739120ae4eb9912/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "Colossus.mp3"),
        .init(id: "1XeUUnQbsVodlWaovAkOiuqcZH0_PFg4B", title: "CORSO", artist: "Tyler, The Creator", artwork: "https://cdn-images.dzcdn.net/images/cover/2d740784396546039fe626ac2b92877b/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "CORSO.mp3"),
        .init(id: "1gCc5yJzmFMF_UQysFVQF_n8iqO14pBRi", title: "Cowboy", artist: "Tyler, The Creator", artwork: "https://cdn-images.dzcdn.net/images/cover/243cc17e7688cb2f9739120ae4eb9912/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "Cowboy.mp3"),
        .init(id: "1zcOA-htWbqlSG0COrlmtHfrFlsZYk6bR", title: "DEATHCAMP (feat. Cole Alexander)", artist: "Tyler, The Creator", artwork: "https://cdn-images.dzcdn.net/images/cover/502b157c53630785c3f499fd032baf96/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "DEATHCAMP (feat. Cole Alexander).mp3"),
        .init(id: "16AV_QgKg6pI-wNwjB3I1N-gWresqDm7K", title: "Domo23", artist: "Tyler, The Creator", artwork: "https://cdn-images.dzcdn.net/images/cover/243cc17e7688cb2f9739120ae4eb9912/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "Domo23.mp3"),
        .init(id: "1XFiAPND4tE8FalJdkIEuCdFhHE_PWTY0", title: "Droppin' Seeds (feat. Lil' Wayne)", artist: "Tyler, The Creator", artwork: "https://cdn-images.dzcdn.net/images/cover/d79052872c09468fd80bd288928962c9/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "Droppin' Seeds (feat. Lil' Wayne).mp3"),
        .init(id: "17gk1XbkViNndWg94eRyT37FMyGPDDPij", title: "EARFQUAKE", artist: "Tyler, The Creator", artwork: "https://cdn-images.dzcdn.net/images/cover/041ab5ceb6fb6ebf9512966835be9e1b/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "EARFQUAKE.mp3"),
        .init(id: "1TP56shXsWuAcZMLoepX9pbTSYh8m9dMk", title: "Enjoy Right Now, Today", artist: "Tyler, The Creator", artwork: "https://cdn-images.dzcdn.net/images/cover/a7a16b8f63b1ec0e9fbd327619966737/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "Enjoy Right Now, Today.mp3"),
        .init(id: "10wvdGvnVL_BKEYX82ZDOQyq9yqStO9Cm", title: "EXACTLY WHAT YOU RUN FROM YOU END UP CHASING", artist: "Tyler, The Creator", artwork: "https://cdn-images.dzcdn.net/images/cover/041ab5ceb6fb6ebf9512966835be9e1b/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "EXACTLY WHAT YOU RUN FROM YOU END UP CHASING.mp3"),
        .init(id: "1Zl333INCRuW8XeI1wHomfuepbwQXVXGL", title: "FIND YOUR WINGS (feat. Roy Ayers, Sydney Bennett & Kali Uchis)", artist: "Tyler, The Creator", artwork: "https://cdn-images.dzcdn.net/images/cover/502b157c53630785c3f499fd032baf96/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "FIND YOUR WINGS (feat. Roy Ayers, Sydney Bennett & Kali Uchis).mp3"),
        .init(id: "1G1q5wkY8Hv98qNVZb-UNh5vd2fEGYdP-", title: "Fish", artist: "Tyler, The Creator", artwork: "https://cdn-images.dzcdn.net/images/cover/65d4a36d03918097176d42f8f55900af/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "Fish.mp3"),
        .init(id: "1NKvM7KqjjeAY1YP3WaFv9kb-uuqtEPCI", title: "Foreword (feat. Rex Orange County)", artist: "Tyler, The Creator", artwork: "https://cdn-images.dzcdn.net/images/cover/a7a16b8f63b1ec0e9fbd327619966737/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "Foreword (feat. Rex Orange County).mp3"),
        .init(id: "1dEvVeNjy7gNJNgH2XzWKitNqRrJ0m5El", title: "French (feat. Hodgy)", artist: "Tyler, The Creator", artwork: "https://cdn-images.dzcdn.net/images/cover/ec4fbc00ee667077e745bbc4368bc0fe/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "French (feat. Hodgy).mp3"),
        .init(id: "1cLSkxjRFEur0Z4AUBhInfFvKyXSQeH5t", title: "Garbage", artist: "Tyler, The Creator", artwork: "https://cdn-images.dzcdn.net/images/cover/a623166c2ddc61d8251e74ab60303b7b/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "Garbage.mp3"),
        .init(id: "1_xqTwk_BgLW8LY28hLLkctn-i8-t3dii", title: "Garden Shed (feat. Estelle)", artist: "Tyler, The Creator", artwork: "https://cdn-images.dzcdn.net/images/cover/a7a16b8f63b1ec0e9fbd327619966737/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "Garden Shed (feat. Estelle).mp3"),
        .init(id: "166XR_NuepIn1U8wFCgIa2wHOQsVQeycW", title: "Glitter", artist: "Tyler, The Creator", artwork: "https://cdn-images.dzcdn.net/images/cover/a7a16b8f63b1ec0e9fbd327619966737/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "Glitter.mp3"),
        .init(id: "1NfU_y7ypk2PjZR6i0fVBJ7VVa_n9vgNM", title: "Goblin", artist: "Tyler, The Creator", artwork: "https://cdn-images.dzcdn.net/images/cover/65d4a36d03918097176d42f8f55900af/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "Goblin.mp3"),
        .init(id: "1_tEYWKdt-RcyxDeNCp4PtR4aHTN88h4u", title: "Golden", artist: "Tyler, The Creator", artwork: "https://cdn-images.dzcdn.net/images/cover/65d4a36d03918097176d42f8f55900af/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "Golden.mp3"),
        .init(id: "1FnUphvo4QeuNB9ZlUNYgSaOf7lAtwn1X", title: "GROUP B", artist: "Tyler, The Creator", artwork: "https://cdn-images.dzcdn.net/images/cover/01eeffc29b2216fcf614489fc373f99d/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "GROUP B.mp3"),
        .init(id: "17_04GMhTeUCNhtYg9zAhTLGxU-Ld1An1", title: "Her", artist: "Tyler, The Creator", artwork: "https://cdn-images.dzcdn.net/images/cover/65d4a36d03918097176d42f8f55900af/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "Her.mp3"),
        .init(id: "1RYzeNEIVnWk2WQII_mLaAzZp2ROaID7d", title: "Hot Chocolate (feat. Jerry Paper)", artist: "Tyler, The Creator", artwork: "https://cdn-images.dzcdn.net/images/cover/6c23a4161be01dd7aa16454f285598d4/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "Hot Chocolate (feat. Jerry Paper).mp3"),
        .init(id: "1YpoIAxC-NrGSdNB6CNvXxRlXAZzpC3-t", title: "HOT WIND BLOWS (feat. Lil Wayne)", artist: "Tyler, The Creator", artwork: "https://cdn-images.dzcdn.net/images/cover/2d740784396546039fe626ac2b92877b/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "HOT WIND BLOWS (feat. Lil Wayne).mp3"),
        .init(id: "15eKsBXzpHy0DpMPXKb6HE6YvGE4HVbBM", title: "I Ain't Got Time!", artist: "Tyler, The Creator", artwork: "https://cdn-images.dzcdn.net/images/cover/d79052872c09468fd80bd288928962c9/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "I Ain't Got Time!.mp3"),
        .init(id: "1-82k1rq4K56Df1jchfAuQG7SbqcsxUGw", title: "I Am the Grinch (feat. Fletcher Jones)", artist: "Tyler, The Creator", artwork: "https://cdn-images.dzcdn.net/images/cover/4da96d3cccd989b9e4281552d3109458/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "I Am the Grinch (feat. Fletcher Jones).mp3"),
        .init(id: "10GEt-qaSHJ526OrRVgyJ8hp0vJ64wJMt", title: "I DON'T LOVE YOU ANYMORE", artist: "Tyler, The Creator", artwork: "https://cdn-images.dzcdn.net/images/cover/d79052872c09468fd80bd288928962c9/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "I DON'T LOVE YOU ANYMORE.mp3"),
        .init(id: "1onghTAQHEh9DQdFa1NQSCvYrxSOA4Fz0", title: "I THINK", artist: "Tyler, The Creator", artwork: "https://cdn-images.dzcdn.net/images/cover/041ab5ceb6fb6ebf9512966835be9e1b/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "I THINK.mp3"),
        .init(id: "1RYMetrdxeKoUqb3BBolBN_nCp_cxzWQj", title: "IFHY (feat. Pharrell)", artist: "Tyler, The Creator", artwork: "https://cdn-images.dzcdn.net/images/cover/243cc17e7688cb2f9739120ae4eb9912/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "IFHY (feat. Pharrell).mp3"),
        .init(id: "1LcYynBGYZHMlJU4Z-OPbdyIb-H_1u9-J", title: "IGOR'S THEME", artist: "Tyler, The Creator", artwork: "https://cdn-images.dzcdn.net/images/cover/d79052872c09468fd80bd288928962c9/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "IGOR'S THEME.mp3"),
        .init(id: "1l_MTGbgFL3-p9ghih8T8hKr5az0nMnEL", title: "Jamba (feat. Hodgy)", artist: "Tyler, The Creator", artwork: "https://cdn-images.dzcdn.net/images/cover/243cc17e7688cb2f9739120ae4eb9912/1000x1000-000000-80-0-0.jpg", genre: "Hip-Hop", fileName: "Jamba (feat. Hodgy).mp3"),
        .init(id: "1AGLuA5OFrNo1_SCguxqnIZ7wkQixeKGg", title: "Starboy", artist: "The Weeknd", artwork: "https://cdn-images.dzcdn.net/images/cover/134778e4c4f19ea71c82408300925a9a/1000x1000-000000-80-0-0.jpg", genre: "R&B", fileName: "1. Starboy"),
        .init(id: "1Lr14fQaHiu50ImLfQ-IAxpgH09n7k3Hm", title: "Party Monster", artist: "The Weeknd", artwork: "https://cdn-images.dzcdn.net/images/cover/134778e4c4f19ea71c82408300925a9a/1000x1000-000000-80-0-0.jpg", genre: "R&B", fileName: "2. Party Monster"),
        .init(id: "1oUqI3WS3Zqh8voUcsMDH3U0uJns4A4iE", title: "False Alarm", artist: "The Weeknd", artwork: "https://cdn-images.dzcdn.net/images/cover/134778e4c4f19ea71c82408300925a9a/1000x1000-000000-80-0-0.jpg", genre: "R&B", fileName: "3. False Alarm"),
        .init(id: "1QBtRgiYeyIlvxGaWqZDizQp-djQVPei6", title: "Reminder", artist: "The Weeknd", artwork: "https://cdn-images.dzcdn.net/images/cover/134778e4c4f19ea71c82408300925a9a/1000x1000-000000-80-0-0.jpg", genre: "R&B", fileName: "4. Reminder"),
        .init(id: "1Q1ZV6AdsNBfiWCgfiwzx1lrx3MdZxn7I", title: "Rockin", artist: "The Weeknd", artwork: "https://cdn-images.dzcdn.net/images/cover/134778e4c4f19ea71c82408300925a9a/1000x1000-000000-80-0-0.jpg", genre: "R&B", fileName: "5. Rockin"),
        .init(id: "1SPSsl2YxfFOa0cIOVQ6Rqmj2D4_OvNB9", title: "Secrets", artist: "The Weeknd", artwork: "https://cdn-images.dzcdn.net/images/cover/134778e4c4f19ea71c82408300925a9a/1000x1000-000000-80-0-0.jpg", genre: "R&B", fileName: "6. Secrets"),
        .init(id: "1SsQpRD2FFXG2On6fD6f6W0BTVKn6Kn--", title: "True Colors", artist: "The Weeknd", artwork: "https://cdn-images.dzcdn.net/images/cover/134778e4c4f19ea71c82408300925a9a/1000x1000-000000-80-0-0.jpg", genre: "R&B", fileName: "7. True Colors"),
        .init(id: "1loozCPRqYh00_-AmQVz7QXexgl3SBq_J", title: "Stargirl Interlude", artist: "The Weeknd", artwork: "https://cdn-images.dzcdn.net/images/cover/134778e4c4f19ea71c82408300925a9a/1000x1000-000000-80-0-0.jpg", genre: "R&B", fileName: "8. Stargirl Interlude"),
        .init(id: "1tjXrnXSXAuR5cPJAipEPvU-QVfpsdHjK", title: "Sidewalks (ft. Kendrick Lamar)", artist: "The Weeknd", artwork: "https://cdn-images.dzcdn.net/images/cover/134778e4c4f19ea71c82408300925a9a/1000x1000-000000-80-0-0.jpg", genre: "R&B", fileName: "9. Sidewalks (ft. Kendrick Lamar)"),
        .init(id: "1GMNgNa5PdIi_TcRMs2uaUhLFjEKHOi-O", title: "Six Feet Under", artist: "The Weeknd", artwork: "https://cdn-images.dzcdn.net/images/cover/134778e4c4f19ea71c82408300925a9a/1000x1000-000000-80-0-0.jpg", genre: "R&B", fileName: "10. Six Feet Under"),
        .init(id: "13EiPelbfpQGFDUy74ObT5FiXooeobQnK", title: "Love To Lay", artist: "The Weeknd", artwork: "https://cdn-images.dzcdn.net/images/cover/134778e4c4f19ea71c82408300925a9a/1000x1000-000000-80-0-0.jpg", genre: "R&B", fileName: "11. Love To Lay"),
        .init(id: "13fcoPyZfy1L8G-wfMkluqngavHr2slXD", title: "A Lonely Night", artist: "The Weeknd", artwork: "https://cdn-images.dzcdn.net/images/cover/134778e4c4f19ea71c82408300925a9a/1000x1000-000000-80-0-0.jpg", genre: "R&B", fileName: "12. A Lonely Night"),
        .init(id: "1GEJvaNXQjFrSFkh65t_YGwBeqVgix1_Q", title: "Attention", artist: "The Weeknd", artwork: "https://cdn-images.dzcdn.net/images/cover/134778e4c4f19ea71c82408300925a9a/1000x1000-000000-80-0-0.jpg", genre: "R&B", fileName: "13. Attention"),
        .init(id: "1pHzTGhoafAZAb9r6s_nzD2rcm2g46RFZ", title: "Ordinary Life", artist: "The Weeknd", artwork: "https://cdn-images.dzcdn.net/images/cover/134778e4c4f19ea71c82408300925a9a/1000x1000-000000-80-0-0.jpg", genre: "R&B", fileName: "14. Ordinary Life"),
        .init(id: "1cdJVpT9biIgt9fvYxbGf78YkK7M6Tc-p", title: "Nothing Without You", artist: "The Weeknd", artwork: "https://cdn-images.dzcdn.net/images/cover/134778e4c4f19ea71c82408300925a9a/1000x1000-000000-80-0-0.jpg", genre: "R&B", fileName: "15.  Nothing Without You"),
        .init(id: "1DnNiDRO7SQULQ1OCjTqU3B7iL4uxRqzw", title: "All I Know (ft. Future)", artist: "The Weeknd", artwork: "https://cdn-images.dzcdn.net/images/cover/134778e4c4f19ea71c82408300925a9a/1000x1000-000000-80-0-0.jpg", genre: "R&B", fileName: "16. All I Know (ft. Future)"),
        .init(id: "1U7i0kaGXXLLHFMFbuXGIkBtSCqfAO8Xh", title: "Die For You", artist: "The Weeknd", artwork: "https://cdn-images.dzcdn.net/images/cover/134778e4c4f19ea71c82408300925a9a/1000x1000-000000-80-0-0.jpg", genre: "R&B", fileName: "17. Die For You"),
        .init(id: "1SIMPrr48Zzzru0OgISbFUTEuG2Ss19eY", title: "I Feel It Coming", artist: "The Weeknd", artwork: "https://cdn-images.dzcdn.net/images/cover/134778e4c4f19ea71c82408300925a9a/1000x1000-000000-80-0-0.jpg", genre: "R&B", fileName: "18. I Feel It Coming")
    ]

    // Public destinations whose matching artwork is included in the supplied folder.
    static let apps: [MediaHubApp] = [
        .init(id: "geforce", title: "GeForce NOW", url: "https://play.geforcenow.com", cover: "geforce"),
        .init(id: "github", title: "GitHub", url: "https://github.com", cover: "github"),
        .init(id: "spotify", title: "Spotify", url: "https://open.spotify.com", cover: "spotify"),
        .init(id: "netflix", title: "Netflix", url: "https://netflix.com", cover: "netflix"),
        .init(id: "hulu", title: "Hulu", url: "https://hulu.com", cover: "hulu"),
        .init(id: "pinterest", title: "Pinterest", url: "https://pinterest.com", cover: "pinterist"),
        .init(id: "soundcloud", title: "SoundCloud", url: "https://soundcloud.com", cover: "soundcloud"),
        .init(id: "espn", title: "ESPN", url: "https://espn.com", cover: "espn"),
        .init(id: "fifa", title: "FIFA Rosters", url: "https://www.ea.com/games/ea-sports-fc", cover: "fifarosters"),
        .init(id: "rumble", title: "Rumble", url: "https://rumble.com", cover: "rumble"),
        .init(id: "yahoo", title: "Yahoo", url: "https://yahoo.com", cover: "yahoo"),
        .init(id: "vercel", title: "Vercel", url: "https://vercel.com", cover: "vercel"),
        .init(id: "vscode", title: "VS Code", url: "https://vscode.dev", cover: "vscode"),
        .init(id: "y8games", title: "Y8 Games", url: "https://y8.com", cover: "y8games"),
        .init(id: "w3school", title: "W3Schools", url: "https://w3schools.com", cover: "w3school"),
        .init(id: "scratch", title: "Scratch", url: "https://scratch.mit.edu", cover: "scratch"),
        .init(id: "gmail", title: "Gmail", url: "https://mail.google.com", cover: "gmail"),
        .init(id: "drive", title: "Google Drive", url: "https://drive.google.com", cover: "drive")
    ]
}

private struct HubSearchField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 11.5))
            TextField(placeholder, text: $text).textFieldStyle(.plain).font(.system(size: 12.5))
        }
        .foregroundStyle(.white.opacity(0.65))
        .padding(.horizontal, 11).frame(width: 210, height: 32)
        .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.white.opacity(0.13)))
    }
}

struct MusicHubPage: View {
    @State private var search = ""
    @State private var genre = "All"
    @State private var artist = "All Artists"
    @ObservedObject private var player = MusicPlaybackController.shared
    @ObservedObject private var userMusic = UserMusicLibrary.shared

    private var allTracks: [MediaHubTrack] { MediaHubCatalog.tracks + userMusic.tracks }
    private var genres: [String] { ["All"] + Array(Set(allTracks.map(\.genre))).sorted() }
    private var artists: [String] { ["All Artists"] + Array(Set(allTracks.map(\.artist))).sorted() }

    private var visible: [MediaHubTrack] {
        allTracks.filter {
            (genre == "All" || $0.genre == genre) &&
            (artist == "All Artists" || $0.artist == artist) &&
            (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) ||
             $0.artist.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Music").font(.system(size: 28, weight: .bold)).foregroundStyle(.white)
                    Text("Choose a song to download it once, then play it locally in LiveWall")
                        .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.48))
                }
                Spacer()
                Button(action: userMusic.chooseAndImport) {
                    Label("Add MP3", systemImage: "plus.circle.fill")
                        .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 12).frame(height: 32)
                        .background(DS.blue, in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain).help("Copy MP3 files into LiveWall")
                HubSearchField(placeholder: "Search music", text: $search)
            }

            Text("Genres").font(.system(size: 10.5, weight: .bold)).foregroundStyle(.white.opacity(0.48))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(genres, id: \.self) { item in
                        Button { genre = item } label: {
                            Text(item).font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(genre == item ? .white : .white.opacity(0.62))
                                .padding(.horizontal, 13).frame(height: 29)
                                .background(genre == item ? AnyShapeStyle(DS.accent) : AnyShapeStyle(Color.white.opacity(0.08)), in: Capsule())
                        }.buttonStyle(.plain)
                    }
                }
            }

            Text("Artists").font(.system(size: 10.5, weight: .bold)).foregroundStyle(.white.opacity(0.48))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(artists, id: \.self) { item in
                        Button { artist = item } label: {
                            Text(item).font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(artist == item ? .white : .white.opacity(0.62))
                                .padding(.horizontal, 13).frame(height: 29)
                                .background(artist == item ? AnyShapeStyle(DS.accent) : AnyShapeStyle(Color.white.opacity(0.08)), in: Capsule())
                        }.buttonStyle(.plain)
                    }
                }
            }

            if let current = player.currentTrack {
                MusicControlBar(track: current, player: player)
            }

            if let error = player.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 12)], spacing: 16) {
                ForEach(visible) { track in
                    MusicTrackCard(track: track,
                                   active: player.currentTrack?.id == track.id,
                                   playing: player.isPlaying,
                                   action: {
                                       if player.currentTrack?.id == track.id { player.togglePlayback() }
                                       else { player.play(track, in: visible) }
                                   })
                }
            }
        }
    }
}

private struct MusicControlBar: View {
    let track: MediaHubTrack
    @ObservedObject var player: MusicPlaybackController

    var body: some View {
        HStack(spacing: 13) {
            MusicArtwork(track: track)
            .frame(width: 48, height: 48).clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(track.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text(player.isLoading ? "Downloading from Google Drive…" : track.artist)
                    .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.48)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: player.previous) { controlIcon("backward.fill") }
            Button(action: player.togglePlayback) {
                controlIcon(player.isPlaying ? "pause.fill" : "play.fill", primary: true)
            }
            Button(action: player.next) { controlIcon("forward.fill") }
            Button(action: player.stop) { controlIcon("stop.fill") }.help("Stop music")

            Image(systemName: player.volume < 0.02 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.48))
            Slider(value: $player.volume, in: 0...1).frame(width: 100).help("Music volume")
        }
        .buttonStyle(.plain)
        .padding(10)
        .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(.white.opacity(0.12)))
    }

    private func controlIcon(_ name: String, primary: Bool = false) -> some View {
        Image(systemName: name).font(.system(size: 11.5, weight: .bold)).foregroundStyle(.white)
            .frame(width: primary ? 34 : 29, height: primary ? 34 : 29)
            .background(primary ? AnyShapeStyle(DS.accent) : AnyShapeStyle(Color.white.opacity(0.09)), in: Circle())
    }
}

private struct MusicTrackCard: View {
    let track: MediaHubTrack
    let active: Bool
    let playing: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                MusicArtwork(track: track)
                .aspectRatio(1, contentMode: .fit).clipped()
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    Group {
                        if active && MusicPlaybackController.shared.isLoading {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: active && playing ? "pause.fill" : "play.fill")
                                .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        }
                    }
                    .frame(width: 31, height: 31).background(DS.blue, in: Circle()).padding(8)
                    .opacity(hover || active ? 1 : 0)
                }
                .overlay(alignment: .topTrailing) {
                    if MusicPlaybackController.shared.isDownloaded(track) {
                        Label("Downloaded", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 5)
                            .background(.black.opacity(0.58), in: Capsule()).padding(7)
                    }
                }
                Text(track.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text(track.artist).font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.48)).lineLimit(1)
            }
        }
        .buttonStyle(.plain).onHover { hover = $0 }
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(active ? DS.blue.opacity(0.9) : .clear, lineWidth: 2))
    }
}

private struct MusicArtwork: View {
    let track: MediaHubTrack

    var body: some View {
        ZStack {
            LinearGradient(colors: [DS.purple.opacity(0.88), DS.blue.opacity(0.72)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let url = URL(string: track.artwork), !track.artwork.isEmpty {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
    }

    private var fallback: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note").font(.system(size: 30, weight: .bold))
            Text(track.artist.prefix(1).uppercased())
                .font(.system(size: 15, weight: .heavy, design: .rounded))
        }
        .foregroundStyle(.white.opacity(0.92))
    }
}

struct AppsHubPage: View {
    @State private var search = ""
    private var visible: [MediaHubApp] {
        search.isEmpty ? MediaHubCatalog.apps : MediaHubCatalog.apps.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Apps").font(.system(size: 28, weight: .bold)).foregroundStyle(.white)
                    Text("Quick links imported from the supplied PeteZahGames folder")
                        .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.48))
                }
                Spacer()
                HubSearchField(placeholder: "Search apps", text: $search)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 12)], spacing: 12) {
                ForEach(visible) { app in AppHubCard(app: app) }
            }
        }
    }
}

private struct AppHubCard: View {
    let app: MediaHubApp
    @State private var hover = false

    var body: some View {
        Button { if let url = app.pageURL { NSWorkspace.shared.open(url) } } label: {
            ZStack(alignment: .bottomLeading) {
                if let image = coverImage {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(colors: [DS.blue.opacity(0.68), DS.purple.opacity(0.72)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "app.fill").font(.system(size: 31)).foregroundStyle(.white.opacity(0.82))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                LinearGradient(colors: [.clear, .black.opacity(0.78)], startPoint: .center, endPoint: .bottom)
                Text(app.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                    .lineLimit(1).padding(10)
                Image(systemName: "arrow.up.right.square.fill").font(.system(size: 13)).foregroundStyle(.white)
                    .padding(9).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .opacity(hover ? 1 : 0)
            }
            .aspectRatio(4.0 / 3.0, contentMode: .fit).clipped()
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(hover ? DS.blue.opacity(0.9) : .white.opacity(0.1), lineWidth: hover ? 2 : 1))
            .shadow(color: .black.opacity(0.24), radius: 8, y: 5)
        }
        .buttonStyle(.plain).onHover { hover = $0 }
    }

    private var coverImage: NSImage? {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("AppCovers", isDirectory: true) else { return nil }
        return NSImage(contentsOf: root.appendingPathComponent(app.cover).appendingPathExtension("jpg"))
    }
}
