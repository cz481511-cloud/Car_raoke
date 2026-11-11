import SwiftUI

/// 歌單裡的一個播放清單
struct PlaylistRow: View {
    @Environment(Library.self) private var library
    @Environment(PlaylistStore.self) private var store
    let playlist: Playlist

    var body: some View {
        let ready = store.songs(in: playlist, from: library)
        HStack(spacing: 12) {
            if let first = ready.first {
                ArtworkView(url: first.mainURL, size: 52, cornerRadius: 8)
            } else {
                Image(systemName: "music.note.list")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 52, height: 52)
                    .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.body)
                    .lineLimit(1)
                Text(summary(ready: ready.count))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if playlist.isImporting {
                ProgressView()
            }
        }
        .padding(.vertical, 2)
    }

    private func summary(ready: Int) -> String {
        var text = "\(ready)/\(playlist.items.count) 首可以唱"
        if playlist.isImporting {
            text += "・Mac 處理中"
        } else if playlist.failedCount > 0 {
            text += "・\(playlist.failedCount) 首沒做好"
        }
        return text
    }
}

/// 播放清單裡面：照 Spotify 的順序列出每首歌，做好的可以唱，還沒好的顯示 Mac 的進度
struct PlaylistView: View {
    @Environment(Library.self) private var library
    @Environment(KaraokePlayer.self) private var player
    @Environment(PlaylistStore.self) private var store
    @Environment(SongServer.self) private var server
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var confirmDelete = false
    @State private var showPlayer = false
    @State private var songToDelete: Song?

    var body: some View {
        if let p = store.playlist(id) {
            content(p)
        } else {
            ContentUnavailableView("這個播放清單已經刪除", systemImage: "music.note.list")
        }
    }

    private func content(_ p: Playlist) -> some View {
        let songs = store.songs(in: p, from: library)
        let byKey = Dictionary(songs.map { ($0.stableKey, $0) }, uniquingKeysWith: { a, _ in a })
        return List {
            Section {
                HStack(spacing: 12) {
                    Button {
                        player.play(songs, startAt: 0, source: id)
                    } label: {
                        Label("播放", systemImage: "play.fill")
                            .font(.headline)
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                    }
                    .glassButton(prominent: true)
                    Button {
                        player.play(songs.shuffled(), startAt: 0, source: id)
                    } label: {
                        Label("隨機播放", systemImage: "shuffle")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .glassButton()
                }
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .disabled(songs.isEmpty)
                .listRowSeparator(.hidden)
                VStack(alignment: .leading, spacing: 6) {
                    Text(statusLine(p, ready: songs.count))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if p.isImporting || hasLeftovers(p, ready: songs.count) {
                        ServerStatusLabel(showsChevron: false)
                    }
                }
            }
            Section {
                ForEach(Array(p.items.enumerated()), id: \.element.id) { n, item in
                    if let stem = item.stem, let song = byKey[stem] {
                        Button {
                            player.play(songs, startAt: songs.firstIndex(of: song) ?? 0, source: id)
                        } label: {
                            SongRow(song: song, isCurrent: player.current?.id == song.id, isPlaying: player.isPlaying)
                        }
                        .buttonStyle(.plain)
                        .songActions(song, onPlay: {
                            player.play(songs, startAt: songs.firstIndex(of: song) ?? 0, source: id)
                        }, onDelete: { songToDelete = song })
                    } else {
                        PendingItemRow(item: item, number: n + 1, deletedOnPhone: item.stem != nil)
                    }
                }
            }
        }
        .listStyle(.plain)
        .safeAreaInset(edge: .bottom) {
            if player.current != nil {
                MiniPlayer { showPlayer = true }
            }
        }
        .sheet(isPresented: $showPlayer) {
            PlayerView()
        }
        .navigationTitle(p.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if p.isImporting {
                        Button("停止匯入", systemImage: "stop.circle") { server.cancelImport(id) }
                    } else if hasLeftovers(p, ready: songs.count) {
                        Button("繼續匯入沒做好的歌", systemImage: "arrow.clockwise") { server.resumeImport(id) }
                    }
                    Button("刪除播放清單", systemImage: "trash", role: .destructive) { confirmDelete = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("更多")
            }
        }
        .confirmationDialog("刪除「\(songToDelete?.title ?? "")」？",
                            isPresented: Binding(get: { songToDelete != nil }, set: { if !$0 { songToDelete = nil } }),
                            titleVisibility: .visible, presenting: songToDelete) { song in
            Button("刪除這首歌", role: .destructive) {
                if player.current?.id == song.id { player.stop() }
                library.delete(song)
            }
        } message: { _ in
            Text("會從手機刪掉這首歌的音檔和歌詞，之後要唱得重新加入。")
        }
        .confirmationDialog("刪除「\(p.name)」？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("刪除播放清單", role: .destructive) {
                server.deletePlaylist(id)
                dismiss()
            }
        } message: {
            Text("只刪除這個播放清單，已經傳到手機的歌會留在歌單裡。")
        }
    }

    private func hasLeftovers(_ p: Playlist, ready: Int) -> Bool {
        !p.isImporting && ready < p.items.count
    }

    private func statusLine(_ p: Playlist, ready: Int) -> String {
        let source = "Spotify \(p.kindLabel)" + (p.owner.map { "・\($0)" } ?? "")
        var text = "\(source)・\(ready)/\(p.items.count) 首可以唱"
        if p.isImporting {
            let left = p.items.filter(\.isWorking).count
            text += "。Mac 還要做 \(left) 首（一首約 1 分鐘）"
        } else if ready < p.items.count {
            text += "。沒做好的歌可以按右上角「⋯ → 繼續匯入」"
        }
        return text
    }
}

/// 還沒傳到手機的歌：顯示 Mac 的進度
struct PendingItemRow: View {
    let item: Playlist.Item
    let number: Int
    let deletedOnPhone: Bool

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if item.isWorking && item.status != "queued" {
                    ProgressView()
                } else if item.status == "failed" {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else {
                    Text("\(number)").font(.subheadline.monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
            .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(status)
                    .font(.subheadline)
                    .foregroundStyle(item.status == "failed" ? AnyShapeStyle(.red) : AnyShapeStyle(.tertiary))
                    .lineLimit(item.status == "failed" ? 3 : 1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var status: String {
        if deletedOnPhone { return "手機上已經刪掉了" }
        switch item.status {
        case "queued":
            if let ahead = item.ahead, ahead > 0 { return "排隊中，前面還有 \(ahead) 首" }
            return "排隊中"
        case "searching": return "Mac 正在 YouTube 找這首歌…"
        case "downloading": return "Mac 正在從 YouTube 下載…"
        case "separating":
            return item.progress.map { "Mac 正在去人聲 \(Int($0 * 100))%" } ?? "Mac 正在去人聲…"
        case "done": return "傳到手機…"
        case "canceled": return "已停止匯入"
        case "failed": return item.error ?? "沒做好"
        default: return item.artist ?? ""
        }
    }
}
