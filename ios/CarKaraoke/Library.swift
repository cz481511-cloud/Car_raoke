import Foundation
import Observation

/// 一首歌：伴唱檔（或一般音檔）＋ 可選的人聲檔。
struct Song: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let artist: String?
    /// 播放的主音軌：「.伴唱」檔；沒有的話就是一般音檔
    let mainURL: URL
    /// 「.人聲」檔，用來切換 原唱／導唱
    let vocalsURL: URL?
    /// mainURL 是去過人聲的伴唱檔
    let isBackingTrack: Bool
    let addedAt: Date
    /// 時間同步歌詞「歌名 - 歌手.lrc」
    var lyricsURL: URL? = nil

    var canSwitchVocals: Bool { isBackingTrack && vocalsURL != nil }
    var files: [URL] { [mainURL] + [vocalsURL, lyricsURL].compactMap { $0 } }
    /// 不含資料夾路徑的名稱（App 重新安裝後資料夾路徑會變，設定要用這個當鍵）
    var stableKey: String { (id as NSString).lastPathComponent }
}

/// 歌曲庫：App 的「文件」資料夾（Finder 拖曳、AirDrop、匯入的檔案都放這裡）。
@MainActor
@Observable
final class Library {
    nonisolated static let instSuffix = ".伴唱"
    nonisolated static let vocalSuffix = ".人聲"
    nonisolated static let audioExtensions: Set<String> = ["m4a", "mp3", "aac", "wav", "caf", "aif", "aiff", "flac", "mp4"]
    nonisolated static let lyricsExtension = "lrc"

    private(set) var songs: [Song] = []
    let folder: URL

    init(folder: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]) {
        self.folder = folder
        reload()
    }

    func reload() {
        songs = Self.scan(folder)
    }

    /// 把檔案複製進歌曲庫，回傳成功的檔案數。
    @discardableResult
    func importFiles(_ urls: [URL]) -> Int {
        var count = 0
        let fm = FileManager.default
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/") {
                count += 1  // 已經在歌曲庫裡（例如 AirDrop 放進 Inbox）
                continue
            }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            let sources = isDir.boolValue
                ? ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
                : [url]
            for src in sources where Self.audioExtensions.contains(src.pathExtension.lowercased())
                || src.pathExtension.lowercased() == Self.lyricsExtension {
                let dest = folder.appendingPathComponent(src.lastPathComponent)
                do {
                    if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                    try fm.copyItem(at: src, to: dest)
                    count += 1
                } catch {
                    continue
                }
            }
        }
        reload()
        return count
    }

    func delete(_ song: Song) {
        for url in song.files { try? FileManager.default.removeItem(at: url) }
        reload()
    }

    /// 掃描資料夾，把「歌名 - 歌手.伴唱.m4a」和「歌名 - 歌手.人聲.m4a」配成一首歌。
    nonisolated static func scan(_ folder: URL) -> [Song] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .creationDateKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles]) else { return [] }
        struct Group { var inst: URL?; var vocals: URL?; var plain: URL?; var lyrics: URL?; var date = Date.distantPast }
        var groups: [String: Group] = [:]

        for case let url as URL in walker {
            let ext = url.pathExtension.lowercased()
            if ext == lyricsExtension {
                let key = url.deletingLastPathComponent().standardizedFileURL.path + "/"
                    + url.deletingPathExtension().lastPathComponent
                groups[key, default: Group()].lyrics = url
                continue
            }
            guard audioExtensions.contains(ext),
                  !url.lastPathComponent.hasSuffix(".tmp.m4a"),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            var stem = url.deletingPathExtension().lastPathComponent
            var kind = 0
            if stem.hasSuffix(instSuffix) {
                stem.removeLast(instSuffix.count); kind = 1
            } else if stem.hasSuffix(vocalSuffix) {
                stem.removeLast(vocalSuffix.count); kind = 2
            }
            let key = url.deletingLastPathComponent().standardizedFileURL.path + "/" + stem
            var group = groups[key] ?? Group()
            switch kind {
            case 1: group.inst = url
            case 2: group.vocals = url
            default: group.plain = url
            }
            group.date = max(group.date, values.creationDate ?? values.contentModificationDate ?? .distantPast)  // 歌詞不影響排序
            groups[key] = group
        }

        var songs: [Song] = []
        for (key, group) in groups {
            let (title, artist) = splitName((key as NSString).lastPathComponent)
            if let inst = group.inst {
                songs.append(Song(id: key, title: title, artist: artist, mainURL: inst,
                                  vocalsURL: group.vocals, isBackingTrack: true, addedAt: group.date,
                                  lyricsURL: group.lyrics))
            } else if let plain = group.plain {
                songs.append(Song(id: key, title: title, artist: artist, mainURL: plain,
                                  vocalsURL: nil, isBackingTrack: false, addedAt: group.date,
                                  lyricsURL: group.lyrics))
            }
        }
        return songs.sorted {
            $0.addedAt != $1.addedAt ? $0.addedAt > $1.addedAt
                : $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    /// 「歌名 - 歌手」→ (歌名, 歌手)
    nonisolated static func splitName(_ stem: String) -> (String, String?) {
        guard let range = stem.range(of: " - ") else { return (stem, nil) }
        let title = stem[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        let artist = stem[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return (title.isEmpty ? stem : title, artist.isEmpty ? nil : artist)
    }
}

// MARK: - 播放清單

/// 從 Spotify 匯入的播放清單／專輯：照原本的順序記下每首歌；做好、傳到手機的歌用檔名對到歌曲庫。
struct Playlist: Codable, Identifiable, Equatable, Sendable {
    struct Item: Codable, Identifiable, Equatable, Sendable {
        /// Spotify 歌曲 ID
        let id: String
        var title: String
        var artist: String?
        /// 傳到手機的檔名（不含「.伴唱.m4a」）；nil = 還沒傳過來
        var stem: String?
        /// Mac 上的進度：queued／searching／downloading／separating／done／failed／canceled
        var status: String = "queued"
        var error: String?
        var progress: Double?
        var ahead: Int?
        /// Mac 做好的檔案（手機照這些名字下載）
        var inst: String?
        var vocals: String?
        var lyrics: String?
        /// Mac 上的檔案已經刪掉了（以前傳到手機過）；手機上沒有的話要請 Mac 重做
        var delivered: Bool?

        var isWorking: Bool { ["queued", "searching", "downloading", "separating"].contains(status) }
        var needsDownload: Bool { status == "done" && stem == nil && inst != nil }
    }

    /// Spotify 的清單 ID（同一個清單再貼一次＝更新這一個）
    let id: String
    var kind: String  // playlist／album
    var name: String
    var owner: String?
    var link: String
    /// Mac 上這次匯入的編號（Mac 的伺服器重新啟動後就失效，手機會自動重新匯入）
    var serverID: String?
    var items: [Item]
    var created: Date

    var kindLabel: String { kind == "album" ? "專輯" : "播放清單" }
    var isImporting: Bool { items.contains { $0.isWorking || $0.needsDownload } }
    var failedCount: Int { items.filter { $0.status == "failed" }.count }
}

/// 手機上的播放清單（存在歌曲資料夾的隱藏檔 .playlists.json，不會出現在歌單裡）
@MainActor
@Observable
final class PlaylistStore {
    private(set) var playlists: [Playlist] = []
    @ObservationIgnored private let file: URL

    init(folder: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]) {
        file = folder.appendingPathComponent(".playlists.json")
        if let data = try? Data(contentsOf: file) {
            playlists = (try? JSONDecoder().decode([Playlist].self, from: data)) ?? []
        }
    }

    func playlist(_ id: String) -> Playlist? { playlists.first { $0.id == id } }

    /// 新的放最上面
    func upsert(_ p: Playlist, save persist: Bool = true) {
        if let i = playlists.firstIndex(where: { $0.id == p.id }) {
            playlists[i] = p
        } else {
            playlists.insert(p, at: 0)
        }
        if persist { save() }
    }

    func update(_ id: String, _ change: (inout Playlist) -> Void) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        change(&playlists[i])
        save()
    }

    func remove(_ id: String) {
        playlists.removeAll { $0.id == id }
        save()
    }

    /// 清單裡已經在手機上的歌（照清單順序）
    func songs(in p: Playlist, from library: Library) -> [Song] {
        let byKey = Dictionary(library.songs.map { ($0.stableKey, $0) }, uniquingKeysWith: { a, _ in a })
        return p.items.compactMap { $0.stem.flatMap { byKey[$0] } }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(playlists) else { return }
        try? data.write(to: file, options: .atomic)
    }
}
