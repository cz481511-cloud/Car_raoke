import Foundation
import Testing
@testable import CarKaraoke

// 第一層：每個元件自己的輸入輸出

@Suite("元件：訊號處理")
struct SignalComponentTests {
    @Test("numpy 對應：百分位數、卷積、四捨六入五成雙")
    func numpyHelpers() {
        #expect(SignalMath.percentile([1, 2, 3, 4], 50) == 2.5)
        #expect(SignalMath.percentile([5], 95) == 5)
        // np.convolve([1,2,3],[0,1,0.5],'same') == [1, 2.5, 4]
        #expect(SignalMath.convolveSame([1, 2, 3], [0, 1, 0.5]) == [1, 2.5, 4])
        // np.convolve([1,2,3],[1,1],'same') == [1, 3, 5]
        #expect(SignalMath.convolveSame([1, 2, 3], [1, 1]) == [1, 3, 5])
        #expect(SignalMath.roundHalfEven(2.5) == 2 && SignalMath.roundHalfEven(3.5) == 4)
    }

    @Test("頻譜轉換：轉過去再轉回來，還原原本的聲音")
    func stftRoundTrip() {
        let L = 343_980
        let stft = DemucsSTFT(length: L)
        var seg = [Float](repeating: 0, count: 2 * L)
        for i in 0..<L {
            seg[i] = Float(sin(Double(i) * 0.031)) * 0.5
            seg[L + i] = Float(sin(Double(i) * 0.017 + 1)) * 0.3
        }
        var spec = [Float](repeating: 0, count: 4 * 2048 * stft.frames)
        seg.withUnsafeBufferPointer { s in spec.withUnsafeMutableBufferPointer { stft.forward(s.baseAddress!, into: $0.baseAddress!) } }
        var back = [Float](repeating: 0, count: 2 * L)
        spec.withUnsafeBufferPointer { s in back.withUnsafeMutableBufferPointer { stft.inverseAdd(s.baseAddress!, into: $0.baseAddress!) } }
        // 中間完整還原；頭尾各約 0.03 秒會變小聲，這是 Demucs 原本的設計（PyTorch 版同一段訊號也是 35.07 dB）
        #expect(abs(TestAudio.sdr(back, seg) - 35.07) < 0.01)
        let inner = { (x: [Float]) in Array(x[4096..<(L - 4096)]) + Array(x[(L + 4096)..<(2 * L - 4096)]) }
        #expect(TestAudio.sdr(inner(back), inner(seg)) > 60)
    }

    @Test("讀音檔：48 kHz 單聲道也會轉成 44.1 kHz 立體聲")
    func decodeOtherFormats() async throws {
        let folder = try makeTempFolder()
        let url = folder.appendingPathComponent("mono48k.caf")
        let file = try AVAudioFileHelper.writeMono(TestAudio.sine(440, seconds: 2, rate: 48_000), rate: 48_000, to: url)
        _ = file
        let audio = try AudioDecoder.decode(url)
        #expect(abs(audio.duration - 2) < 0.05)
        #expect(audio.left == audio.right)
        #expect(audio.peak > 0.25)
    }

    @Test("讀音檔：不是音訊的檔案丟出「讀不出聲音」")
    func decodeGarbage() throws {
        let folder = try makeTempFolder()
        let url = folder.appendingPathComponent("broken.mp3")
        try Data("not audio".utf8).write(to: url)
        #expect(throws: ConversionError.unreadable) { try AudioDecoder.decode(url) }
    }
}

@Suite("元件：原唱音高")
struct MelodyPitchTests {
    @Test("220 Hz（A3，MIDI 57）→ 每點 (57-24)*4 = 132")
    func sineGivesMidi() {
        let pitch = MelodyPitch.extract(TestAudio.sine(220, seconds: 2))
        // 和 Mac 一樣：1 + (樣本數 - (512 + 229)) / 800
        #expect(pitch.count == 1 + (32_000 - 741) / 800)
        let voiced = pitch.filter { $0 > 0 }
        #expect(voiced.count > 30)
        #expect(voiced.allSatisfy { abs(Int($0) - 132) <= 1 })
    }

    @Test("安靜 → 全部 0（沒有唱）")
    func silence() {
        let pitch = MelodyPitch.extract([Float](repeating: 0, count: 32_000))
        #expect(!pitch.isEmpty && pitch.allSatisfy { $0 == 0 })
    }

    @Test("短於 150 ms 的聲音不算唱")
    func shortBlipRemoved() {
        var x = [Float](repeating: 0, count: 48_000)
        let blip = TestAudio.sine(220, seconds: 0.1)
        x.replaceSubrange(16_000..<(16_000 + blip.count), with: blip)
        #expect(MelodyPitch.extract(x).allSatisfy { $0 == 0 })
    }

    @Test("太短的音檔 → 空的")
    func tooShort() { #expect(MelodyPitch.extract([0.1, 0.2]).isEmpty) }

    @Test("CKP1 標籤格式和 Mac 一樣")
    func tagFormat() {
        #expect(MelodyPitch.tag([0, 132, 255]) == "CKP1:20:" + Data([0, 132, 255]).base64EncodedString())
    }
}

@Suite("元件：歌詞")
struct LyricsComponentTests {
    @Test("歌名、歌手的幾種寫法（和 Mac 版一樣）")
    func variants() {
        let (t1, a1) = LyricsFinder.variants(title: "Superhero (feat. Chris Linton)", artist: "王傑 Dave Wong")
        #expect(t1 == ["Superhero (feat. Chris Linton)", "Superhero"])
        #expect(a1 == ["王傑 Dave Wong", "王傑", "Dave Wong"])
        let (t2, a2) = LyricsFinder.variants(title: "天黑黑 - Remastered", artist: nil)
        #expect(t2 == ["天黑黑 - Remastered", "天黑黑"])
        #expect(a2.isEmpty)
    }

    @Test("讀 LRC：多個時間標記、offset、逐字標記")
    func parse() {
        let text = "[ti:x]\n[offset:+500]\n[00:10.00][00:20.50]副歌\n[00:12.00]<00:12.00>我<00:12.50>愛<00:13.00>\n[00:15.00]"
        let lines = LyricsFinder.parseLRC(text)
        #expect(lines.map(\.0) == [9.5, 11.5, 14.5, 20.0])
        #expect(lines.map(\.1) == ["副歌", "我愛", "", "副歌"])
    }

    @Test("寫出的 LRC，App 原本的歌詞讀取器讀得懂（含逐字時間）")
    func writtenLRCIsReadable() throws {
        let lines = [LRCLine(time: 1.0, text: "我愛你", words: [(1.0, "我"), (1.5, "愛"), (2.0, "你")], end: 2.6),
                     LRCLine(time: 3.0, text: "一起唱")]
        let text = LyricsFinder.lrc(lines, title: "晴天", artist: "周杰倫", note: "test")
        #expect(text.hasPrefix("[ti:晴天]\n[ar:周杰倫]\n[re:車上K歌 test]\n"))
        let folder = try makeTempFolder()
        let url = folder.appendingPathComponent("a.lrc")
        try text.write(to: url, atomically: true, encoding: .utf8)
        let loaded = try #require(Lyrics.load(url))
        #expect(loaded.lines.count == 2)
        #expect(loaded.lines[0].words.map(\.time) == [1.0, 1.5, 2.0])
        #expect(loaded.lines[0].singEnd == 2.6)
        #expect(loaded.lines[1].text == "一起唱")
    }

    @Test("對齊：歌詞整體晚 2 秒，找出約 -2 秒的位移（和 Mac 一樣是 -2.4；容許 0.4 秒，之後逐字時間再細調）")
    func shiftFound() {
        // 間隔不規則的 10 句（規則的間隔會讓 0 秒和 -2 秒一樣好，分不出來）
        let starts = [1.0, 3.9, 5.6, 9.4, 12.1, 13.8, 18.5, 21.2, 25.9, 28.0]
        var voiced = [Bool](repeating: false, count: 35 * 20)
        for s in starts { for i in Int(s * 20)..<Int((s + 1.2) * 20) { voiced[i] = true } }
        let lines = starts.map { ($0 + 2, "我愛你") }
        let (shift, hit) = LyricsFinder.chooseShift(lines, voiced: voiced, lengthDiff: 0)
        // Mac 版 lyrics.choose_shift 對同一組資料回傳 (-2.4, 1.0)：命中範圍是一段平台，取最前面那一格
        #expect(abs(shift - (-2.4)) < 1e-9)
        #expect(hit == 1.0)
        // 已經對準的歌詞不動
        #expect(LyricsFinder.chooseShift(starts.map { ($0, "我愛你") }, voiced: voiced, lengthDiff: 0).0 == 0)
    }

    @Test("歌詞少於 6 行不做位移")
    func tooFewLines() {
        let lines = LyricsFinder.parseLRC(syntheticLRC(lines: 4))
        #expect(LyricsFinder.chooseShift(lines, voiced: [true, false], lengthDiff: 0) == (0, 0))
    }

    @Test("繁簡判斷和簡轉繁")
    func script() {
        #expect(LyricsFinder.script("我爱你这说") == (0, 3))
        #expect(LyricsFinder.toTraditional("我爱你，这是说明") == "我愛你，這是說明")
    }
}

@Suite("元件：逐字時間")
struct WordTimingTests {
    @Test("切字：中文一字一個、英文一個單字一個（權重 = 音節）、標點併進前一個")
    func units() {
        let u = WordTiming.units("我愛你, hello world")
        #expect(u.count == 5)
        #expect(u.map(\.weight) == [1, 1, 1, 2, 1])
        #expect(WordTiming.slice("我愛你, hello world", u[2].start, u[2].end) == "你, ")
        #expect(u[2].phraseEnd && u[4].phraseEnd && !u[0].phraseEnd)
    }

    @Test("合成人聲：每個字的時間在這一行的範圍內、而且由小到大")
    func wordTimes() {
        // 20 秒的合成歌有 10 句，歌詞也要 10 行（少一行的話，最後一行會把第 10 句也算進去，Mac 版也一樣）
        let (_, vocals) = TestAudio.song(seconds: 20)
        let mono16k = AudioDecoder.resampleTo16k(vocals.mono)
        let pitch = MelodyPitch.extract(mono16k)
        let lines = LyricsFinder.parseLRC(syntheticLRC(lines: 10)).map { LRCLine(time: $0.0, text: $0.1) }
        let result = WordTiming.addWordTimes(lines, mono16k: mono16k, pitch: pitch)
        #expect(result.sung == 10)
        #expect(result.timed >= 8)
        for line in result.lines {
            guard let words = line.words, let end = line.end else { continue }
            #expect(words.count == 3)
            #expect(zip(words, words.dropFirst()).allSatisfy { $0.time < $1.time })
            #expect(words[0].time >= line.time - 0.6 && end <= line.time + 2.2, "行 \(line.time) 字 \(words[0].time) 結束 \(end)")
        }
    }

    @Test("沒有人聲的行維持整行時間")
    func silentLine() {
        let mono16k = [Float](repeating: 0, count: 16_000 * 6)
        let lines = [LRCLine(time: 1, text: "我愛你"), LRCLine(time: 3, text: "你愛我")]
        let result = WordTiming.addWordTimes(lines, mono16k: mono16k, pitch: nil)
        #expect(result.timed == 0)
        #expect(result.lines == lines)
    }
}

@Suite("元件：檔名")
struct NamingTests {
    @Test("歌名 - 歌手；歌名已含歌手時不重複；不能用的字元換掉")
    func baseName() {
        #expect(SongPipeline.baseName(title: "晴天", artist: "周杰倫") == "晴天 - 周杰倫")
        #expect(SongPipeline.baseName(title: "周杰倫 晴天", artist: "周杰倫") == "周杰倫 晴天")
        #expect(SongPipeline.baseName(title: "AC/DC: Back?", artist: nil) == "AC DC Back")
        #expect(SongPipeline.baseName(title: "x.伴唱", artist: nil) == "x")
        #expect(SongPipeline.baseName(title: " . ", artist: nil) == "未命名")
    }
}

import AVFoundation

enum AVAudioFileHelper {
    static func writeMono(_ samples: [Float], rate: Double, to url: URL) throws -> AVAudioFile {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count))!
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buf)
        return file
    }
}
