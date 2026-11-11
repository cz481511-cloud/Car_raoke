import Foundation
import Testing
@testable import CarKaraoke

// 模組：這支手機用不用家裡的 Mac。
// 從沒配對過的手機（例如朋友的）不顯示 Mac 的功能，也不在網路上找 Mac；配對過的手機和以前一樣。
// 這裡都不碰真的網路：不會連到、也不會配對真的 Mac。

@Suite("模組：沒配對過 Mac 的手機", .serialized)
@MainActor
struct MacUsageTests {
    func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "ck-mac-\(UUID().uuidString)")!
    }

    @Test("從沒配對過（沒有記錄、鑰匙圈沒有金鑰）：不顯示 Mac 的功能，也不記錄")
    func neverPaired() {
        let defaults = freshDefaults()
        let server = SongServer(usage: MacUsage(defaults: defaults, hasPairingKey: { false }))
        #expect(server.usesMac == false)
        #expect(defaults.object(forKey: MacUsage.rememberedKey) == nil)
    }

    @Test("這個版本以前就配對過（鑰匙圈有金鑰）：和以前一樣顯示，並記下來")
    func pairedBeforeThisVersion() {
        let defaults = freshDefaults()
        let server = SongServer(usage: MacUsage(defaults: defaults, hasPairingKey: { true }))
        #expect(server.usesMac)
        #expect(defaults.bool(forKey: MacUsage.rememberedKey))
    }

    @Test("記錄過、但金鑰被刪掉（Mac 換了配對碼）：照樣顯示，才能重新配對")
    func keyRemovedLater() {
        let defaults = freshDefaults()
        MacUsage(defaults: defaults, hasPairingKey: { true }).remember()
        let server = SongServer(usage: MacUsage(defaults: defaults, hasPairingKey: { false }))
        #expect(server.usesMac)
    }

    @Test("沒配對過：App 啟動、回到前景，都不在網路上找 Mac")
    func neverPairedDoesNotBrowse() throws {
        let folder = try makeTempFolder()
        let library = Library(folder: folder)
        let player = KaraokePlayer()
        let playlists = PlaylistStore(folder: folder)
        let server = SongServer(usage: MacUsage(defaults: freshDefaults(), hasPairingKey: { false }))
        server.attach(library: library, player: player, playlists: playlists)
        #expect(!server.isBrowsing)
        server.refresh()
        #expect(!server.isBrowsing)
        #expect(server.connection == .searching)  // 沒有變成「找不到 Mac」：根本沒去找
    }

    @Test("按「連接家裡的 Mac」：這次打開 Mac 的功能；還沒連上前不記錄，重開 App 又藏起來")
    func useMacIsNotRememberedUntilConnected() {
        let defaults = freshDefaults()
        let usage = MacUsage(defaults: defaults, hasPairingKey: { false })
        let server = SongServer(usage: usage)
        server.useMac()  // 沒有 attach：不會真的去找 Mac
        #expect(server.usesMac)
        #expect(server.connection == .searching)
        #expect(defaults.object(forKey: MacUsage.rememberedKey) == nil)
        #expect(SongServer(usage: usage).usesMac == false)
    }

    @Test("連上或配對成功後記下來：重開 App 會顯示 Mac 的功能")
    func rememberedAfterConnecting() {
        let defaults = freshDefaults()
        let usage = MacUsage(defaults: defaults, hasPairingKey: { false })
        usage.remember()  // SongServer 在連上 Mac、配對成功時呼叫
        #expect(SongServer(usage: usage).usesMac)
    }

    @Test("鑰匙圈：存了一把 Mac 的金鑰就算配對過")
    func keychainHasAny() {
        let id = "test-\(UUID().uuidString)"
        PairingKeys.save("test-key", for: id)
        defer { PairingKeys.remove(id) }  // 不留在模擬器的鑰匙圈裡
        #expect(PairingKeys.key(for: id) == "test-key")
        #expect(PairingKeys.hasAny())
    }
}
