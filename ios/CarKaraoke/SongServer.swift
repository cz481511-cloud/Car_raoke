import Foundation
import Network
import Observation
import Security
import UIKit

/// 跟家裡 Mac 上的「車上K歌伺服器」溝通：
/// 貼上 YouTube 或 Spotify 歌曲連結 → Mac 下載＋去人聲 → 下載回手機 → 自動播放（正在唱的話排到下一首）。
/// （Spotify 連結：Mac 讀出歌名、歌手、長度，在 YouTube 找同一首；Spotify 本身不提供音樂檔）
/// Spotify 播放清單／專輯：Mac 一首一首做，手機照清單順序建立播放清單，做好的歌陸續傳回來。
///
/// 手機只負責傳連結、等結果、下載兩個檔案；所有運算都在 Mac 上，不用任何雲端／AI 服務。
/// 配對：第一次連到一台 Mac 要輸入它的 6 位數配對碼，之後用 Mac 給的金鑰（存在鑰匙圈）連線。
/// Mac 不留歌：手機收好一首就通知 Mac（POST /received），Mac 刪掉自己那份。
/// 之後再點同一首時 Mac 回「delivered」：手機上有就直接唱，沒有就請 Mac 重做（redo）。
@MainActor
@Observable
final class SongServer {
    enum Connection: Equatable {
        case searching
        case connected(name: String)
        case needsPairing(name: String)  // 找到 Mac 了，但還沒輸入配對碼（或 Mac 換了配對碼）
        case notFound
        case denied  // 沒給「區域網路」權限
    }

    struct Request: Identifiable, Equatable {
        enum Stage: Equatable {
            case sending
            case queued(ahead: Int)
            case searching  // Spotify 歌曲：Mac 在 YouTube 找同一首
            case downloading
            case separating(Double?)
            case transferring
            case done
            case failed(String)
        }

        let id = UUID()
        let link: String
        var jobID: String?
        var title: String?
        var artist: String?
        var stage: Stage = .sending
        var outcome: String?
        /// 已經請 Mac 重做過（Mac 上刪掉了、手機上也沒有的歌）
        var redoAsked = false

        var isActive: Bool {
            switch stage {
            case .done, .failed: return false
            default: return true
            }
        }

        var needsPolling: Bool {
            guard jobID != nil else { return false }
            switch stage {
            case .queued, .searching, .downloading, .separating: return true
            default: return false
            }
        }
    }

    nonisolated static let defaultPort = 8765
    private static let addressKey = "serverAddress"

    private(set) var connection: Connection = .searching
    private(set) var requests: [Request] = []
    private(set) var syncStatus: String?
    private(set) var isSyncing = false
    /// 手動輸入的位址（Tailscale 或 Bonjour 找不到時用）
    private(set) var manualAddress: String
    /// 每次變動＝請畫面打開「輸入配對碼」
    private(set) var pairingPrompt = 0
    /// 顯示 Mac 的功能（貼連結、Mac 狀態、從 Mac 同步），並在網路上找 Mac。
    /// 從沒配對過的手機（例如朋友的）是 false：按「連接家裡的 Mac」才打開，配對成功或連上 Mac 後記住。
    private(set) var usesMac: Bool

    @ObservationIgnored private weak var library: Library?
    @ObservationIgnored private weak var player: KaraokePlayer?
    @ObservationIgnored private weak var playlists: PlaylistStore?
    @ObservationIgnored private var listTask: Task<Void, Never>?
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var bonjourCandidates: [String] = []
    @ObservationIgnored private var baseURL: URL?
    @ObservationIgnored private var connectTask: Task<Bool, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var pollFailures = 0
    /// 播放清單裡已經請 Mac 重做過的歌（Spotify 歌曲 ID），避免一直重送
    @ObservationIgnored private var redoAsked: Set<String> = []
    @ObservationIgnored private var isTidying = false
    /// 找到、但還沒配對的 Mac
    @ObservationIgnored private var pairingBase: URL?
    /// 連上的 Mac 的配對編號（Mac 重設配對時會換）
    @ObservationIgnored private var serverID: String?
    /// 目前連線帶的金鑰（session 每個要求都會在標頭帶著它）
    @ObservationIgnored private var sessionKey: String?
    @ObservationIgnored private var session: URLSession
    @ObservationIgnored private let usage: MacUsage

    nonisolated static let keyHeader = "X-CarKaraoke-Key"

    init(usage: MacUsage = MacUsage()) {
        self.usage = usage
        let used = usage.wasUsed
        if used { usage.remember() }  // 這個設定出現前就配對過的手機：記下來（之後 Mac 換配對碼、金鑰被刪也不會藏起來）
        usesMac = used
        manualAddress = UserDefaults.standard.string(forKey: Self.addressKey) ?? ""
        session = Self.makeSession(key: nil)
    }

    nonisolated private static func makeSession(key: String?) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.waitsForConnectivity = false
        if let key { config.httpAdditionalHeaders = [keyHeader: key] }
        return URLSession(configuration: config)
    }

    var visibleRequests: [Request] { requests }

    // MARK: - 連線

    func attach(library: Library, player: KaraokePlayer, playlists: PlaylistStore) {
        guard self.library == nil else { return }
        self.library = library
        self.player = player
        self.playlists = playlists
        if usesMac { startMac() }  // 沒用過 Mac 的手機：不在網路上找
    }

    /// 「連接家裡的 Mac」：開始找 Mac。這次只是打開，配對成功（或連上）才會記住
    func useMac() {
        guard !usesMac else { return }
        usesMac = true
        connection = .searching
        if library != nil { startMac() }
    }

    /// 這個 SongServer 有沒有在區域網路上找 Mac（測試用）
    var isBrowsing: Bool { browser != nil }

    private func startMac() {
        startBrowsing()
        Task {
            await connect()
            ensureListPolling()  // 上次還沒匯入完的播放清單
            await tidyMac()
        }
    }

    /// App 回到前景時：確認 Mac 還連得到
    func refresh() {
        guard library != nil, usesMac else { return }
        startBrowsing()
        Task {
            if let base = baseURL, let info = await ping(base) {
                if await adopt(base, info) {
                    ensureListPolling()
                    await tidyMac()
                }
                return
            }
            baseURL = nil
            await connect()
            ensureListPolling()
            await tidyMac()
        }
    }

    func setManualAddress(_ text: String) {
        manualAddress = text.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(manualAddress, forKey: Self.addressKey)
        baseURL = nil
        connection = .searching
        Task { await connect() }
    }

    /// 依序試：手動位址 → Bonjour 找到的 IP → Bonjour 的「名稱.local」
    @discardableResult
    func connect() async -> Bool {
        if let running = connectTask { return await running.value }
        let task = Task { await self.tryCandidates() }
        connectTask = task
        let ok = await task.value
        connectTask = nil
        return ok
    }

    private func tryCandidates() async -> Bool {
        var candidates: [String] = []
        if !manualAddress.isEmpty { candidates.append(manualAddress) }
        candidates += bonjourCandidates
        var seen = Set<String>()
        for text in candidates where seen.insert(text).inserted {
            guard let url = Self.baseURL(from: text), let info = await ping(url) else { continue }
            return await adopt(url, info)
        }
        baseURL = nil
        if connection != .denied {
            connection = candidates.isEmpty ? .searching : .notFound
        }
        return false
    }

    private struct Ping: Decodable {
        let app: String
        let name: String
        /// 配對編號；舊版 Mac 程式沒有（不用配對）
        let id: String?
        let pairing: Bool?
        /// 這次帶的金鑰是配對過的
        let paired: Bool?
    }

    private func ping(_ base: URL) async -> Ping? {
        var req = URLRequest(url: Self.endpoint(base, "ping"))
        req.timeoutInterval = 3
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let info = try? JSONDecoder().decode(Ping.self, from: data), info.app == "carkaraoke"
        else { return nil }
        return info
    }

    /// 找到 Mac 了：要配對的話，用鑰匙圈裡給這台 Mac 的金鑰；沒有金鑰（或 Mac 換過配對碼）就請使用者輸入配對碼
    private func adopt(_ url: URL, _ first: Ping) async -> Bool {
        var info = first
        serverID = info.id
        if info.pairing == true, info.paired != true, let id = info.id {
            if let key = PairingKeys.key(for: id), key != sessionKey {
                useKey(key)
                info = await ping(url) ?? info
            }
            if info.paired != true {
                if let key = PairingKeys.key(for: id), key == sessionKey {
                    PairingKeys.remove(id)  // Mac 換過配對碼：舊金鑰不能用了
                }
                askForPairing(url, name: info.name)
                return false
            }
        }
        baseURL = url
        pairingBase = nil
        connection = .connected(name: info.name)
        usage.remember()
        pollFailures = 0
        return true
    }

    private func askForPairing(_ url: URL?, name: String) {
        let already = { if case .needsPairing = self.connection { return true } else { return false } }()
        baseURL = nil
        pairingBase = url ?? pairingBase
        connection = .needsPairing(name: name)
        if !already { pairingPrompt += 1 }  // 第一次發現要配對時，自動打開輸入畫面
    }

    private func useKey(_ key: String?) {
        guard key != sessionKey else { return }
        sessionKey = key
        let old = session
        session = Self.makeSession(key: key)
        old.finishTasksAndInvalidate()
    }

    /// Mac 回 401（金鑰不對，例如在 Mac 上換了配對碼）：改成要輸入配對碼。回傳 false＝要配對
    private func checkPaired(_ resp: URLResponse?) -> Bool {
        guard (resp as? HTTPURLResponse)?.statusCode == 401 else { return true }
        if let id = serverID, PairingKeys.key(for: id) == sessionKey { PairingKeys.remove(id) }
        useKey(nil)
        var name = "Mac"
        if case .connected(let n) = connection { name = n }
        askForPairing(baseURL, name: name)
        return false
    }

    /// 輸入配對碼。回傳 nil＝成功，否則是給使用者看的原因
    func pair(code: String) async -> String? {
        if pairingBase == nil, baseURL == nil { await connect() }
        guard let base = pairingBase ?? baseURL else { return notConnectedMessage }
        var req = URLRequest(url: Self.endpoint(base, "pair"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(["code": code, "device": UIDevice.current.name])
        struct Paired: Decodable { let key: String; let id: String; let name: String }
        do {
            let (data, resp) = try await session.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let ok = try? JSONDecoder().decode(Paired.self, from: data) else {
                return (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? "配對失敗"
            }
            PairingKeys.save(ok.key, for: ok.id)
            usage.remember()
            useKey(ok.key)
            serverID = ok.id
            baseURL = base
            pairingBase = nil
            connection = .connected(name: ok.name)
            ensureListPolling()
            Task { await tidyMac() }
            return nil
        } catch {
            return "連不到 Mac：\(error.localizedDescription)"
        }
    }

    private func startBrowsing() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_carkaraoke._tcp", domain: nil), using: .tcp)
        b.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.browserChanged(state) }
        }
        b.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in await self?.found(results) }
        }
        b.start(queue: .main)
        browser = b
        Task {  // 找了幾秒都沒有 → 顯示「找不到 Mac」
            try? await Task.sleep(for: .seconds(6))
            if baseURL == nil, connection == .searching { connection = .notFound }
        }
    }

    private func browserChanged(_ state: NWBrowser.State) {
        switch state {
        case .waiting(let error), .failed(let error):
            if case .dns(let code) = error, code == -65570 {  // kDNSServiceErr_PolicyDenied
                connection = .denied
            }
            if case .failed = state {
                browser?.cancel()
                browser = nil
            }
        case .ready where connection == .denied:
            connection = .searching
        default:
            break
        }
    }

    private func found(_ results: Set<NWBrowser.Result>) async {
        var list: [String] = []
        for result in results {
            var txtHost: String?
            var port = String(Self.defaultPort)
            if case .bonjour(let txt) = result.metadata {
                txtHost = txt["host"]
                if let p = txt["port"] { port = p }
            }
            if let ip = await Self.resolveIPv4(result.endpoint) { list.append(ip) }
            if let txtHost { list.append("\(txtHost):\(port)") }
        }
        bonjourCandidates = list
        if !list.isEmpty, baseURL == nil { await connect() }
    }

    /// 把 Bonjour 服務解析成 IPv4 位址（比 .local 名稱穩定）
    nonisolated private static func resolveIPv4(_ endpoint: NWEndpoint) async -> String? {
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let connection = NWConnection(to: endpoint, using: params)
        let queue = DispatchQueue(label: "carkaraoke.resolve")
        final class Once: @unchecked Sendable { var done = false }  // 只在 queue 上存取
        let once = Once()
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            @Sendable func finish(_ value: String?) {
                guard !once.done else { return }
                once.done = true
                connection.cancel()
                cont.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case .hostPort(let host, let port) = connection.currentPath?.remoteEndpoint {
                        let h = "\(host)".split(separator: "%").first.map(String.init) ?? "\(host)"
                        finish("\(h):\(port.rawValue)")
                    } else {
                        finish(nil)
                    }
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 4) { finish(nil) }
        }
    }

    // MARK: - 加歌

    /// 貼上的文字（YouTube／Spotify 連結，或「分享」複製出來、夾雜文字的內容）
    func submit(_ text: String) {
        guard let link = Self.songLink(in: text) else {
            var bad = Request(link: String(text.prefix(60)))
            bad.stage = .failed("這不是 YouTube 或 Spotify 的歌曲連結。請在 YouTube 或 Spotify 的歌曲按「分享 → 複製連結」再貼上")
            requests.insert(bad, at: 0)
            return
        }
        if requests.contains(where: { $0.link == link && $0.isActive }) { return }
        let req = Request(link: link)
        requests.insert(req, at: 0)
        Task { await send(req.id) }
    }

    func retry(_ id: UUID) {
        guard let req = requests.first(where: { $0.id == id }) else { return }
        if Self.songLink(in: req.link) == nil {
            dismiss(id)
            return
        }
        update(id) {
            $0.jobID = nil
            $0.stage = .sending
        }
        Task { await send(id) }
    }

    func dismiss(_ id: UUID) {
        requests.removeAll { $0.id == id }
    }

    private struct Job: Decodable {
        let id: String
        let status: String
        let title: String?
        let artist: String?
        let inst: String?
        let vocals: String?
        let lyrics: String?
        let error: String?
        let progress: Double?
        let ahead: Int?
        /// 已經傳到手機過、Mac 上的檔案刪掉了
        let delivered: Bool?
    }

    private struct ErrorBody: Decodable { let error: String }

    private func send(_ id: UUID, redo: Bool = false) async {
        if baseURL == nil { await connect() }
        guard let base = baseURL else {
            if case .needsPairing = connection { pairingPrompt += 1 }
            update(id) { $0.stage = .failed(self.notConnectedMessage) }
            return
        }
        guard let link = requests.first(where: { $0.id == id })?.link else { return }
        var req = URLRequest(url: Self.endpoint(base, "jobs"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["url": link, "redo": redo])
        do {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(code) {
                if let list = try? JSONDecoder().decode(ListBody.self, from: data), list.type == "list" {
                    let p = applyList(list, link: link, refetchMissing: true)
                    update(id) {
                        $0.title = p.name
                        $0.stage = .done
                        $0.outcome = "已加入\(p.kindLabel)，共 \(p.items.count) 首"
                    }
                    removeLater(id)
                    ensureListPolling()
                    return
                }
                apply(try JSONDecoder().decode(Job.self, from: data), to: id)
                ensurePolling()
            } else {
                let msg = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? "Mac 回應錯誤（\(code)）"
                _ = checkPaired(resp)
                update(id) { $0.stage = .failed(msg) }
            }
        } catch {
            baseURL = nil
            connection = .notFound
            update(id) { $0.stage = .failed("連不到 Mac：\(error.localizedDescription)") }
        }
    }

    private func apply(_ job: Job, to id: UUID) {
        guard let current = requests.first(where: { $0.id == id }), current.isActive else { return }
        if job.status == "done", job.delivered == true, let inst = job.inst, !has(inst) {
            // 以前傳到手機過、Mac 已經刪掉了，但這支手機上沒有：請 Mac 重做
            if current.redoAsked {
                update(id) { $0.stage = .failed("Mac 上已經沒有這首了，請再貼一次連結") }
            } else {
                update(id) {
                    $0.redoAsked = true
                    $0.jobID = nil
                    $0.stage = .sending
                }
                Task { await send(id, redo: true) }
            }
            return
        }
        update(id) { r in
            r.jobID = job.id
            r.title = job.title ?? r.title
            r.artist = job.artist ?? r.artist
            switch job.status {
            case "queued": r.stage = .queued(ahead: job.ahead ?? 0)
            case "searching": r.stage = .searching
            case "downloading": r.stage = .downloading
            case "separating": r.stage = .separating(job.progress)
            case "done": r.stage = .transferring
            case "failed": r.stage = .failed(job.error ?? "處理失敗")
            default: break
            }
        }
        if job.status == "done", let inst = job.inst {
            let onMac = job.delivered != true  // 不在 Mac 上了＝手機上已經有，不用下載
            Task {
                await receive(id, inst: inst, vocals: onMac ? job.vocals : nil, lyrics: onMac ? job.lyrics : nil,
                              onMac: onMac)
            }
        }
    }

    private func ensurePolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                let ids = self.requests.filter(\.needsPolling).map(\.id)
                if ids.isEmpty { break }
                try? await Task.sleep(for: .seconds(2))
                await self.poll(ids)
            }
            self?.pollTask = nil
        }
    }

    private func poll(_ ids: [UUID]) async {
        if baseURL == nil { await connect() }
        guard let base = baseURL else { return }  // 下一輪再試（例如手機暫時離開 Wi-Fi）
        for id in ids {
            guard let jobID = requests.first(where: { $0.id == id })?.jobID else { continue }
            do {
                let (data, resp) = try await session.data(from: Self.endpoint(base, "jobs/\(jobID)"))
                pollFailures = 0
                guard checkPaired(resp) else { return }
                if (resp as? HTTPURLResponse)?.statusCode == 404 {
                    update(id) { $0.stage = .failed("Mac 的伺服器重新啟動過，請按「重試」") }
                    continue
                }
                apply(try JSONDecoder().decode(Job.self, from: data), to: id)
            } catch {
                pollFailures += 1
                if pollFailures >= 3 {
                    baseURL = nil
                    connection = .notFound
                }
                return
            }
        }
    }

    /// 下載伴唱（＋人聲）檔到歌曲庫，然後播放／排到下一首
    private func receive(_ id: UUID, inst: String, vocals: String?, lyrics: String?, onMac: Bool = true) async {
        if baseURL == nil { await connect() }
        guard let base = baseURL, let library else {
            update(id) { $0.stage = .failed(self.notConnectedMessage) }
            return
        }
        do {
            if let vocals { try await download(vocals, from: base, into: library.folder) }
            if let lyrics { try? await download(lyrics, from: base, into: library.folder) }  // 歌詞失敗不影響唱歌
            try await download(inst, from: base, into: library.folder)  // 伴唱檔最後放進去，歌單才不會出現半套
        } catch {
            update(id) { $0.stage = .failed("傳到手機失敗：\(error.localizedDescription)") }
            return
        }
        if onMac, has(inst, vocals, lyrics) {
            Task { await release([inst]) }  // 手機收好了：Mac 刪掉自己那份
        }
        library.reload()
        player?.refreshSongs(library.songs)
        var outcome = "已加入歌單"
        if let song = library.songs.first(where: { $0.mainURL.lastPathComponent == inst }), let player {
            if player.isPlaying {
                player.playNext(song)
                outcome = "已排到下一首"
            } else {
                let songs = library.songs
                player.play(songs, startAt: songs.firstIndex(of: song) ?? 0)
                outcome = "開始播放"
            }
        }
        update(id) {
            $0.stage = .done
            $0.outcome = outcome
        }
        removeLater(id)
    }

    /// 完成的項目過一會兒自動收起
    private func removeLater(_ id: UUID) {
        Task {
            try? await Task.sleep(for: .seconds(15))
            requests.removeAll { $0.id == id && $0.stage == .done }
        }
    }

    // MARK: - Spotify 播放清單

    private struct ListBody: Decodable {
        struct Track: Decodable {
            let spotifyId: String
            let title: String
            let artist: String?
            let status: String
            let progress: Double?
            let ahead: Int?
            let inst: String?
            let vocals: String?
            let lyrics: String?
            let error: String?
            let delivered: Bool?
        }
        let type: String
        let id: String
        let kind: String
        let listId: String
        let name: String
        let owner: String?
        let tracks: [Track]
    }

    /// Mac 回傳的清單進度 → 手機上的播放清單。refetchMissing：手機上已經刪掉的歌重新下載
    @discardableResult
    private func applyList(_ list: ListBody, link: String, refetchMissing: Bool = false) -> Playlist {
        let old = playlists?.playlist(list.listId)
        var p = old ?? Playlist(id: list.listId, kind: list.kind, name: list.name, owner: list.owner, link: link,
                                serverID: nil, items: [], created: .now)
        let previous = Dictionary((old?.items ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Mac 已經接手重做的歌：之後如果又遇到「Mac 上刪掉了、手機上沒有」，可以再請 Mac 重做
        redoAsked.subtract(list.tracks.filter { $0.status != "done" }.map(\.spotifyId))
        let onPhone = Set(library?.songs.map(\.stableKey) ?? [])
        p.kind = list.kind
        p.name = list.name
        p.owner = list.owner
        p.link = link
        p.serverID = list.id
        p.items = list.tracks.map { t in
            var item = previous[t.spotifyId] ?? Playlist.Item(id: t.spotifyId, title: t.title, artist: t.artist)
            item.title = t.title
            item.artist = t.artist
            item.status = t.status
            item.error = t.error
            item.progress = t.progress
            item.ahead = t.ahead
            item.inst = t.inst
            item.vocals = t.vocals
            item.lyrics = t.lyrics
            item.delivered = t.delivered
            if refetchMissing, let stem = item.stem, !onPhone.contains(stem) { item.stem = nil }
            if item.stem == nil, t.status == "done", let inst = t.inst, onPhone.contains(Self.stem(of: inst)) {
                item.stem = Self.stem(of: inst)  // 手機上本來就有這首
            }
            return item
        }
        // 只有進度數字變了就不用寫檔
        let key = { (i: Playlist.Item) in [i.id, i.status, i.stem ?? "", i.inst ?? "", i.error ?? "", i.delivered == true ? "d" : ""] }
        let changed = old.map { o in
            o.items.map(key) != p.items.map(key) || o.serverID != p.serverID || o.name != p.name
        } ?? true
        playlists?.upsert(p, save: changed)
        return p
    }

    nonisolated private static func stem(of inst: String) -> String {
        inst.hasSuffix(".伴唱.m4a") ? String(inst.dropLast(".伴唱.m4a".count)) : (inst as NSString).deletingPathExtension
    }

    /// 有播放清單還在匯入時，每 3 秒問一次 Mac 進度、把做好的歌傳到手機
    private func ensureListPolling() {
        guard listTask == nil, playlists?.playlists.contains(where: \.isImporting) == true else { return }
        listTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                let active = (self.playlists?.playlists ?? []).filter(\.isImporting).map(\.id)
                if active.isEmpty { break }
                if self.baseURL == nil { await self.connect() }
                guard let base = self.baseURL else {
                    try? await Task.sleep(for: .seconds(30))  // 連不到 Mac（例如在車上）：慢慢再試，省電
                    continue
                }
                for id in active { await self.syncList(id, base: base) }
                try? await Task.sleep(for: .seconds(3))
            }
            self?.listTask = nil
        }
    }

    private func syncList(_ id: String, base: URL) async {
        guard let p = playlists?.playlist(id) else { return }
        if p.items.contains(where: \.isWorking) {
            var gone = p.serverID == nil
            if let sid = p.serverID {
                do {
                    let (data, resp) = try await session.data(from: Self.endpoint(base, "lists/\(sid)"))
                    guard checkPaired(resp) else { return }
                    if (resp as? HTTPURLResponse)?.statusCode == 404 {
                        gone = true
                    } else if let list = try? JSONDecoder().decode(ListBody.self, from: data) {
                        applyList(list, link: p.link)
                    }
                } catch {
                    return  // 下一輪再試
                }
            }
            if gone {  // Mac 的伺服器重新啟動過：重新匯入（做好的歌不會重做）
                await submitList(id, base: base, refetchMissing: false)
            }
        }
        await downloadReady(id, base: base)
    }

    /// 把清單的連結再交給 Mac 一次。redo：Mac 上已經刪掉、手機上也沒有的歌（Spotify 歌曲 ID），請 Mac 重做
    private func submitList(_ id: String, base: URL, refetchMissing: Bool, redo: [String] = []) async {
        guard let p = playlists?.playlist(id) else { return }
        var req = URLRequest(url: Self.endpoint(base, "jobs"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["url": p.link, "redo": redo])
        req.timeoutInterval = 20
        guard let (data, resp) = try? await session.data(for: req), checkPaired(resp) else { return }
        if let list = try? JSONDecoder().decode(ListBody.self, from: data), list.type == "list" {
            applyList(list, link: p.link, refetchMissing: refetchMissing)
        } else if (resp as? HTTPURLResponse)?.statusCode == 400 {
            let msg = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? "Mac 無法匯入"
            playlists?.update(id) { p in
                for i in p.items.indices where p.items[i].isWorking {
                    p.items[i].status = "failed"
                    p.items[i].error = msg
                }
            }
        }
    }

    /// Mac 做好的歌傳到手機（照清單順序），收好的請 Mac 刪掉
    private func downloadReady(_ id: String, base: URL) async {
        guard let library else { return }
        var redo: [String] = []
        var received: [String] = []
        while let item = playlists?.playlist(id)?.items.first(where: { $0.needsDownload && !redo.contains($0.id) }),
              let inst = item.inst {
            if item.delivered == true {  // 以前傳過、Mac 已經刪掉了，但手機上沒有：請 Mac 重做
                if redoAsked.contains(item.id) {
                    setFailed(id, item: item.id, "Mac 上已經沒有這首了，請按右上角「⋯ → 繼續匯入」")
                } else {
                    redo.append(item.id)
                }
                continue
            }
            do {
                if let vocals = item.vocals { try await download(vocals, from: base, into: library.folder) }
                if let lyrics = item.lyrics { try? await download(lyrics, from: base, into: library.folder) }
                try await download(inst, from: base, into: library.folder)
                library.reload()
                let stem = Self.stem(of: inst)
                playlists?.update(id) { p in
                    if let i = p.items.firstIndex(where: { $0.id == item.id }) { p.items[i].stem = stem }
                }
                if let song = library.songs.first(where: { $0.stableKey == stem }) {
                    player?.appendToQueue(song, from: id)  // 正在唱這個清單：接到最後面
                }
            } catch {
                if (error as? URLError)?.code != .userAuthenticationRequired {  // 要重新配對：配對好再接著傳
                    setFailed(id, item: item.id, "傳到手機失敗：\(error.localizedDescription)")
                }
                break
            }
        }
        // 手機上已經有、Mac 上還留著的（剛下載的、或本來就有的）：請 Mac 刪掉
        for item in playlists?.playlist(id)?.items ?? [] where item.status == "done" && item.stem != nil
            && item.delivered != true {
            if let inst = item.inst, has(inst, item.vocals, item.lyrics) { received.append(inst) }
        }
        if !received.isEmpty {
            playlists?.update(id) { p in
                for i in p.items.indices where p.items[i].inst.map(received.contains) == true { p.items[i].delivered = true }
            }
            await release(received)
        }
        if !redo.isEmpty {
            redoAsked.formUnion(redo)
            playlists?.update(id) { p in  // 先顯示「排隊中」，Mac 回應後更新
                for i in p.items.indices where redo.contains(p.items[i].id) { p.items[i].status = "queued" }
            }
            await submitList(id, base: base, refetchMissing: false, redo: redo)
        }
        player?.refreshSongs(library.songs)
    }

    private func setFailed(_ id: String, item: String, _ message: String) {
        playlists?.update(id) { p in
            if let i = p.items.firstIndex(where: { $0.id == item }) {
                p.items[i].status = "failed"
                p.items[i].error = message
            }
        }
    }

    /// 停止匯入：Mac 上還在排隊的歌不做了（已經做好的留著）
    func cancelImport(_ id: String) {
        guard let p = playlists?.playlist(id) else { return }
        playlists?.update(id) { p in  // 先在手機上停掉（連不到 Mac 也一樣）
            for i in p.items.indices where p.items[i].status == "queued" { p.items[i].status = "canceled" }
        }
        Task {
            if let list = await sendCancel(p.serverID), playlists?.playlist(id) != nil {
                applyList(list, link: p.link)
            }
        }
    }

    private func sendCancel(_ serverID: String?) async -> ListBody? {
        guard let serverID else { return nil }
        if baseURL == nil { await connect() }
        guard let base = baseURL else { return nil }
        var req = URLRequest(url: Self.endpoint(base, "lists/\(serverID)/cancel"))
        req.httpMethod = "POST"
        guard let (data, _) = try? await session.data(for: req) else { return nil }
        return try? JSONDecoder().decode(ListBody.self, from: data)
    }

    /// 繼續匯入：沒做好、停掉的、手機上刪掉的歌再交給 Mac
    func resumeImport(_ id: String) {
        redoAsked.subtract(playlists?.playlist(id)?.items.map(\.id) ?? [])
        Task {
            if baseURL == nil { await connect() }
            guard let base = baseURL else { return }  // 畫面上會顯示「找不到 Mac」
            await submitList(id, base: base, refetchMissing: true)
            ensureListPolling()
        }
    }

    /// 刪除手機上的播放清單（歌曲本身留著）；還在匯入的話也請 Mac 停下來
    func deletePlaylist(_ id: String) {
        guard let p = playlists?.playlist(id) else { return }
        playlists?.remove(id)
        if p.items.contains(where: \.isWorking) {
            Task { _ = await sendCancel(p.serverID) }
        }
    }

    /// replace：手機上已經有同名檔案時也重新下載（歌詞更新）
    private func download(_ name: String, from base: URL, into folder: URL, replace: Bool = false) async throws {
        guard !name.contains("/"), !name.hasPrefix("."), name.hasSuffix(".m4a") || name.hasSuffix(".lrc")
        else { throw URLError(.badURL) }
        let dest = folder.appendingPathComponent(name)
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path), !replace { return }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#;%")
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: allowed) else { throw URLError(.badURL) }
        var req = URLRequest(url: Self.endpoint(base, "files/" + encoded))
        req.timeoutInterval = 60
        let (tmp, resp) = try await session.download(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            try? fm.removeItem(at: tmp)
            throw checkPaired(resp) ? URLError(.badServerResponse) : URLError(.userAuthenticationRequired)
        }
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: tmp, to: dest)
    }

    // MARK: - 同步 Mac 上所有歌

    private struct RemoteSong: Decodable {
        let title: String
        let inst: String
        let vocals: String?
        let lyrics: String?
        /// Mac 上歌詞檔的大小（舊版 Mac 程式沒有這個欄位）
        let lyricsSize: Int?
    }

    func syncAll() async {
        guard !isSyncing, let library else { return }
        isSyncing = true
        defer { isSyncing = false }
        if baseURL == nil { await connect() }
        guard let base = baseURL else {
            syncStatus = notConnectedMessage
            return
        }
        syncStatus = "讀取 Mac 上的歌單…"
        do {
            let (data, resp) = try await session.data(from: Self.endpoint(base, "songs"))
            guard checkPaired(resp) else {
                syncStatus = notConnectedMessage
                return
            }
            let remote = try JSONDecoder().decode([RemoteSong].self, from: data)
            let missing = remote.filter { !has($0.inst) }
            for (n, song) in missing.enumerated() {
                syncStatus = "同步中 \(n + 1)/\(missing.count)：\(song.title)"
                if let vocals = song.vocals { try await download(vocals, from: base, into: library.folder) }
                if let lyrics = song.lyrics { try? await download(lyrics, from: base, into: library.folder) }
                try await download(song.inst, from: base, into: library.folder)
                library.reload()
                if has(song.inst, song.vocals, song.lyrics) {
                    await release([song.inst])  // 一首一首通知：中途斷線的話，傳好的那些 Mac 也已經刪掉了
                }
            }
            syncStatus = "整理 Mac 上的檔案…"
            let fetched = Set(missing.map(\.inst))
            let (lyricsAdded, _) = await settle(remote.filter { !fetched.contains($0.inst) }, base: base, library: library)
            library.reload()
            player?.refreshSongs(library.songs)
            var parts: [String] = []
            if !missing.isEmpty { parts.append("同步 \(missing.count) 首歌") }
            if lyricsAdded > 0 { parts.append("更新 \(lyricsAdded) 首歌詞") }
            syncStatus = parts.isEmpty ? "Mac 上的歌都已經在手機上了" : "已從 Mac " + parts.joined(separator: "、") + "（Mac 上的檔案已刪掉）"
        } catch {
            syncStatus = "同步失敗：\(error.localizedDescription)"
        }
    }

    /// 手機上已經有、Mac 上還留著的歌（例如舊版 App 傳的，或上次通知 Mac 時斷線）：
    /// 先補上 Mac 後來才找到（或更新了）的歌詞，再請 Mac 刪掉。回傳（更新幾首歌詞，Mac 刪了幾首）
    @discardableResult
    private func settle(_ remote: [RemoteSong], base: URL, library: Library) async -> (Int, Int) {
        var lyricsAdded = 0
        var done: [String] = []
        for song in remote where has(song.inst) {
            if let lyrics = song.lyrics, song.lyricsSize.map({ $0 != fileSize(lyrics) }) ?? !has(lyrics) {
                guard (try? await download(lyrics, from: base, into: library.folder, replace: true)) != nil else { continue }
                lyricsAdded += 1
            }
            if let vocals = song.vocals, !has(vocals) {
                try? await download(vocals, from: base, into: library.folder)
            }
            if has(song.inst, song.vocals, song.lyrics) { done.append(song.inst) }
        }
        if lyricsAdded > 0 {
            library.reload()
            player?.refreshSongs(library.songs)
        }
        await release(done)
        return (lyricsAdded, done.count)
    }

    /// 連上 Mac 時順便整理：手機上已經有的歌，請 Mac 刪掉自己那份
    private func tidyMac() async {
        guard !isTidying, !isSyncing, let library, let base = baseURL else { return }
        isTidying = true
        defer { isTidying = false }
        guard let (data, resp) = try? await session.data(from: Self.endpoint(base, "songs")), checkPaired(resp),
              let remote = try? JSONDecoder().decode([RemoteSong].self, from: data) else { return }
        await settle(remote, base: base, library: library)
    }

    /// 告訴 Mac 這幾首手機已經收好了：Mac 刪掉自己那份（只留一筆紀錄），不佔 Mac 的硬碟
    private func release(_ names: [String]) async {
        guard !names.isEmpty, let base = baseURL else { return }
        var req = URLRequest(url: Self.endpoint(base, "received"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(["songs": names])
        _ = try? await session.data(for: req)  // 舊版 Mac 程式沒有這個功能：不影響
    }

    /// 手機的歌曲資料夾裡有這些檔案（nil 不算）
    private func has(_ names: String?...) -> Bool {
        guard let folder = library?.folder else { return false }
        return names.allSatisfy { name in
            name.map { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) } ?? true
        }
    }

    private func fileSize(_ name: String) -> Int? {
        guard let folder = library?.folder else { return nil }
        return (try? folder.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }

    // MARK: - 工具

    var notConnectedMessage: String {
        if case .needsPairing = connection {
            return "要先輸入 Mac 的配對碼：點右上角「＋」輸入。配對碼在 Mac 上雙擊 CarKaraoke 資料夾裡的「配對碼.command」就會看到"
        }
        return connection == .denied
            ? "沒有「區域網路」權限：請到 iPhone 設定 → 隱私權與安全性 → 區域網路，打開「車上K歌」"
            : "找不到 Mac：請確認 Mac 開著（沒有睡眠），而且手機和 Mac 連同一個 Wi-Fi"
    }

    private func update(_ id: UUID, _ change: (inout Request) -> Void) {
        guard let i = requests.firstIndex(where: { $0.id == id }) else { return }
        change(&requests[i])
    }

    nonisolated static func endpoint(_ base: URL, _ path: String) -> URL {
        URL(string: base.absoluteString + "/" + path) ?? base
    }

    /// "192.168.1.20"、"192.168.1.20:8765"、"mac.local"、"http://100.1.2.3:8765" → http://主機:埠
    nonisolated static func baseURL(from text: String) -> URL? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "http://" + s }
        guard var c = URLComponents(string: s), let host = c.host, !host.isEmpty else { return nil }
        if c.port == nil { c.port = defaultPort }
        c.path = ""
        c.query = nil
        c.fragment = nil
        return c.url
    }

    /// 從文字中找出 YouTube 或 Spotify 連結（詳細檢查交給 Mac）
    nonisolated static func songLink(in text: String) -> String? {
        youtubeLink(in: text) ?? spotifyLink(in: text)
    }

    /// 失敗後按「重試」有沒有用：Spotify 的歌手頁面、Podcast 連結重試也一樣不行
    nonisolated static func canRetry(_ link: String) -> Bool {
        if youtubeLink(in: link) != nil { return true }
        guard let s = spotifyLink(in: link)?.lowercased() else { return false }
        return !["/artist/", "/episode/", "/show/", "/user/"].contains { s.contains($0) }
    }

    nonisolated static func youtubeLink(in text: String) -> String? {
        firstLink(in: text, hosts: #"(youtube\.com|youtu\.be)"#)
    }

    /// open.spotify.com/track/…（或 playlist、album）、spotify.link/…（短網址）、spotify:track:…
    nonisolated static func spotifyLink(in text: String) -> String? {
        if let r = text.range(of: #"spotify:(track|playlist|album):[A-Za-z0-9]{22}"#, options: .regularExpression) {
            return String(text[r])
        }
        return firstLink(in: text, hosts: #"(open\.spotify\.com|spotify\.link|spotify\.app\.link)"#)
    }

    nonisolated private static func firstLink(in text: String, hosts: String) -> String? {
        let pattern = #"(https?://)?([a-z0-9-]+\.)*"# + hosts + #"/[^\s<>"'）」】]+"#
        guard let r = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let link = String(text[r])
        return link.lowercased().hasPrefix("http") ? link : "https://" + link
    }
}

/// 這支手機用不用家裡的 Mac：配對過（鑰匙圈裡有金鑰）或連上過 Mac，就算用過。
struct MacUsage {
    nonisolated static let rememberedKey = "usesMac"
    var defaults: UserDefaults = .standard
    var hasPairingKey: () -> Bool = PairingKeys.hasAny

    var wasUsed: Bool { defaults.bool(forKey: Self.rememberedKey) || hasPairingKey() }

    /// 記住「這支手機用 Mac」：之後一打開 App 就顯示 Mac 的功能
    func remember() { defaults.set(true, forKey: Self.rememberedKey) }
}

/// 配對後 Mac 給的金鑰：存在 iPhone 的鑰匙圈（Keychain），每台 Mac 一把（用 Mac 的配對編號區分）
enum PairingKeys {
    private static let service = "carkaraoke.pairing"

    /// 鑰匙圈裡有沒有任何一台 Mac 的金鑰。手機開機後還沒解鎖過（讀不到內容）時也算有
    static func hasAny() -> Bool {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        let status = SecItemCopyMatching(q as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    private static func query(_ server: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: server]
    }

    static func key(for server: String) -> String? {
        var q = query(server)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ key: String, for server: String) {
        remove(server)
        var q = query(server)
        q[kSecValueData as String] = Data(key.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly  // 背景播歌時也讀得到；不會跟著備份到別支手機
        SecItemAdd(q as CFDictionary, nil)
    }

    static func remove(_ server: String) {
        SecItemDelete(query(server) as CFDictionary)
    }
}
