import Foundation

/// 一行歌詞（可選逐字時間）。words 有值時，end 是這一行唱完的時間。
struct LRCLine: Sendable, Equatable {
    var time: Double
    var text: String
    var words: [(time: Double, text: String)]? = nil
    var end: Double? = nil

    static func == (a: LRCLine, b: LRCLine) -> Bool {
        a.time == b.time && a.text == b.text && a.end == b.end
            && (a.words?.map(\.time) ?? []) == (b.words?.map(\.time) ?? [])
            && (a.words?.map(\.text) ?? []) == (b.words?.map(\.text) ?? [])
    }
}

/// 找時間同步歌詞並對齊人聲：Mac 轉換工具 lyrics.py 的 Swift 版。
/// 做法：歌詞每一行開始的時間應該剛好是人聲「開始唱」的時間；試前後 60 秒的位移，挑命中最多行的。
struct LyricsFinder: Sendable {
    static let fps = 20.0
    static let maxShift = 60.0

    var source: any LyricsSource

    struct Found: Sendable, Equatable {
        var lines: [LRCLine]
        var note: String
    }

    /// voiced：每 50 ms 有沒有在唱（MelodyPitch.voiced）；nil 時只接受長度幾乎一樣的版本。
    /// 找不到可信的歌詞、或網路不通，都回傳 nil（照樣可以唱）。
    func find(title: String, artist: String?, duration: Double, voiced: [Bool]?) async -> Found? {
        let candidates = await search(title: title, artist: artist)
        guard !candidates.isEmpty else { return nil }
        let (tradName, simpName) = Self.script(title + (artist ?? ""))
        let wantTrad = tradName >= simpName
        var best: (score: Double, item: LyricsCandidate, lines: [(Double, String)], shift: Double, hit: Double, diff: Double)?
        for item in candidates.prefix(8) {
            let synced = item.syncedLyrics ?? ""
            let lines = Self.parseLRC(synced)
            let sung = lines.filter { !$0.1.isEmpty }.map(\.0)
            guard sung.count >= 4 else { continue }
            let lengthDiff = abs((item.duration ?? duration) - duration)
            let (shift, hit) = Self.chooseShift(lines, voiced: voiced, lengthDiff: lengthDiff)
            let coverage = min(1, (sung.last! - sung.first!) / max(duration * 0.6, 1))
            let (trad, simp) = Self.script(synced)
            let scriptOK = (trad >= simp) == wantTrad || trad == simp
            let score = 2 * hit + 2 * coverage - min(lengthDiff, 60) / 30 + (scriptOK ? 0.5 : 0)
            if best == nil || score > best!.score {
                best = (score, item, lines, shift, hit, lengthDiff)
            }
        }
        guard let best else { return nil }
        if best.diff > 3 && best.hit < 0.5 { return nil }  // 版本長度不同、又對不準：寧可不顯示
        var note = String(format: "lrclib#%@ 位移 %+.2fs 命中 %.0f%%", best.item.id.map(String.init) ?? "None",
                          best.shift, best.hit * 100)
        var lines = best.lines.compactMap { t, s -> LRCLine? in
            let shifted = t + best.shift
            return shifted >= 0 && shifted <= duration + 1 ? LRCLine(time: SignalMath.round2(shifted), text: s) : nil
        }
        let (trad, simp) = Self.script(lines.map(\.text).joined())
        if wantTrad && simp > trad {
            lines = lines.map { LRCLine(time: $0.time, text: Self.toTraditional($0.text)) }
            note += " 簡轉繁"
        }
        return Found(lines: lines, note: note)
    }

    // MARK: 查詢

    /// 找有時間軸的歌詞候選（內容相同的只留一份）。查詢失敗當成沒找到。
    func search(title: String, artist: String?) async -> [LyricsCandidate] {
        let (titles, artists) = Self.variants(title: title, artist: artist)
        var queries: [LyricsQuery] = titles.flatMap { t in artists.map { LyricsQuery.track(name: t, artist: $0) } }
        queries.append(.text("\(titles.last!) \(artists.last ?? "")".trimmingCharacters(in: .whitespaces)))
        var seen = Set<String>()
        var found: [LyricsCandidate] = []
        for query in queries.prefix(7) {
            let items = (try? await source.search(query)) ?? []
            for item in items {
                let synced = (item.syncedLyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !synced.isEmpty, !item.instrumental, !seen.contains(synced) else { continue }
                seen.insert(synced)
                found.append(item)
            }
            if !found.isEmpty { break }
        }
        return found
    }

    private static let brackets = try! NSRegularExpression(pattern: "\\s*[(\\[（【「《][^)\\]）】」》]*[)\\]）】」》]\\s*")
    private static let dash = try! NSRegularExpression(pattern: "\\s+[-–—]\\s+")
    private static let artistSplit = try! NSRegularExpression(
        pattern: "\\s*(?:,|&|/|、|＆|\\sx\\s|×|feat\\.?\\s|ft\\.?\\s)\\s*", options: [.caseInsensitive])
    private static let cjk = try! NSRegularExpression(pattern: "[㐀-鿿豈-﫿]+")

    /// 歌名、歌手的幾種寫法：「Superhero (feat. X)」→「Superhero」、「王傑 Dave Wong」→「王傑」「Dave Wong」
    static func variants(title: String, artist: String?) -> ([String], [String]) {
        var titles = [title]
        let bare = replace(brackets, in: title, with: " ").trimmingCharacters(in: .whitespaces)
        if !bare.isEmpty && bare != title { titles.append(bare) }
        let dashPart = split(dash, bare.isEmpty ? title : bare).first?.trimmingCharacters(in: .whitespaces) ?? ""
        if !dashPart.isEmpty && !titles.contains(dashPart) { titles.append(dashPart) }
        var artists: [String] = []
        if let artist, !artist.isEmpty {
            artists.append(artist)
            let primary = split(artistSplit, artist).first?.trimmingCharacters(in: .whitespaces) ?? ""
            let cjkPart = matches(cjk, in: primary).joined()
            let latin = replace(cjk, in: primary, with: " ").trimmingCharacters(in: .whitespaces)
            for a in [primary, cjkPart, latin] where !a.isEmpty && !artists.contains(a) { artists.append(a) }
        }
        return (titles, artists)
    }

    private static func replace(_ re: NSRegularExpression, in s: String, with r: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: r)
    }

    private static func matches(_ re: NSRegularExpression, in s: String) -> [String] {
        re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range, in: s).map { String(s[$0]) } }
    }

    private static func split(_ re: NSRegularExpression, _ s: String) -> [String] {
        var parts: [String] = []
        var last = s.startIndex
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let r = Range(m.range, in: s) else { continue }
            parts.append(String(s[last..<r.lowerBound]))
            last = r.upperBound
        }
        parts.append(String(s[last...]))
        return parts
    }

    // MARK: LRC

    private static let stampRE = try! NSRegularExpression(pattern: "^\\[(\\d{1,3}):(\\d{1,2}(?:[.:]\\d{1,3})?)\\]")
    private static let wordStampRE = try! NSRegularExpression(pattern: "<\\d{1,3}:\\d{1,2}(?:[.:]\\d{1,3})?>")
    private static let offsetRE = try! NSRegularExpression(pattern: "^\\[offset:\\s*([+-]?\\d+)\\s*\\]$", options: [.caseInsensitive])

    /// LRC 文字 → [(秒, 這一行歌詞)]，依時間排序。空字串代表間奏。
    static func parseLRC(_ text: String) -> [(Double, String)] {
        var lines: [(Double, String)] = []
        var offset = 0.0
        for rawLine in text.components(separatedBy: .newlines) {
            let raw = rawLine.trimmingCharacters(in: .whitespaces)
            let ns = raw as NSString
            if let m = offsetRE.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) {
                offset = (Double(ns.substring(with: m.range(at: 1))) ?? 0) / 1000
                continue
            }
            var stamps: [Double] = []
            var pos = 0
            while let m = stampRE.firstMatch(in: ns.substring(from: pos), range: NSRange(location: 0, length: ns.length - pos)) {
                let sub = ns.substring(from: pos) as NSString
                let minutes = Double(sub.substring(with: m.range(at: 1))) ?? 0
                let seconds = Double(sub.substring(with: m.range(at: 2)).replacingOccurrences(of: ":", with: ".")) ?? 0
                stamps.append(minutes * 60 + seconds)
                pos += m.range.length
            }
            guard !stamps.isEmpty else { continue }
            let body = ns.substring(from: pos)
            let clean = wordStampRE.stringByReplacingMatches(in: body, range: NSRange(location: 0, length: (body as NSString).length),
                                                             withTemplate: "").trimmingCharacters(in: .whitespaces)
            for t in stamps { lines.append((t, clean)) }
        }
        return lines.map { (max(0, $0.0 - offset), $0.1) }
            .enumerated().sorted { $0.element.0 != $1.element.0 ? $0.element.0 < $1.element.0 : $0.offset < $1.offset }
            .map(\.element)
    }

    static func stamp(_ t: Double) -> String {
        let cs = Int((max(t, 0) * 100).rounded(.toNearestOrEven))
        return String(format: "%02d:%02d.%02d", cs / 6000, cs / 100 % 60, cs % 100)
    }

    /// 寫成 LRC（有逐字時間的行寫成 Enhanced LRC：[00:12.30]<00:12.30>我<00:12.80>愛<00:14.90>）
    static func lrc(_ lines: [LRCLine], title: String, artist: String?, note: String) -> String {
        var out = ["[ti:\(title)]"] + (artist.map { ["[ar:\($0)]"] } ?? []) + ["[re:車上K歌 \(note)]"]
        for line in lines {
            if let words = line.words, !words.isEmpty, let end = line.end {
                let body = words.map { "<\(stamp($0.time))>\($0.text)" }.joined() + "<\(stamp(end))>"
                out.append("[\(stamp(line.time))]\(body)")
            } else {
                out.append("[\(stamp(line.time))]\(line.text)")
            }
        }
        return out.joined(separator: "\n") + "\n"
    }

    // MARK: 對齊

    /// 人聲「開始唱」的位置：前面至少 0.3 秒沒聲音（和 Mac 版一樣的算法）
    static func onsets(_ voiced: [Bool], gap: Double = 0.3) -> [Bool] {
        let g = Int(gap * fps)
        let v = voiced.map { $0 ? 1.0 : 0.0 }
        let trailing = SignalMath.trailingSum(v, width: g)
        var out = [Bool](repeating: false, count: v.count)
        for i in 0..<v.count {
            let before = i == 0 ? 0 : trailing[i - 1] - v[i - 1]
            out[i] = voiced[i] && before <= 0
        }
        return out
    }

    /// 回傳 (位移秒數陣列, 命中率陣列)
    static func hitCurve(_ lines: [(Double, String)], voiced: [Bool], tolerance: Double = 0.4) -> ([Double], [Double]) {
        let starts = lines.filter { !$0.1.isEmpty }.map(\.0)
        let on = onsets(voiced).map { $0 ? 1.0 : 0.0 }
        let near = SignalMath.convolveSame(on, [Double](repeating: 1, count: Int(2 * tolerance * fps) + 1)).map { $0 > 0 }
        let maxS = Int(maxShift * fps)
        let idx = starts.map { Int(SignalMath.roundHalfEven($0 * fps)) }
        var shifts: [Double] = [], rates: [Double] = []
        for s in -maxS...maxS {
            var hits = 0
            for i in idx {
                let p = i + s
                if p >= 0 && p < near.count && near[p] { hits += 1 }
            }
            shifts.append(Double(s) / fps)
            rates.append(Double(hits) / Double(max(starts.count, 1)))
        }
        return (shifts, rates)
    }

    /// 回傳 (位移秒數, 命中率)。長度相同的版本只做 ±3 秒微調；版本不同時才允許大幅位移。
    static func chooseShift(_ lines: [(Double, String)], voiced: [Bool]?, lengthDiff: Double) -> (Double, Double) {
        guard let voiced, !voiced.isEmpty, lines.filter({ !$0.1.isEmpty }).count >= 6 else { return (0, 0) }
        let (sh, rate) = hitCurve(lines, voiced: voiced)
        let zeroIndex = sh.indices.min { abs(sh[$0]) < abs(sh[$1]) }!
        let zero = rate[zeroIndex]
        var li = 0
        var bestLocal = -1.0
        for i in sh.indices {
            let r = abs(sh[i]) <= 3 ? rate[i] : -1
            if r > bestLocal { bestLocal = r; li = i }
        }
        var (shift, hit) = rate[li] >= zero + 0.05 ? (sh[li], rate[li]) : (0.0, zero)
        if lengthDiff > 3 {
            var b = 0
            for i in rate.indices where rate[i] > rate[b] { b = i }
            let runnerUp = rate.indices.filter { abs(sh[$0] - sh[b]) > 2 }.map { rate[$0] }.max() ?? 0
            if abs(sh[b]) > 3 && rate[b] >= 0.6 && rate[b] - zero >= 0.25 && rate[b] - runnerUp >= 0.03 {
                (shift, hit) = (sh[b], rate[b])
            }
        }
        return (shift, hit)
    }

    // MARK: 繁簡

    // 常見的簡體／繁體字（只用來判斷歌詞是哪一種字體）
    private static let simp = Set("爱这说们会时为来过还没对开关门问间听见气电话东车长发乐书声让应该经现实认识梦变边远运进伤忆泪恋怀亲给无")
    private static let trad = Set("愛這說們會時為來過還沒對開關門問間聽見氣電話東車長發樂書聲讓應該經現實認識夢變邊遠運進傷憶淚戀懷親給無")

    static func script(_ text: String) -> (trad: Int, simp: Int) {
        var t = 0, s = 0
        for ch in text {
            if trad.contains(ch) { t += 1 }
            if simp.contains(ch) { s += 1 }
        }
        return (t, s)
    }

    /// 簡體 → 繁體（iOS 內建的轉換，不用連網）
    static func toTraditional(_ text: String) -> String {
        text.applyingTransform(StringTransform(rawValue: "Hans-Hant"), reverse: false) ?? text
    }
}
