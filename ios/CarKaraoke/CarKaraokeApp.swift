import SwiftUI

@main
struct CarKaraokeApp: App {
    @State private var library = Library()
    @State private var player = KaraokePlayer()
    @State private var server = SongServer()
    @State private var playlists = PlaylistStore()
    @State private var converter = SongConverter()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(library)
                .environment(player)
                .environment(server)
                .environment(playlists)
                .environment(converter)
                .task {
                    server.attach(library: library, player: player, playlists: playlists)
                    converter.onLibraryChanged = { [library, player] in player.refreshSongs(library.songs) }
                    converter.attach(library: library)  // 手機去人聲：新匯入的一般音檔自動處理
                }
                .onOpenURL { url in
                    if url.scheme == "carkaraoke" {
                        // carkaraoke://add?url=<YouTube／Spotify 歌曲或播放清單連結>（給「捷徑」App 的分享選單用）
                        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                        if let link = items.first(where: { $0.name == "url" || $0.name == "text" })?.value {
                            server.submit(link)
                        }
                    } else {
                        library.importFiles([url])  // AirDrop／「用車上K歌開啟」
                        converter.scan()
                    }
                }
        }
    }
}
