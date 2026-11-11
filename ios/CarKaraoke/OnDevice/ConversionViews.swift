import SwiftUI

/// 首頁上的一列：一首歌在手機上去人聲的進度
struct ConversionRow: View {
    @Environment(SongConverter.self) private var converter
    let job: SongConverter.Job

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.title)
                    .font(.body)
                    .lineLimit(1)
                Text(status)
                    .font(.subheadline)
                    .foregroundStyle(isFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(isFailed ? 4 : 2)
                    .fixedSize(horizontal: false, vertical: isFailed)
                if case .working(_, let p) = job.stage {
                    ProgressView(value: p)
                }
            }
            Spacer(minLength: 0)
            if isFailed {
                Button("重試") { converter.retry(job.id) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            if canDismiss {
                Button {
                    converter.dismiss(job.id)
                } label: {
                    Image(systemName: "xmark").frame(width: 32, height: 32)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityLabel("移除")
            }
        }
        .padding(.vertical, 2)
    }

    private var isFailed: Bool {
        if case .failed = job.stage { return true }
        return false
    }

    private var canDismiss: Bool {
        if case .working = job.stage { return false }
        return true
    }

    @ViewBuilder private var icon: some View {
        switch job.stage {
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.orange)
        case .waiting:
            Image(systemName: "hourglass").font(.title2).foregroundStyle(.secondary)
        case .working:
            if converter.isPaused {
                Image(systemName: "pause.circle").font(.title2).foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
    }

    private var status: String {
        switch job.stage {
        case .waiting:
            let ahead = converter.jobs.prefix { $0.id != job.id }.filter {
                switch $0.stage {
                case .waiting, .working: return true
                default: return false
                }
            }.count
            return ahead > 0 ? "排隊中，前面還有 \(ahead) 首" : "準備去人聲…"
        case .working(let step, let p):
            if let reason = converter.pauseReasons.sorted(by: { "\($0)" < "\($1)" }).first { return reason.message }
            return step == .separating ? "手機去人聲 \(Int(p * 100))%（一首約 30 秒）" : "\(step.rawValue)…"
        case .failed(let message): return message
        case .done(let message): return message
        }
    }
}
