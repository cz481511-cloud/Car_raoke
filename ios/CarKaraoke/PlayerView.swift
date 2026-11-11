import SwiftUI
import UIKit

struct PlayerView: View {
    @Environment(KaraokePlayer.self) private var player
    @State private var showAllLyrics = false

    var body: some View {
        // 背景跟著封面變色（每首歌只算一次）
        let palette = ArtworkPalette.palette(for: player.artwork, key: player.current?.mainURL)
        ScrollView {
            VStack(spacing: 22) {
                if let song = player.current {
                    if let score = player.lastScore {
                        ScoreBanner(result: score, compact: true, onClose: nil)
                    }
                    ArtworkView(url: song.mainURL, size: player.lyrics == nil ? 300 : 190, cornerRadius: 14)
                        .shadow(color: .black.opacity(0.5), radius: 24, y: 14)
                        .padding(.top, player.lastScore == nil ? 12 : 0)
                    titleRow(song)
                    if let lyrics = player.lyrics {
                        Button { showAllLyrics = true } label: {
                            LyricsPanel(lyrics: lyrics)
                        }
                        .buttonStyle(.plain)
                        .glassCard(cornerRadius: 26, tint: palette?.color.opacity(0.3), interactive: true)
                        .accessibilityHint("打開全部歌詞，點一句就從那裡開始唱")
                    }
                    progress
                    controls
                    modeSection(song)
                    keySection
                    if player.lyrics != nil {
                        lyricsSection
                    }
                    scoringSection
                } else {
                    ContentUnavailableView("沒有正在播放的歌", systemImage: "music.note")
                        .padding(.top, 120)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .background { ArtworkBackdrop(palette: palette).ignoresSafeArea() }
        .environment(\.colorScheme, .dark)
        .presentationBackground(.black)
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showAllLyrics) {
            // 半高：上面還看得到 KTV 字幕
            LyricsListView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: player.lyrics == nil) { _, none in
            if none { showAllLyrics = false }
        }
        // 打開播放畫面時，主畫面的提示跳不出來，所以這裡也要顯示
        .alert("無法播放", isPresented: Binding(get: { player.errorMessage != nil },
                                            set: { if !$0 { player.errorMessage = nil } })) {
            Button("好") {}
        } message: {
            Text(player.errorMessage ?? "")
        }
    }

    /// 歌名、歌手靠左（升降 Key 時右邊顯示目前的 Key）
    private func titleRow(_ song: Song) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(song.title).font(.title2.bold()).lineLimit(2)
                Text(song.artist ?? "未知歌手").foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if player.keyShift != 0 {
                Text("Key " + String(format: "%+d", player.keyShift))
                    .font(.caption.weight(.bold).monospacedDigit())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .glass(Capsule())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var lyricsSection: some View {
        SettingsCard(title: "歌詞", systemImage: "text.quote") {
            Toggle(isOn: Binding(get: { player.carLyrics }, set: { player.carLyrics = $0 })) {
                Label("車機顯示歌詞", systemImage: "car.fill")
            }
            HStack(spacing: 10) {
                Text("歌詞時間").font(.subheadline)
                Spacer()
                Button("提早") { player.adjustLyricsOffset(by: 0.5) }
                    .accessibilityHint("歌詞提早 0.5 秒出現")
                Text(Self.offsetLabel(player.lyricsOffset))
                    .font(.subheadline.monospacedDigit())
                    .frame(minWidth: 64)
                Button("延後") { player.adjustLyricsOffset(by: -0.5) }
                    .accessibilityHint("歌詞延後 0.5 秒出現")
            }
            .buttonStyle(PillButtonStyle())
            Text("歌詞比歌聲慢就按「提早」，比歌聲快就按「延後」；每首歌會分別記住。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private static func offsetLabel(_ offset: TimeInterval) -> String {
        if offset == 0 { return "準時" }
        return String(format: offset > 0 ? "早 %.1f 秒" : "晚 %.1f 秒", abs(offset))
    }

    private var scoringSection: some View {
        SettingsCard(title: "唱歌評分", systemImage: "mic.fill") {
            Toggle("開啟評分（會用麥克風）", isOn: Binding(get: { player.scoringEnabled },
                                                set: { on in Task { await player.setScoring(on) } }))
            if player.scoringEnabled {
                HStack(spacing: 12) {
                    Menu {
                        ForEach(player.inputOptions) { option in
                            Button { player.selectInput(option.id) } label: {
                                if option.isCurrent {
                                    Label(option.name, systemImage: "checkmark")
                                } else {
                                    Text(option.name)
                                }
                            }
                        }
                    } label: {
                        Label(player.inputOptions.first(where: \.isCurrent)?.name ?? "選擇麥克風", systemImage: "mic")
                            .font(.subheadline)
                    }
                    Spacer()
                    MicLevelView(scorer: player.scorer)
                }
                if !player.currentSongScorable {
                    Text("這首沒有評分資料，請用新版「做伴唱」重新轉換。")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if player.mode != .karaoke {
                    Text("評分時建議用「伴唱」模式，避免喇叭放出的原唱被收進麥克風。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Toggle("唱完用語音報分數", isOn: Binding(get: { player.announceScore },
                                                 set: { player.announceScore = $0 }))
                    .font(.subheadline)
            }
        }
    }

    private var progress: some View {
        TimelineView(.animation(minimumInterval: 0.5, paused: !player.isPlaying)) { _ in
            Scrubber(time: player.currentTime, duration: player.duration) { player.seek(to: $0) }
        }
    }

    /// 上一首、播放（綠色大圓鈕）、下一首
    private var controls: some View {
        GlassGroup(spacing: 30) {
            HStack(spacing: 30) {
                roundButton("backward.fill", label: "上一首") { player.previous() }
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 84, height: 84)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glass(Circle(), tint: .accentColor, interactive: true)
                .accessibilityLabel(player.isPlaying ? "暫停" : "播放")
                roundButton("forward.fill", label: "下一首") { player.next() }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func roundButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 60, height: 60)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glass(Circle(), interactive: true)
        .accessibilityLabel(label)
    }

    /// 伴唱／導唱／原唱：玻璃膠囊，選到的是綠色
    @ViewBuilder
    private func modeSection(_ song: Song) -> some View {
        if song.canSwitchVocals {
            GlassGroup(spacing: 10) {
                HStack(spacing: 10) {
                    ForEach(VocalMode.allCases) { m in
                        let selected = player.mode == m
                        Button { player.setMode(m) } label: {
                            Text(m.label)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(selected ? Color.black : Color.primary)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .glass(Capsule(), tint: selected ? .accentColor : nil, interactive: true)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
            .animation(.snappy(duration: 0.25), value: player.mode)
        } else {
            Label(song.isBackingTrack ? "伴唱（沒有人聲檔，無法切換原唱）" : "原曲（這首沒有去人聲）",
                  systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var keySection: some View {
        SettingsCard(title: "升降 Key", systemImage: "tuningfork") {
            HStack(spacing: 12) {
                Button { player.setKey(player.keyShift - 1) } label: {
                    Image(systemName: "minus").frame(width: 44, height: 30)
                }
                .disabled(player.keyShift <= KaraokePlayer.keyRange.lowerBound)
                .accessibilityLabel("降 Key")
                Text(player.keyShift == 0 ? "0" : String(format: "%+d", player.keyShift))
                    .font(.title3.monospacedDigit().weight(.bold))
                    .frame(maxWidth: .infinity)
                Button { player.setKey(player.keyShift + 1) } label: {
                    Image(systemName: "plus").frame(width: 44, height: 30)
                }
                .disabled(player.keyShift >= KaraokePlayer.keyRange.upperBound)
                .accessibilityLabel("升 Key")
                Button("重設") { player.setKey(0) }
                    .font(.subheadline)
                    .disabled(player.keyShift == 0)
            }
            .buttonStyle(PillButtonStyle())
        }
    }
}

/// 設定卡裡的小按鈕：淡綠色膠囊，按不了時變成淡灰色。
/// （系統的 bordered 樣式在深色背景上按不了時，會變成一塊黑色）
struct PillButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(isEnabled ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
            .background {
                Capsule().fill(isEnabled ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06))
            }
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Capsule())
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// 播放畫面下方的設定卡（玻璃）
struct SettingsCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .tint(.accentColor)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 24)
    }
}

/// 播放進度條：整條都能點、能拖（不用剛好按到圓點），放開手才跳過去。
/// 手指在條上時，外面的捲動和關閉畫面的手勢不會把它搶走。
struct Scrubber: View {
    let time: TimeInterval
    let duration: TimeInterval
    var onSeek: (TimeInterval) -> Void
    /// 拖曳中的位置（手勢被系統取消時會自動清掉，不會卡住）
    @GestureState private var dragTime: TimeInterval?
    /// 剛放開、播放器還沒跟上時，先停在放開的位置，不要彈回去
    @State private var pending: TimeInterval?

    var body: some View {
        let shown = dragTime ?? pending ?? time
        let fraction = duration > 0 ? min(max(shown / duration, 0), 1) : 0
        let active = dragTime != nil
        VStack(spacing: 2) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.22))
                        .frame(height: active ? 10 : 6)
                    Capsule()
                        .fill(active ? Color.accentColor : Color.primary)
                        .frame(width: width * fraction, height: active ? 10 : 6)
                    Circle()
                        .fill(Color.white)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                        .frame(width: active ? 26 : 20, height: active ? 26 : 20)
                        .offset(x: width * fraction - (active ? 13 : 10))
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0)
                        .updating($dragTime) { value, state, _ in
                            state = position(at: value.location.x, width: width)
                        }
                        .onEnded { value in
                            let target = position(at: value.location.x, width: width)
                            pending = target
                            onSeek(target)
                        }
                )
                .animation(.easeOut(duration: 0.15), value: active)
            }
            .frame(height: 44)
            HStack {
                Text(Self.format(shown))
                Spacer()
                Text("-" + Self.format(max(duration - shown, 0)))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .onChange(of: time) { pending = nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("播放進度")
        .accessibilityValue("\(Self.format(shown))，全長 \(Self.format(duration))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onSeek(min(time + 10, duration))
            case .decrement: onSeek(max(time - 10, 0))
            @unknown default: break
            }
        }
    }

    private func position(at x: CGFloat, width: CGFloat) -> TimeInterval {
        guard width > 0 else { return 0 }
        return Double(min(max(x / width, 0), 1)) * duration
    }

    private static func format(_ time: TimeInterval) -> String {
        let t = max(Int(time.rounded(.down)), 0)
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// 麥克風音量條（確認有收到聲音）
struct MicLevelView: View {
    let scorer: SingingScorer

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.15)) { _ in
            let level = CGFloat(min(max((scorer.levelDB + 60) / 50, 0), 1))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule().fill(Color.accentColor).frame(width: 80 * level)
            }
            .frame(width: 80, height: 6)
        }
        .accessibilityLabel("麥克風音量")
    }
}

/// 唱完的分數卡
struct ScoreBanner: View {
    let result: ScoreResult
    var compact = false
    var onClose: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Text("\(result.score)")
                .font(.system(size: compact ? 28 : 34, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(compact ? "上一首 \(result.comment)" : result.comment).font(.headline)
                Text("\(result.title) · 音準 \(Int((result.accuracy * 100).rounded()))%")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.footnote.weight(.semibold)).padding(8)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("關閉")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassCard(cornerRadius: 18)
        .accessibilityElement(children: .combine)
    }
}

/// KTV 字幕：正在唱的這一行會從左到右變色，下面預告下一行
struct LyricsPanel: View {
    @Environment(KaraokePlayer.self) private var player
    let lyrics: Lyrics

    var body: some View {
        // 只有這個畫面打開、而且正在播放時才會重畫（約每秒 30 次）
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !player.isPlaying)) { _ in
            let t = player.lyricClock
            let i = lyrics.index(at: t + KaraokePlayer.lyricLead)
            let line = i.map { lyrics.lines[$0].text } ?? ""
            let next = lyrics.nextSung(after: i).map { lyrics.lines[$0].text }
            VStack(spacing: 12) {
                if line.isEmpty {
                    Text(i == nil ? "前奏…" : "間奏…")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    KaraokeLine(text: line, position: i.map { lyrics.wipePosition(of: $0, at: t) } ?? 0)
                }
                Text(next ?? " ")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            .frame(maxWidth: .infinity, minHeight: 84)
            .accessibilityElement(children: .combine)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 14)
        .overlay(alignment: .topTrailing) {
            Image(systemName: "list.bullet")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(10)
                .accessibilityHidden(true)
        }
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

/// 全部歌詞：點一句，音樂就回到那一句
struct LyricsListView: View {
    @Environment(KaraokePlayer.self) private var player
    @Environment(\.dismiss) private var dismiss
    /// 跟著歌聲自動捲動；使用者自己滑動時先停下來，按「目前這句」或點一句歌詞再恢復
    @State private var following = true

    var body: some View {
        NavigationStack {
            Group {
                if let lyrics = player.lyrics {
                    list(lyrics)
                } else {
                    ContentUnavailableView("這首沒有歌詞", systemImage: "text.quote")
                }
            }
            .navigationTitle(player.current?.title ?? "歌詞")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func list(_ lyrics: Lyrics) -> some View {
        let sung = lyrics.lines.indices.filter { !lyrics.lines[$0].text.isEmpty }
        let current = player.lyricIndex.flatMap { lyrics.lines[$0].text.isEmpty ? nil : $0 }
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text("點一句歌詞，音樂就從那裡開始")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 6)
                    ForEach(sung, id: \.self) { i in
                        row(i, lyrics.lines[i], current: current)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { _ in following = false })
            .overlay(alignment: .bottom) {
                if !following {
                    Button {
                        following = true
                        scroll(proxy, lyrics, animated: true)
                    } label: {
                        Label("目前這句", systemImage: "arrow.uturn.down")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .padding(.bottom, 12)
                }
            }
            .onAppear { scroll(proxy, lyrics, animated: false) }
            .onChange(of: player.lyricIndex) {
                if following { scroll(proxy, lyrics, animated: true) }
            }
        }
    }

    private func row(_ i: Int, _ line: LyricLine, current: Int?) -> some View {
        let isCurrent = i == current
        let isPast = current.map { i < $0 } ?? false
        return Button {
            following = true
            player.jumpToLyric(i)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(line.text)
                    .font(isCurrent ? .title3.bold() : .title3)
                    .foregroundStyle(isCurrent ? Color.accentColor : (isPast ? Color.secondary : Color.primary))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(Self.format(line.time - player.lyricsOffset))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(i)
        .accessibilityHint("從這一句開始播")
    }

    /// 捲到正在唱的那一句（間奏時捲到下一句）
    private func scroll(_ proxy: ScrollViewProxy, _ lyrics: Lyrics, animated: Bool) {
        let i = player.lyricIndex
        guard let target = i.flatMap({ lyrics.lines[$0].text.isEmpty ? nil : $0 }) ?? lyrics.nextSung(after: i)
        else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(target, anchor: .center) }
        } else {
            proxy.scrollTo(target, anchor: .center)
        }
    }

    private static func format(_ time: TimeInterval) -> String {
        let t = max(Int(time.rounded(.down)), 0)
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// 一行歌詞，唱過的部分換成主題色
struct KaraokeLine: View {
    let text: String
    /// 跑色跑到第幾個字（Lyrics.wipePosition，可以有小數）
    let position: Double

    var body: some View {
        let fraction = WipeLayout.fraction(of: text, at: position)
        styled(Text(text).foregroundStyle(.primary))
            .overlay(alignment: .leading) {
                styled(Text(text).foregroundStyle(Color.accentColor))
                    .mask(alignment: .leading) {
                        GeometryReader { geo in
                            Rectangle().frame(width: geo.size.width * fraction)
                        }
                    }
            }
    }

    private func styled(_ text: Text) -> some View {
        text.font(.title2.bold())
            .lineLimit(1)
            .minimumScaleFactor(0.5)
    }
}

/// 每個字在這一行裡的位置（0…1），讓跑色剛好停在字和字之間。
/// 字太長自動縮小時整行等比例縮，比例不變；同一行只量一次。
@MainActor
enum WipeLayout {
    private static var cache: [String: [Double]] = [:]

    static func fraction(of text: String, at position: Double) -> Double {
        let edges = edges(for: text)
        guard edges.count > 1 else { return 0 }
        let p = min(max(position, 0), Double(edges.count - 1))
        let k = min(Int(p), edges.count - 2)
        return edges[k] + (edges[k + 1] - edges[k]) * (p - Double(k))
    }

    static func edges(for text: String) -> [Double] {
        if let cached = cache[text] { return cached }
        let base = UIFont.preferredFont(forTextStyle: .title2)
        let font = base.fontDescriptor.withSymbolicTraits(.traitBold).map { UIFont(descriptor: $0, size: 0) } ?? base
        var xs: [Double] = [0]
        var prefix = ""
        for c in text {
            prefix.append(c)
            xs.append(Double((prefix as NSString).size(withAttributes: [.font: font]).width))
        }
        let total = max(xs.last ?? 1, 1)
        let edges = xs.map { min($0 / total, 1) }
        if cache.count > 64 { cache.removeAll() }
        cache[text] = edges
        return edges
    }
}
