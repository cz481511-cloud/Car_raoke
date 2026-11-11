import SwiftUI
import UniformTypeIdentifiers

/// 歌單最上面：一鍵貼上 YouTube／Spotify 連結
struct LinkBar: View {
    @Environment(SongServer.self) private var server
    var openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                // 系統的「貼上」按鈕：按了才讀剪貼簿，不會跳出「允許貼上」的詢問
                PasteButton(supportedContentTypes: [.url, .plainText]) { providers in
                    Task { @MainActor in
                        if let text = await Self.text(from: providers) { server.submit(text) }
                    }
                }
                .labelStyle(.titleAndIcon)
                .buttonBorderShape(.capsule)
                .tint(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("貼上歌曲連結就開始唱")
                        .font(.subheadline.weight(.semibold))
                    Text("YouTube 或 Spotify →「分享」→「複製連結」")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            Button(action: openSettings) {
                ServerStatusLabel()
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
    }

    static func text(from providers: [NSItemProvider]) async -> String? {
        for p in providers {
            if p.canLoadObject(ofClass: URL.self) {
                let url: URL? = await withCheckedContinuation { c in
                    _ = p.loadObject(ofClass: URL.self) { value, _ in c.resume(returning: value) }
                }
                if let url { return url.absoluteString }
            }
            if p.canLoadObject(ofClass: String.self) {
                let text: String? = await withCheckedContinuation { c in
                    _ = p.loadObject(ofClass: String.self) { value, _ in c.resume(returning: value) }
                }
                if let text { return text }
            }
        }
        return nil
    }
}

struct ServerStatusLabel: View {
    @Environment(SongServer.self) private var server
    var showsChevron = true

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Mac 連線設定")
    }

    private var color: Color {
        switch server.connection {
        case .connected: return .green
        case .searching, .needsPairing: return .orange
        case .notFound, .denied: return .red
        }
    }

    private var text: String {
        switch server.connection {
        case .connected(let name): return "已連上 \(name)"
        case .needsPairing(let name): return "要輸入 \(name) 的配對碼" + (showsChevron ? "（點這裡）" : "")
        case .searching: return "正在尋找家裡的 Mac…"
        case .notFound: return "找不到 Mac（點這裡看說明）"
        case .denied: return "需要「區域網路」權限（點這裡看說明）"
        }
    }
}

/// 一個貼上的連結：Mac 處理進度
struct RequestRow: View {
    @Environment(SongServer.self) private var server
    let request: SongServer.Request

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(request.title ?? shortLink)
                    .font(.body)
                    .lineLimit(1)
                Text(status)
                    .font(.subheadline)
                    .foregroundStyle(isFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(isFailed ? 4 : 1)
                    .fixedSize(horizontal: false, vertical: isFailed)
                if case .separating(let p?) = request.stage {
                    ProgressView(value: p)
                }
            }
            Spacer(minLength: 0)
            if isFailed {
                if SongServer.canRetry(request.link) {
                    Button("重試") { server.retry(request.id) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Button {
                    server.dismiss(request.id)
                } label: {
                    Image(systemName: "xmark").frame(width: 32, height: 32)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityLabel("移除")
            }
        }
        .padding(.vertical, 2)
        .swipeActions {
            Button("移除", role: .destructive) { server.dismiss(request.id) }
        }
    }

    private var isFailed: Bool {
        if case .failed = request.stage { return true }
        return false
    }

    private var shortLink: String {
        request.link.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "www.", with: "")
    }

    @ViewBuilder private var icon: some View {
        switch request.stage {
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.orange)
        default:
            ProgressView()
        }
    }

    private var status: String {
        switch request.stage {
        case .sending: return "傳送到 Mac…"
        case .queued(let ahead): return ahead > 0 ? "排隊中，前面還有 \(ahead) 首" : "排隊中…"
        case .searching: return "Mac 正在 YouTube 找同一首歌…"
        case .downloading: return "Mac 正在從 YouTube 下載…"
        case .separating(let p):
            return p.map { "Mac 正在去人聲 \(Int($0 * 100))%" } ?? "Mac 正在去人聲（約 1 分鐘）…"
        case .transferring: return "傳到手機…"
        case .done: return request.outcome ?? "完成"
        case .failed(let message): return message
        }
    }
}

/// 「加入歌曲」：Mac 連線設定、手動輸入連結、同步 Mac 上的歌。
/// 從沒配對過 Mac 的手機只顯示「從檔案匯入」和一個「連接家裡的 Mac」。
struct ServerSheet: View {
    @Environment(SongServer.self) private var server
    @Environment(\.dismiss) private var dismiss
    /// 按了「從檔案匯入」：畫面收起來後由歌單打開選檔案
    var onImportFiles: () -> Void = {}
    @State private var link = ""
    @State private var address = ""

    var body: some View {
        NavigationStack {
            Form {
                if !server.usesMac {
                    PhoneOnlySections {
                        onImportFiles()
                        dismiss()
                    }
                } else {
                    macSections
                }
            }
            .navigationTitle("加入歌曲")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear { address = server.manualAddress }
        }
    }

    @ViewBuilder private var macSections: some View {
        if case .needsPairing(let name) = server.connection {
            PairingSection(name: name)
        }
        Section {
            ServerStatusLabel(showsChevron: false)
            switch server.connection {
            case .notFound, .denied:
                Text(server.notConnectedMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            default:
                EmptyView()
            }
            Button("重新連線") { server.setManualAddress(address) }
        } header: {
            Text("家裡的 Mac")
        }

        Section {
            TextField("貼上或輸入 YouTube／Spotify 連結（歌曲或播放清單）", text: $link, axis: .vertical)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("加入") {
                server.submit(link)
                link = ""
                dismiss()
            }
            .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } header: {
            Text("手動輸入連結")
        }

        Section {
            Button {
                Task { await server.syncAll() }
            } label: {
                HStack {
                    Label("把 Mac 上的歌全部傳到手機", systemImage: "arrow.triangle.2.circlepath")
                    if server.isSyncing {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(server.isSyncing)
            if let status = server.syncStatus {
                Text(status).font(.footnote).foregroundStyle(.secondary)
            }
        } footer: {
            Text("在 Mac 上用「做伴唱」轉好的歌，也可以用這個一次傳過來。歌傳到手機後，Mac 會把自己那份刪掉，不佔 Mac 的硬碟。")
        }

        Section {
            TextField("例如 192.168.1.20 或 100.101.102.103", text: $address)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { server.setManualAddress(address) }
            Button("儲存並連線") { server.setManualAddress(address) }
        } header: {
            Text("手動輸入 Mac 位址（通常不用填）")
        } footer: {
            Text("手機和 Mac 連同一個 Wi-Fi 時會自動找到。人在外面想用的話，Mac 和手機都裝 Tailscale，然後在這裡填 Mac 的 Tailscale 位址。")
        }
    }
}

/// 沒配對過 Mac 的手機：用手機自己做伴唱；最下面留一個不起眼的「連接家裡的 Mac」
private struct PhoneOnlySections: View {
    @Environment(SongServer.self) private var server
    var importFiles: () -> Void

    var body: some View {
        Section {
            Button(action: importFiles) {
                Label("從檔案匯入", systemImage: "square.and.arrow.down")
            }
        } header: {
            Text("用手機加入")
        } footer: {
            Text("MP3、m4a 都可以。手機會自己去人聲、找歌詞，一首約 30 秒。\nAirDrop 或 LINE 收到的音檔，選「用車上K歌開啟」也可以。")
        }

        Section {
            Button("連接家裡的 Mac") { server.useMac() }
                .font(.footnote)
        } footer: {
            Text("只有自己的 Mac 上裝了車上K歌伺服器才需要。輸入 Mac 的配對碼後，就能貼 YouTube／Spotify 連結，由 Mac 做伴唱。")
        }
    }
}

/// 第一次連到一台 Mac：輸入它的 6 位數配對碼
struct PairingSection: View {
    @Environment(SongServer.self) private var server
    let name: String
    @State private var code = ""
    @State private var error: String?
    @State private var working = false
    @FocusState private var focused: Bool

    var body: some View {
        Section {
            TextField("6 位數字", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .font(.title2.monospacedDigit())
                .focused($focused)
                .onChange(of: code) {
                    let digits = String(code.filter(\.isASCII).filter(\.isNumber).prefix(6))
                    if digits != code { code = digits }
                }
            Button {
                Task {
                    working = true
                    error = await server.pair(code: code)
                    working = false
                    if error == nil { code = "" }
                }
            } label: {
                HStack {
                    Text("配對")
                    if working {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(code.count != 6 || working)
            if let error {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("輸入 \(name) 的配對碼")
        } footer: {
            Text("在 Mac 上打開 CarKaraoke 資料夾，雙擊「配對碼.command」就會看到 6 位數字。每支手機只要輸入一次；別人就算連同一個 Wi-Fi，沒有配對碼也用不了你的 Mac。")
        }
        .onAppear { focused = true }
    }
}
