import Foundation

/// 一行歌詞
struct LyricLine: Equatable, Sendable {
    let time: TimeInterval
    let text: String
    /// 這行大概唱到第幾秒（手機上 KTV 字幕「跑色」用）
    var singEnd: TimeInterval
    /// 逐字時間（Mac 從人聲軌算出來的）；空的 = 只有整行時間，整行平均跑色
    var words: [LyricWord] = []
}

/// 一行裡的一段字（通常是一個中文字、或一個英文單字）開始唱的時間
struct LyricWord: Equatable, Sendable {
    let time: TimeInterval
    /// 在這一行文字裡的位置（第幾個字元，含頭不含尾）
    let start: Int
    let end: Int
}

/// LRC 解析出來的一行
struct ParsedLyricLine: Sendable {
    var time: TimeInterval
    var text: String
    var words: [LyricWord] = []
    /// 逐字格式最後一個標記 = 唱完的時間
    var end: TimeInterval? = nil
}

/// 時間同步歌詞（LRC 檔，和伴唱檔同名：「歌名 - 歌手.lrc」）
struct Lyrics: Equatable, Sendable {
    private(set) var lines: [LyricLine]

    init(_ parsed: [(TimeInterval, String)]) {
        self.init(lines: parsed.map { ParsedLyricLine(time: $0.0, text: $0.1) })
    }

    init(lines parsed: [ParsedLyricLine]) {
        var lines: [LyricLine] = []
        for (i, p) in parsed.enumerated() {
            let next = i + 1 < parsed.count ? parsed[i + 1].time : p.time + 5
            // 沒有原唱音高資料時的估計：唱到下一行前一點點，最多 8 秒
            var end = min(max(next - 0.25, p.time + 0.6), p.time + 8)
            var words = p.words
            if let last = words.last, let wordsEnd = p.end, wordsEnd > last.time {
                end = wordsEnd
            } else if let last = words.last {
                end = max(end, last.time + 0.3)
            }
            if !words.isEmpty, zip(words, words.dropFirst()).contains(where: { $0.time > $1.time }) {
                words = []  // 時間亂掉的逐字標記不用，改回整行跑色
            }
            lines.append(LyricLine(time: p.time, text: p.text, singEnd: end, words: words))
        }
        self.lines = lines
    }

    static func load(_ url: URL) -> Lyrics? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16)
        else { return nil }
        let parsed = parseLines(text)
        guard parsed.contains(where: { !$0.text.isEmpty }) else { return nil }
        return Lyrics(lines: parsed)
    }

    /// LRC 文字 → [(秒, 歌詞)]，依時間排序。空字串代表間奏。
    static func parse(_ text: String) -> [(TimeInterval, String)] {
        parseLines(text).map { ($0.time, $0.text) }
    }

    /// LRC 文字 → 每一行（含逐字時間），依時間排序
    static func parseLines(_ text: String) -> [ParsedLyricLine] {
        var out: [ParsedLyricLine] = []
        var offset: TimeInterval = 0
        for raw in text.split(whereSeparator: \.isNewline) {
            var rest = Substring(raw.trimmingCharacters(in: .whitespaces))
            var stamps: [TimeInterval] = []
            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                let inner = rest[rest.index(after: rest.startIndex)..<close]
                if let t = timestamp(inner) {
                    stamps.append(t)
                    rest = rest[rest.index(after: close)...]
                } else {
                    if inner.lowercased().hasPrefix("offset:"),
                       let ms = Double(inner.dropFirst(7).trimmingCharacters(in: .whitespaces)) {
                        offset = ms / 1000  // LRC 規格：正數 = 歌詞提早出現
                    }
                    break  // [ti:]、[ar:] 之類的標籤
                }
            }
            guard !stamps.isEmpty else { continue }
            let (body, marks, end) = wordTimestamps(rest)
            for t in stamps {
                var line = ParsedLyricLine(time: max(0, t - offset), text: body)
                if stamps.count == 1, !marks.isEmpty {  // 同一行歌詞出現好幾次時，逐字時間只對其中一次，不用
                    line.words = marks.map { LyricWord(time: max(0, $0.time - offset), start: $0.start, end: $0.end) }
                    line.end = end.map { max(0, $0 - offset) }
                }
                out.append(line)
            }
        }
        return out.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element)
    }

    /// 「mm:ss.xx」「mm:ss:xx」「mm:ss」→ 秒
    private static func timestamp(_ s: Substring) -> TimeInterval? {
        let parts = s.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let minutes = Int(parts[0]), minutes >= 0 else { return nil }
        let secondsText = parts[1].replacingOccurrences(of: ":", with: ".")
        guard let seconds = Double(secondsText), seconds >= 0, seconds < 60 else { return nil }
        return Double(minutes) * 60 + seconds
    }

    /// 逐字格式「<00:12.30>我<00:12.80>愛<00:13.40>你<00:14.90>」→
    /// (歌詞「我愛你」、每段字的開始時間和位置、最後一個標記 = 唱完的時間)
    private static func wordTimestamps(_ s: Substring) -> (String, [LyricWord], TimeInterval?) {
        var text = ""
        var count = 0  // 以「字元」（Character）計
        var stamps: [(time: TimeInterval, at: Int)] = []
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "<", let gt = s[i...].firstIndex(of: ">"),
               let t = timestamp(s[s.index(after: i)..<gt]) {
                stamps.append((t, count))
                i = s.index(after: gt)
            } else {
                text.append(s[i])
                count += 1
                i = s.index(after: i)
            }
        }
        var marks: [LyricWord] = []
        var end: TimeInterval?
        for (k, stamp) in stamps.enumerated() {
            let until = k + 1 < stamps.count ? stamps[k + 1].at : count
            if until > stamp.at {
                marks.append(LyricWord(time: stamp.time, start: stamp.at, end: until))
            } else if k == stamps.count - 1, !marks.isEmpty {
                end = stamp.time  // 最後一個標記後面沒有字 = 唱完的時間
            }
        }
        // 前後空白拿掉，位置跟著移
        let isSpace = { (c: Character) in c.unicodeScalars.allSatisfy { CharacterSet.whitespaces.contains($0) } }
        let lead = text.prefix(while: isSpace).count
        let trimmed = String(text.dropFirst(lead).reversed().drop(while: isSpace).reversed())
        let n = trimmed.count
        marks = marks.compactMap {
            let a = min(max($0.start - lead, 0), n), b = min(max($0.end - lead, 0), n)
            return b > a ? LyricWord(time: $0.time, start: a, end: b) : nil
        }
        if let first = marks.first, first.start > 0 {  // 第一個標記前面的字併進第一段
            marks[0] = LyricWord(time: first.time, start: 0, end: first.end)
        }
        return (trimmed, marks, marks.isEmpty ? nil : end)
    }

    /// 第 t 秒正在唱的那一行（nil = 還沒到第一行）
    func index(at t: TimeInterval) -> Int? {
        var lo = 0, hi = lines.count  // 找最後一個 time <= t
        while lo < hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo == 0 ? nil : lo - 1
    }

    /// i 之後下一行有字的歌詞
    func nextSung(after i: Int?) -> Int? {
        var j = (i ?? -1) + 1
        while j < lines.count {
            if !lines[j].text.isEmpty { return j }
            j += 1
        }
        return nil
    }

    /// 點歌詞跳過去時，從歌詞時間的第幾秒開始放：這一行開始前留最多 1 秒當提示，
    /// 但不會退到上一行還在唱的地方（minLead = 字幕本來就提早出現的量，跳過去時字幕立刻就是這一行）
    func jumpStart(to i: Int, minLead: TimeInterval) -> TimeInterval {
        let start = lines[i].time
        let previousEnd = lines[..<i].last(where: { !$0.text.isEmpty })?.singEnd ?? 0
        let preroll = min(1.0, max(minLead * 0.9, start - previousEnd))
        return max(start - preroll, 0)
    }

    /// 用原唱音高資料（每秒 fps 點，0 = 沒唱）算出每行真正唱完的時間，讓跑色速度貼近歌聲
    mutating func refineEnds(reference: [UInt8], fps: Double) {
        guard fps > 0, !reference.isEmpty else { return }
        for i in lines.indices where !lines[i].text.isEmpty && lines[i].words.isEmpty {  // 有逐字時間的行已經知道唱到哪
            let start = lines[i].time
            let next = i + 1 < lines.count ? lines[i + 1].time : start + 10
            let a = max(Int(start * fps), 0)
            let b = min(Int(next * fps), reference.count)
            guard a < b, let last = reference[a..<b].lastIndex(where: { $0 != 0 }) else { continue }
            let end = (Double(last) + 1) / fps
            if end > start + 0.4 { lines[i].singEnd = min(end, next) }
        }
    }

    /// 跑色進度 0…1（整行平均）
    func progress(of i: Int, at t: TimeInterval) -> Double {
        let line = lines[i]
        let span = max(line.singEnd - line.time, 0.3)
        return min(max((t - line.time) / span, 0), 1)
    }

    /// 跑色跑到第幾個字（可以有小數：2.5 = 前 2 個字已經變色、第 3 個字變了一半）。
    /// 有逐字時間時每個字照它自己的時間變色（拉長音的字慢慢變）；沒有時整行平均。
    func wipePosition(of i: Int, at t: TimeInterval) -> Double {
        let line = lines[i]
        let n = Double(line.text.count)
        guard let first = line.words.first else { return progress(of: i, at: t) * n }
        if t < first.time { return Double(first.start) }
        let k = line.words.lastIndex { $0.time <= t } ?? 0
        let w = line.words[k]
        let until = k + 1 < line.words.count ? line.words[k + 1].time : line.singEnd
        let f = until > w.time ? min(max((t - w.time) / (until - w.time), 0), 1) : 1
        return Double(w.start) + Double(w.end - w.start) * f
    }
}
