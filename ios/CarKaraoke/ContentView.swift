import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(Library.self) private var library
    @Environment(KaraokePlayer.self) private var player
    @Environment(SongServer.self) private var server
    @Environment(SongConverter.self) private var converter
    @Environment(PlaylistStore.self) private var playlists
    @Environment(\.scenePhase) private var scenePhase
    @State private var query = ""
    @State private var showImporter = false
    @State private var showPlayer = false
    @State private var showServer = false
    /// 「加入歌曲」裡按了「從檔案匯入」：等那個畫面收起來再打開選檔案
    @State private var importAfterSheet = false
    @State private var notice: String?
    @State private var hiddenScore: ScoreResult?
    /// 長按 →「刪除」後，等使用者確認的那首歌
    @State private var songToDelete: Song?
    @Environment(\.colorScheme) private var colorScheme

    private var filtered: [Song] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return library.songs }
        return library.songs.filter {
            $0.title.localizedCaseInsensitiveContains(q) || ($0.artist?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    Section {
                        if server.usesMac {  // 從沒配對過 Mac 的手機（例如朋友的）不顯示
                            LinkBar { showServer = true }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .glassCard(cornerRadius: 22)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 10, trailing: 16))
                        }
                        ForEach(server.requests) { RequestRow(request: $0) }
                        ForEach(converter.jobs) { ConversionRow(job: $0) }
                    }
                    .listRowBackground(Color.clear)
                }
                if showsPlaylists {
                    Section {
                        ForEach(playlists.playlists) { p in
                            NavigationLink {
                                PlaylistView(id: p.id)
                            } label: {
                                PlaylistRow(playlist: p)
                            }
                        }
                        .onDelete { offsets in  // 只刪清單，歌留著
                            let ids = offsets.map { playlists.playlists[$0].id }
                            ids.forEach(server.deletePlaylist)
                        }
                    } header: {
                        SectionTitle("播放清單")
                    }
                    .listRowBackground(Color.clear)
                }
                Section {
                    ForEach(filtered) { song in
                        Button {
                            let songs = filtered
                            if let i = songs.firstIndex(of: song) { player.play(songs, startAt: i) }
                        } label: {
                            SongRow(song: song, isCurrent: player.current?.id == song.id, isPlaying: player.isPlaying)
                        }
                        .buttonStyle(.plain)
                        .songActions(song, onPlay: {
                            let songs = filtered
                            if let i = songs.firstIndex(of: song) { player.play(songs, startAt: i) }
                        }, onDelete: { songToDelete = song })
                    }
                    .onDelete(perform: delete)
                } header: {
                    if showsPlaylists && !library.songs.isEmpty { SectionTitle("所有歌曲") }
                }
                .listRowBackground(Color.clear)
                if library.songs.isEmpty && server.requests.isEmpty && converter.jobs.isEmpty && query.isEmpty {
                    ContentUnavailableView {
                        Label("還沒有歌曲", systemImage: "music.mic")
                    } description: {
                        Text("按右上角的「從檔案匯入」選音檔（MP3、m4a…），\n手機會自己去人聲、找歌詞，一首約 30 秒。\nAirDrop 或 LINE 收到的音檔，選「用車上K歌開啟」也可以。")
                    }
                    .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background { HomeBackdrop(palette: ArtworkPalette.palette(for: player.artwork, key: player.current?.mainURL)) }
            .animation(.default, value: server.requests)
            .animation(.default, value: converter.jobs)
            .overlay {
                if !query.isEmpty && filtered.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .searchable(text: $query, prompt: "搜尋歌名或歌手")
            .refreshable { library.reload() }
            .navigationTitle("車上K歌")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showImporter = true } label: {
                        Label("從檔案匯入", systemImage: "square.and.arrow.down")
                    }
                    Button { showServer = true } label: {
                        Label("加入歌曲", systemImage: "plus")
                    }
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio], allowsMultipleSelection: true) {
                if case .success(let urls) = $0 {
                    let count = library.importFiles(urls)
                    converter.scan()  // 新的一般音檔：手機自動去人聲
                    if count == 0 { notice = "沒有匯入任何檔案" }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 6) {
                    if let score = player.lastScore, score != hiddenScore {
                        ScoreBanner(result: score) { hiddenScore = score }
                            .padding(.horizontal, 10)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    if player.current != nil {
                        MiniPlayer { showPlayer = true }
                    }
                }
                .animation(.default, value: player.lastScore)
            }
            .task(id: player.lastScore) {  // 分數卡 12 秒後自動收起
                guard let score = player.lastScore else { return }
                try? await Task.sleep(for: .seconds(12))
                hiddenScore = score
            }
            .sheet(isPresented: $showPlayer) {
                PlayerView()
            }
            .onChange(of: server.pairingPrompt) { showServer = true }  // 要輸入配對碼：打開「加入歌曲」
            .sheet(isPresented: $showServer, onDismiss: {
                if importAfterSheet {
                    importAfterSheet = false
                    showImporter = true
                }
            }) {
                ServerSheet { importAfterSheet = true }
            }
            .confirmationDialog("刪除「\(songToDelete?.title ?? "")」？",
                                isPresented: Binding(get: { songToDelete != nil }, set: { if !$0 { songToDelete = nil } }),
                                titleVisibility: .visible, presenting: songToDelete) { song in
                Button("刪除這首歌", role: .destructive) { remove(song) }
            } message: { _ in
                Text("會從手機刪掉這首歌的音檔和歌詞，之後要唱得重新加入。")
            }
            .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
                Button("好") {}
            }
            .alert("無法播放", isPresented: Binding(get: { player.errorMessage != nil && !showPlayer },  // 播放畫面開著時由它顯示
                                                set: { if !$0 { player.errorMessage = nil } })) {
                Button("好") {}
            } message: {
                Text(player.errorMessage ?? "")
            }
        }
        .onChange(of: scenePhase) { _, phase in
            converter.setActive(phase == .active)  // 背景不做去人聲
            if phase == .active {
                library.reload()  // 從 Finder 拖進來的新歌
                player.refreshSongs(library.songs)
                server.refresh()
                converter.scan()
            }
        }
    }

    private var showsPlaylists: Bool { query.isEmpty && !playlists.playlists.isEmpty }

    private func delete(at offsets: IndexSet) {
        let songs = filtered
        offsets.map { songs[$0] }.forEach(remove)
    }

    private func remove(_ song: Song) {
        if player.current?.id == song.id { player.stop() }
        library.delete(song)
    }
}

struct SongRow: View {
    let song: Song
    let isCurrent: Bool
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(url: song.mainURL, size: 52, cornerRadius: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(song.title)
                    .font(.body.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if !song.isBackingTrack {
                        Text("原曲")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                    Text(song.artist ?? "未知歌手").lineLimit(1)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if isCurrent {
                Image(systemName: isPlaying ? "waveform" : "pause.fill")
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel(isPlaying ? "正在播放" : "已暫停")
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

struct MiniPlayer: View {
    @Environment(KaraokePlayer.self) private var player
    @Environment(\.colorScheme) private var colorScheme
    var open: () -> Void

    var body: some View {
        if let song = player.current {
            // 玻璃染上封面的顏色（Spotify 的迷你播放器那樣）
            let palette = ArtworkPalette.palette(for: player.artwork, key: song.mainURL)
            HStack(spacing: 6) {
                Button(action: open) {
                    HStack(spacing: 12) {
                        ArtworkView(url: song.mainURL, size: 44, cornerRadius: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(song.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(subtitle(for: song))
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2).frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isPlaying ? "暫停" : "播放")
                Button { player.next() } label: {
                    Image(systemName: "forward.fill").font(.title3).frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("下一首")
            }
            .foregroundStyle(.primary)
            .padding(.leading, 8).padding(.trailing, 6).padding(.top, 8).padding(.bottom, 10)
            .overlay(alignment: .bottom) {
                MiniProgress().padding(.horizontal, 18).padding(.bottom, 4)
            }
            .glassCard(cornerRadius: 24, tint: palette?.color.opacity(colorScheme == .dark ? 0.5 : 0.22),
                       interactive: true)
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
        }
    }

    /// 有歌詞時顯示正在唱的這一行，沒有就顯示 伴唱／原唱
    private func subtitle(for song: Song) -> String {
        if let lyrics = player.lyrics, let i = player.lyricIndex, !lyrics.lines[i].text.isEmpty {
            return lyrics.lines[i].text
        }
        return song.canSwitchVocals ? player.mode.label : (song.isBackingTrack ? "伴唱" : "原曲")
    }
}

/// 迷你播放器底下的細進度線（每秒更新一次，暫停時不更新）
private struct MiniProgress: View {
    @Environment(KaraokePlayer.self) private var player

    var body: some View {
        TimelineView(.animation(minimumInterval: 1, paused: !player.isPlaying)) { _ in
            let fraction = player.duration > 0 ? min(max(player.currentTime / player.duration, 0), 1) : 0
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.15))
                    Capsule().fill(Color.primary.opacity(0.8)).frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 2)
        }
        .accessibilityHidden(true)
    }
}

/// 歌單的區塊標題（粗體大字）
struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.title3.bold())
            .foregroundStyle(Color.primary)
            .textCase(nil)
    }
}

/// 歌單背景：上方淡淡染上正在唱的那首歌的封面顏色
struct HomeBackdrop: View {
    let palette: ArtworkPalette.Palette?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .top) {
            Color(uiColor: .systemBackground)
            if let palette {
                LinearGradient(colors: [palette.color.opacity(colorScheme == .dark ? 0.55 : 0.28), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 420)
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: palette)
        .accessibilityHidden(true)
    }
}

extension View {
    /// 長按一首歌：播放、排到下一首、刪除（刪除會再問一次）
    func songActions(_ song: Song, onPlay: @escaping () -> Void, onDelete: @escaping () -> Void) -> some View {
        modifier(SongActions(song: song, onPlay: onPlay, onDelete: onDelete))
    }
}

private struct SongActions: ViewModifier {
    @Environment(KaraokePlayer.self) private var player
    @Environment(SongConverter.self) private var converter
    let song: Song
    let onPlay: () -> Void
    let onDelete: () -> Void

    func body(content: Content) -> some View {
        content.contextMenu {
            Button("播放", systemImage: "play.fill", action: onPlay)
            if player.current != nil && player.current?.id != song.id {
                Button("下一首唱這首", systemImage: "text.line.first.and.arrowtriangle.forward") { player.playNext(song) }
            }
            if !song.isBackingTrack && !converter.isQueued(song) {
                Button("手機去人聲", systemImage: "waveform.badge.minus") { converter.enqueue(song) }
            }
            Divider()
            Button("刪除這首歌", systemImage: "trash", role: .destructive, action: onDelete)
        }
    }
}
