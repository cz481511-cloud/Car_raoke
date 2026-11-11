import Foundation

/// 一首一般音檔 → 和 Mac 轉換工具一樣的一組檔案：
/// 「歌名 - 歌手.伴唱.m4a」（含評分用音高 CKP1、封面）、「歌名 - 歌手.人聲.m4a」、「歌名 - 歌手.lrc」（找得到才有）。
/// 全部在手機上算，不連 Mac；只有查歌詞會連 lrclib.net（只送歌名、歌手）。
struct SongPipeline: Sendable {
    var separator: any VocalSeparating
    var lyrics: LyricsFinder

    enum Step: String, Sendable {
        case reading = "讀取音檔"
        case separating = "去人聲"
        case pitch = "抓原唱音高"
        case lyrics = "找歌詞"
        case saving = "存檔"
    }

    enum Outcome: Sendable, Equatable {
        /// 做好了；base 是新歌的檔名（不含「.伴唱.m4a」）
        case converted(base: String, hasLyrics: Bool)
        /// 歌曲庫裡已經有同一首去過人聲的歌，沒有重做
        case alreadyExists(base: String)
    }

    /// 「歌名 - 歌手」：和 Mac 版 Track.base_name 一樣（歌名已經含歌手時不重複）
    static func baseName(title: String, artist: String?) -> String {
        var name = title
        if let artist, !artist.isEmpty, !title.lowercased().contains(artist.lowercased()) {
            name = "\(title) - \(artist)"
        }
        return safeName(name)
    }

    /// 檔名不能用的字元換成空白（Mac 版 safe_name）
    static func safeName(_ text: String, limit: Int = 90) -> String {
        var t = String(text.unicodeScalars.map { s -> Character in
            "\\/:*?\"<>|".unicodeScalars.contains(s) || s.value < 0x20 ? " " : Character(s)
        })
        t = t.replacingOccurrences(of: Library.instSuffix, with: "").replacingOccurrences(of: Library.vocalSuffix, with: "")
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        t = String(t.prefix(limit)).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return t.isEmpty ? "未命名" : t
    }

    /// source：歌曲庫裡的一般音檔。成功時會刪掉 source（伴唱 + 人聲 = 原曲）；失敗時 source 一定保留。
    func convert(_ source: URL, in folder: URL,
                 progress: @escaping @Sendable (Step, Double) -> Void,
                 checkpoint: @escaping @Sendable () async throws -> Void) async throws -> Outcome {
        let fm = FileManager.default
        progress(.reading, 0)
        try await checkpoint()
        let tags = await SourceTags.read(source)
        let (fileTitle, fileArtist) = Library.splitName(source.deletingPathExtension().lastPathComponent)
        let title = tags.title ?? fileTitle
        let artist = tags.artist ?? fileArtist
        let base = Self.baseName(title: title, artist: artist)
        let instURL = folder.appendingPathComponent(base + Library.instSuffix + ".m4a")
        let vocalURL = folder.appendingPathComponent(base + Library.vocalSuffix + ".m4a")
        let lrcURL = folder.appendingPathComponent(base + "." + Library.lyricsExtension)
        if fm.fileExists(atPath: instURL.path) { return .alreadyExists(base: base) }

        let audio = try AudioDecoder.decode(source)
        guard audio.duration >= 1 else { throw ConversionError.tooShort }
        progress(.reading, 0.05)

        var stems = try await separator.separate(audio, progress: { p in progress(.separating, 0.05 + 0.8 * p) },
                                                 checkpoint: checkpoint)
        // 兩軌一起縮放，避免爆音，也保持 伴唱 + 人聲 = 原曲
        let peak = max(stems.accompaniment.peak, stems.vocals.peak, audio.peak)
        if peak > 0.98 {
            stems.accompaniment = stems.accompaniment.scaled(by: 0.98 / peak)
            stems.vocals = stems.vocals.scaled(by: 0.98 / peak)
        }

        try await checkpoint()
        progress(.pitch, 0.86)
        let mono16k = AudioDecoder.resampleTo16k(stems.vocals.mono)
        let pitch = MelodyPitch.extract(mono16k)

        try await checkpoint()
        progress(.lyrics, 0.9)
        var lrcText: String?
        if let found = await lyrics.find(title: title, artist: artist, duration: audio.duration,
                                         voiced: MelodyPitch.voiced(pitch)) {
            let timed = WordTiming.addWordTimes(found.lines, mono16k: mono16k, pitch: pitch)
            lrcText = LyricsFinder.lrc(timed.lines, title: title, artist: artist,
                                       note: found.note + " 逐字 \(timed.timed)/\(timed.sung) 手機")
        }

        try await checkpoint()
        progress(.saving, 0.95)
        let comment = "手機去人聲：\(source.lastPathComponent)"
        var written: [URL] = []
        do {
            // 先寫人聲和歌詞，最後才寫伴唱檔：伴唱檔一出現，歌曲庫就會把它當成去過人聲的歌
            try await SongFileWriter.write(stems.vocals, to: vocalURL, tags: .init(
                title: title, artist: artist, kind: "人聲", pitchTag: nil, artwork: tags.artwork, comment: comment))
            written.append(vocalURL)
            if let lrcText {
                let tmp = lrcURL.appendingPathExtension("tmp")
                do {
                    try lrcText.write(to: tmp, atomically: true, encoding: .utf8)
                    if fm.fileExists(atPath: lrcURL.path) { try fm.removeItem(at: lrcURL) }
                    try fm.moveItem(at: tmp, to: lrcURL)
                    written.append(lrcURL)
                } catch {
                    try? fm.removeItem(at: tmp)  // 歌詞存不下來不影響唱歌
                }
            }
            try await SongFileWriter.write(stems.accompaniment, to: instURL, tags: .init(
                title: title, artist: artist, kind: "伴唱", pitchTag: MelodyPitch.tag(pitch), artwork: tags.artwork,
                comment: comment))
        } catch {
            for url in written { try? fm.removeItem(at: url) }
            throw error
        }
        if source.standardizedFileURL != instURL.standardizedFileURL {
            try? fm.removeItem(at: source)
        }
        progress(.saving, 1)
        return .converted(base: base, hasLyrics: written.contains(lrcURL))
    }
}
