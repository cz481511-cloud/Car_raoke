import AVFoundation
import Foundation
@testable import CarKaraoke

/// 測試用的合成音訊和替身（不用真的歌、不用連網）
enum TestAudio {
    /// 「伴奏」：低音 110 Hz + 和弦；「人聲」：一句一句的 220～330 Hz 長音
    static func song(seconds: Double, vocalsOn: Bool = true) -> (mix: StereoAudio, vocals: StereoAudio) {
        let n = Int(seconds * StereoAudio.sampleRate)
        var bedL = [Float](repeating: 0, count: n), bedR = bedL, voc = bedL
        for i in 0..<n {
            let t = Double(i) / StereoAudio.sampleRate
            let bed = 0.15 * sin(2 * .pi * 110 * t) + 0.08 * sin(2 * .pi * 164.8 * t)
            bedL[i] = Float(bed)
            bedR[i] = Float(bed * 0.9)
            guard vocalsOn else { continue }
            // 每 2 秒唱 1.4 秒，音高輪流 A3、C#4、E4
            let phrase = Int(t / 2), inPhrase = t - Double(phrase) * 2
            if inPhrase > 0.3 && inPhrase < 1.7 {
                let f = [220.0, 277.2, 329.6][phrase % 3]
                voc[i] = Float(0.25 * sin(2 * .pi * f * t) + 0.08 * sin(2 * .pi * 2 * f * t))
            }
        }
        let vocals = StereoAudio(left: voc, right: voc)
        let mix = StereoAudio(left: zip(bedL, voc).map(+), right: zip(bedR, voc).map(+))
        return (mix, vocals)
    }

    static func sine(_ freq: Double, seconds: Double, rate: Double = 16_000, amplitude: Float = 0.3) -> [Float] {
        (0..<Int(seconds * rate)).map { amplitude * Float(sin(2 * .pi * freq * Double($0) / rate)) }
    }

    /// 寫一個一般音檔（m4a，可選歌名／歌手標籤）
    static func writePlainFile(_ audio: StereoAudio, to url: URL, title: String? = nil, artist: String? = nil) async throws {
        if title == nil && artist == nil {
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: StereoAudio.sampleRate,
                                           AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000]
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(audio.frameCount))!
            buf.frameLength = AVAudioFrameCount(audio.frameCount)
            audio.left.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: audio.frameCount) }
            audio.right.withUnsafeBufferPointer { buf.floatChannelData![1].update(from: $0.baseAddress!, count: audio.frameCount) }
            try file.write(from: buf)
        } else {
            try await SongFileWriter.write(audio, to: url, tags: .init(
                title: title ?? "", artist: artist, kind: "原曲", pitchTag: nil, artwork: nil, comment: "test"))
        }
    }

    /// 兩段訊號的 SDR（dB）：越大越像
    static func sdr(_ est: [Float], _ ref: [Float]) -> Double {
        let n = min(est.count, ref.count)
        var num = 0.0, den = 0.0
        for i in 0..<n {
            num += Double(ref[i]) * Double(ref[i])
            let d = Double(ref[i] - est[i])
            den += d * d
        }
        return 10 * log10(num / max(den, 1e-20))
    }
}

func makeTempFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ck-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// 等到條件成立（最多 timeout 秒）
@MainActor
func waitUntil(timeout: Double = 60, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
}

/// 假的去人聲（快、可預測），可以設定延遲和失敗。
/// 有給 knownVocals 時當成「完美分離」：人聲就是它，伴唱 = 原曲 - 人聲；沒給時把原曲的一定比例當人聲。
struct FakeSeparator: VocalSeparating {
    var vocalShare: Float = 0.4
    var segments = 3
    var delayPerSegment: Duration = .zero
    var failure: Error?
    var knownVocals: StereoAudio?

    func separate(_ audio: StereoAudio, progress: @Sendable (Double) -> Void,
                  checkpoint: @Sendable () async throws -> Void) async throws -> SeparatedStems {
        progress(0)
        for k in 0..<segments {
            try await checkpoint()
            if delayPerSegment != .zero { try await Task.sleep(for: delayPerSegment) }
            progress(Double(k + 1) / Double(segments))
        }
        if let failure { throw failure }
        let vocals = knownVocals.map { v in
            let fit = { (x: [Float]) in Array((x + [Float](repeating: 0, count: max(0, audio.frameCount - x.count))).prefix(audio.frameCount)) }
            return StereoAudio(left: fit(v.left), right: fit(v.right))
        } ?? audio.scaled(by: vocalShare)
        return SeparatedStems(accompaniment: audio.subtracting(vocals), vocals: vocals)
    }
}

/// 固定答案的歌詞來源，可以設定成「網路不通」
struct StaticLyricsSource: LyricsSource {
    var answers: [LyricsQuery: [LyricsCandidate]] = [:]
    var fallback: [LyricsCandidate] = []
    var failing = false

    func search(_ query: LyricsQuery) async throws -> [LyricsCandidate] {
        if failing { throw URLError(.notConnectedToInternet) }
        return answers[query] ?? fallback
    }
}

/// 模擬 lrclib.net 的回應（不連網）
final class StubLRCLIBProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let (status, data) = Self.handler?(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubLRCLIBProtocol.self]
        return URLSession(configuration: cfg)
    }
}

/// 一份和合成歌曲對得上的 LRC：每 2 秒一行，從 0.3 秒開始唱
func syntheticLRC(lines: Int, offset: Double = 0) -> String {
    let words = ["我愛你", "你愛我", "一起唱", "車上歌", "好聽的", "再一次", "唱給你", "聽一聽", "晚安了", "下一首"]
    return (0..<lines).map { k in
        let t = 0.3 + 2 * Double(k) + offset
        return "[\(LyricsFinder.stamp(t))]\(words[k % words.count])"
    }.joined(separator: "\n")
}
