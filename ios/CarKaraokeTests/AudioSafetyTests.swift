import AVFoundation
import Testing
@testable import CarKaraoke

// 模組：音訊引擎出狀況時不閃退。
// AVAudioPlayerNode、麥克風收音在引擎狀態不對時會丟出 Objective-C 例外，Swift 的 do/catch 接不到，App 會直接閃退
// （實際發生過：播放卡住、自動接回播放時，出現「player did not see an IO cycle」閃退）。
// 這裡確認這些例外都會變成 Swift 接得到的錯誤。

@Suite("模組：音訊引擎出狀況時不閃退")
struct AudioSafetyTests {
    static let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!

    @Test("Objective-C 例外會變成 Swift 的錯誤，原因放在錯誤說明裡")
    func exceptionBecomesError() {
        var message = ""
        do {
            try ObjCException.run {
                NSException(name: .internalInconsistencyException, reason: "測試用的例外", userInfo: nil).raise()
            }
        } catch {
            message = error.localizedDescription
        }
        #expect(message == "測試用的例外")
    }

    @Test("沒有例外時照常執行，不丟錯誤")
    func runsNormally() throws {
        var ran = false
        try ObjCException.run { ran = true }
        #expect(ran)
    }

    @Test("音訊引擎真的丟出例外時（同一個地方裝兩次收音）：接得住，不閃退")
    func realAudioException() {
        let engine = AVAudioEngine()
        let mixer = engine.mainMixerNode
        var message = ""
        do {
            try ObjCException.run {
                mixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { _, _ in }
                mixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { _, _ in }
            }
        } catch {
            message = error.localizedDescription
        }
        mixer.removeTap(onBus: 0)
        #expect(!message.isEmpty)
    }

    @Test("播放器還沒接上引擎就叫它播：丟出錯誤，不閃退")
    func playWithoutEngine() {
        let player = AVAudioPlayerNode()
        #expect(throws: (any Error).self) { try player.safePlay() }
        #expect(throws: (any Error).self) {
            try player.safePlay(at: AVAudioTime(hostTime: mach_absolute_time()))
        }
    }

    @Test("引擎正常時照常開始播")
    func playNormally() throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: Self.format)
        try engine.enableManualRenderingMode(.offline, format: Self.format, maximumFrameCount: 4096)
        try engine.start()
        defer { engine.stop() }
        try player.safePlay()
        #expect(player.isPlaying)
    }
}
