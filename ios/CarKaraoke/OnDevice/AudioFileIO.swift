import AVFoundation
import Foundation

enum ConversionError: LocalizedError, Equatable {
    case unreadable
    case tooShort
    case modelMissing
    case writeFailed(String)
    case diskFull

    var errorDescription: String? {
        switch self {
        case .unreadable: return "這個檔案讀不出聲音（可能壞掉，或有版權保護）"
        case .tooShort: return "音檔太短（不到 1 秒）"
        case .modelMissing: return "找不到去人聲模型，請重新安裝 App"
        case .writeFailed(let why): return "存檔失敗：\(why)"
        case .diskFull: return "手機空間不夠，請先刪掉一些東西再重試"
        }
    }
}

/// 讀音檔：任何 iOS 讀得出來的格式 → 44.1 kHz 立體聲浮點數。
enum AudioDecoder {
    static func decode(_ url: URL) throws -> StereoAudio {
        guard let file = try? AVAudioFile(forReading: url) else { throw ConversionError.unreadable }
        let src = file.processingFormat
        guard file.length > 0, src.sampleRate > 0, src.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: StereoAudio.sampleRate,
                                         channels: 2, interleaved: false),
              let converter = AVAudioConverter(from: src, to: target) else { throw ConversionError.unreadable }
        if src.channelCount == 1 { converter.channelMap = [0, 0] }  // 單聲道 → 左右一樣

        let chunk: AVAudioFrameCount = 1 << 16
        let expected = Int(Double(file.length) * StereoAudio.sampleRate / src.sampleRate) + 4096
        var left = [Float](), right = [Float]()
        left.reserveCapacity(expected)
        right.reserveCapacity(expected)
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: chunk),
              let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: chunk * 2) else {
            throw ConversionError.unreadable
        }
        var finished = false
        var readError: Error?
        while true {
            var convError: NSError?
            let status = converter.convert(to: outBuf, error: &convError) { _, outStatus in
                if finished { outStatus.pointee = .endOfStream; return nil }
                do {
                    try file.read(into: inBuf, frameCount: chunk)
                } catch {
                    readError = error
                    finished = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if inBuf.frameLength == 0 {
                    finished = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return inBuf
            }
            let n = Int(outBuf.frameLength)
            if n > 0, let ch = outBuf.floatChannelData {
                left.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: n))
                right.append(contentsOf: UnsafeBufferPointer(start: ch[1], count: n))
            }
            if status == .error || convError != nil { throw ConversionError.unreadable }
            if status == .endOfStream || (status == .inputRanDry && finished) { break }
        }
        if readError != nil && left.isEmpty { throw ConversionError.unreadable }
        guard !left.isEmpty else { throw ConversionError.unreadable }
        return StereoAudio(left: left, right: right)
    }

    /// 任意長度單聲道 44.1 kHz → 16 kHz（評分音高、歌詞對齊、逐字時間都用 16 kHz）
    static func resampleTo16k(_ mono: [Float]) -> [Float] {
        guard !mono.isEmpty,
              let src = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: StereoAudio.sampleRate,
                                      channels: 1, interleaved: false),
              let dst = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: src, to: dst),
              let inBuf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: AVAudioFrameCount(mono.count)) else { return [] }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        inBuf.frameLength = AVAudioFrameCount(mono.count)
        mono.withUnsafeBufferPointer { inBuf.floatChannelData![0].update(from: $0.baseAddress!, count: mono.count) }
        let capacity = AVAudioFrameCount(Double(mono.count) * 16_000 / StereoAudio.sampleRate) + 1024
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: capacity) else { return [] }
        var given = false
        var out = [Float]()
        out.reserveCapacity(Int(capacity))
        while true {
            outBuf.frameLength = 0
            let status = converter.convert(to: outBuf, error: nil) { _, outStatus in
                if given { outStatus.pointee = .endOfStream; return nil }
                given = true
                outStatus.pointee = .haveData
                return inBuf
            }
            if outBuf.frameLength > 0 {
                out.append(contentsOf: UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength)))
            }
            if status != .haveData { break }
        }
        return out
    }
}

/// 原始音檔裡的歌名、歌手、封面
struct SourceTags: Sendable, Equatable {
    var title: String?
    var artist: String?
    var artwork: Data?

    static func read(_ url: URL) async -> SourceTags {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.commonMetadata) else { return SourceTags() }
        var tags = SourceTags()
        for item in items {
            switch item.commonKey {
            case .commonKeyTitle?: tags.title = try? await item.load(.stringValue)
            case .commonKeyArtist?: tags.artist = try? await item.load(.stringValue)
            case .commonKeyArtwork?: tags.artwork = try? await item.load(.dataValue)
            default: break
            }
        }
        tags.title = tags.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        tags.artist = tags.artist?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        return tags
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// 寫出和 Mac 轉換工具一樣的 m4a：AAC 192 kbps，標籤有歌名、歌手、專輯「車上K歌 伴唱／人聲」、
/// 封面，伴唱檔另外在 description 標籤放原唱音高「CKP1:20:base64」（評分用，ReferencePitch 讀它）。
enum SongFileWriter {
    struct Tags: Sendable {
        var title: String
        var artist: String?
        var kind: String          // 「伴唱」或「人聲」
        var pitchTag: String?     // CKP1:...
        var artwork: Data?
        var comment: String
    }

    static func write(_ audio: StereoAudio, to dest: URL, tags: Tags) async throws {
        let fm = FileManager.default
        let folder = dest.deletingLastPathComponent()
        let raw = folder.appendingPathComponent(".raw-\(UUID().uuidString).m4a")
        let tagged = folder.appendingPathComponent(dest.deletingPathExtension().lastPathComponent + ".tmp.m4a")
        defer {
            try? fm.removeItem(at: raw)
            try? fm.removeItem(at: tagged)
        }
        do {
            try encodeAAC(audio, to: raw)
        } catch {
            throw isDiskFull(error) ? ConversionError.diskFull : ConversionError.writeFailed("編碼失敗")
        }
        try? fm.removeItem(at: tagged)
        try await addTags(from: raw, to: tagged, tags: tags)
        do {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: tagged, to: dest)
        } catch {
            throw isDiskFull(error) ? ConversionError.diskFull : ConversionError.writeFailed(error.localizedDescription)
        }
    }

    private static func isDiskFull(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.code == NSFileWriteOutOfSpaceError || (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC))
    }

    private static func encodeAAC(_ audio: StereoAudio, to url: URL) throws {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: StereoAudio.sampleRate,
                                       AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 1 << 16
        var i = 0
        while i < audio.frameCount {
            let n = min(chunk, audio.frameCount - i)
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(n)) else {
                throw ConversionError.writeFailed("記憶體不足")
            }
            buf.frameLength = AVAudioFrameCount(n)
            audio.left.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress! + i, count: n) }
            audio.right.withUnsafeBufferPointer { buf.floatChannelData![1].update(from: $0.baseAddress! + i, count: n) }
            try file.write(from: buf)
            i += n
        }
    }

    private static func item(_ id: AVMetadataIdentifier, _ value: NSCopying & NSObjectProtocol,
                             dataType: String? = nil) -> AVMetadataItem {
        let m = AVMutableMetadataItem()
        m.identifier = id
        m.value = value
        if let dataType { m.dataType = dataType }
        m.extendedLanguageTag = "und"
        return m
    }

    private static func addTags(from src: URL, to dest: URL, tags: Tags) async throws {
        var items: [AVMetadataItem] = [
            item(.iTunesMetadataSongName, tags.title as NSString),
            item(.iTunesMetadataAlbum, "車上K歌 \(tags.kind)" as NSString),
            item(.iTunesMetadataUserComment, tags.comment as NSString),
        ]
        if let artist = tags.artist { items.append(item(.iTunesMetadataArtist, artist as NSString)) }
        if let pitch = tags.pitchTag { items.append(item(.iTunesMetadataDescription, pitch as NSString)) }
        if let art = tags.artwork {
            let type = art.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? kCMMetadataBaseDataType_PNG : kCMMetadataBaseDataType_JPEG
            items.append(item(.iTunesMetadataCoverArt, art as NSData, dataType: type as String))
        }
        let asset = AVURLAsset(url: src)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw ConversionError.writeFailed("無法寫入標籤")
        }
        export.metadata = items
        if #available(iOS 18, *) {
            do {
                try await export.export(to: dest, as: .m4a)
            } catch {
                throw isDiskFull(error) ? ConversionError.diskFull : ConversionError.writeFailed("寫入標籤失敗")
            }
        } else {
            export.outputURL = dest
            export.outputFileType = .m4a
            await export.export()
            if export.status != .completed {
                let error = export.error ?? ConversionError.writeFailed("寫入標籤失敗")
                throw isDiskFull(error) ? ConversionError.diskFull : ConversionError.writeFailed("寫入標籤失敗")
            }
        }
    }
}
