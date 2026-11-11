import Foundation

/// 歌詞資料庫的一筆結果
struct LyricsCandidate: Sendable, Equatable {
    var id: Int?
    var duration: Double?
    var syncedLyrics: String?
    var instrumental: Bool = false
}

/// 一次查詢：用「歌名＋歌手」，或一段自由文字
enum LyricsQuery: Sendable, Hashable {
    case track(name: String, artist: String)
    case text(String)
}

/// 歌詞來源。轉換流程只認這個介面：以後換資料庫只要新增一個實作。
///
/// 契約（CarKaraokeTests/LyricsSourceContractTests 對每個實作都會驗證）：
/// - 同一個查詢回傳資料庫原本的候選，不過濾、不改內容
/// - 查不到回傳空陣列；連不上網路、逾時、伺服器錯誤則丟出錯誤（由呼叫端決定要不要當成查不到）
protocol LyricsSource: Sendable {
    func search(_ query: LyricsQuery) async throws -> [LyricsCandidate]
}

/// LRCLIB（https://lrclib.net）：免費、開放的社群歌詞資料庫，不用帳號、不是 AI。
/// 只會送出歌名、歌手。
struct LRCLIBSource: LyricsSource {
    static let endpoint = URL(string: "https://lrclib.net/api/search")!
    static let userAgent = "CarKaraoke/1.0 (personal karaoke app)"

    var session: URLSession = .shared

    func search(_ query: LyricsQuery) async throws -> [LyricsCandidate] {
        var comps = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)!
        switch query {
        case .track(let name, let artist):
            comps.queryItems = [URLQueryItem(name: "track_name", value: name), URLQueryItem(name: "artist_name", value: artist)]
        case .text(let q):
            comps.queryItems = [URLQueryItem(name: "q", value: q)]
        }
        var req = URLRequest(url: comps.url!, timeoutInterval: 12)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list.map { item in
            LyricsCandidate(id: (item["id"] as? NSNumber)?.intValue,
                            duration: (item["duration"] as? NSNumber)?.doubleValue,
                            syncedLyrics: item["syncedLyrics"] as? String,
                            instrumental: (item["instrumental"] as? Bool) ?? false)
        }
    }
}
