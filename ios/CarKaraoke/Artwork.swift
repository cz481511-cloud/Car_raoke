import AVFoundation
import SwiftUI
import UIKit

/// 讀取音檔內嵌的封面（Mac 轉換工具會把 YouTube 縮圖放進去）。
@MainActor
final class ArtworkCache {
    static let shared = ArtworkCache()
    private let cache = NSCache<NSURL, UIImage>()
    private var missing = Set<URL>()

    func image(for url: URL) async -> UIImage? {
        if let image = cache.object(forKey: url as NSURL) { return image }
        if missing.contains(url) { return nil }
        let image = await Self.load(url)
        if let image {
            cache.setObject(image, forKey: url as NSURL)
        } else {
            missing.insert(url)
        }
        return image
    }

    nonisolated private static func load(_ url: URL) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.commonMetadata) else { return nil }
        for item in items where item.commonKey == .commonKeyArtwork {
            if let data = try? await item.load(.dataValue), let image = UIImage(data: data) {
                return image
            }
        }
        return nil
    }
}

struct ArtworkView: View {
    let url: URL?
    var size: CGFloat
    var cornerRadius: CGFloat = 6
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color(uiColor: .secondarySystemFill))
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "music.mic")
                    .font(.system(size: size * 0.4))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: url) {
            image = nil
            if let url { image = await ArtworkCache.shared.image(for: url) }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - 外觀：動態玻璃（iOS 26 起）＋ 跟著封面變色的背景

extension View {
    /// 任意形狀的玻璃。iOS 26 起用系統的動態玻璃（透出後面的顏色、手指按下會有反應），舊系統用毛玻璃。
    /// tint：玻璃染色（要淡一點就自己帶 opacity）
    @ViewBuilder
    func glass(_ shape: some Shape, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    if let tint { shape.fill(tint) }
                }
            }
        }
    }

    /// 圓角玻璃卡片
    func glassCard(cornerRadius: CGFloat = 22, tint: Color? = nil, interactive: Bool = false) -> some View {
        glass(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous), tint: tint, interactive: interactive)
    }

    /// 玻璃按鈕；prominent = 主題綠色
    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }
}

/// 靠在一起的玻璃元件會互相融合（iOS 26 起）
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat?
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// 從封面取主色，做成播放畫面和迷你播放器的背景色。
/// 每首歌只算一次：把封面縮成 10×10，再放大顯示就是柔和的色塊，不需要即時模糊運算。
@MainActor
enum ArtworkPalette {
    struct Palette: Equatable {
        let key: URL
        let color: Color
        let wash: UIImage
        static func == (a: Palette, b: Palette) -> Bool { a.key == b.key }
    }

    private static var cache: [URL: Palette] = [:]

    static func palette(for image: UIImage?, key: URL?) -> Palette? {
        guard let image, let key else { return nil }
        if let hit = cache[key] { return hit }
        guard let cg = image.cgImage ?? render(image) else { return nil }
        let side = 10
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let small: CGImage? = pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return ctx.makeImage()
        }
        guard let small else { return nil }
        // 鮮豔的像素算重一點，整張才不會平均成灰色
        var r = 0.0, g = 0.0, b = 0.0, total = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let pr = Double(pixels[i]) / 255, pg = Double(pixels[i + 1]) / 255, pb = Double(pixels[i + 2]) / 255
            let weight = 0.1 + max(pr, pg, pb) - min(pr, pg, pb)
            r += pr * weight
            g += pg * weight
            b += pb * weight
            total += weight
        }
        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
        UIColor(red: r / total, green: g / total, blue: b / total, alpha: 1)
            .getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)
        // 背景要夠暗，白字才看得清楚
        let color = Color(hue: hue, saturation: min(sat * 1.2, 0.85), brightness: min(max(bri, 0.32), 0.58))
        let palette = Palette(key: key, color: color, wash: UIImage(cgImage: small))
        if cache.count > 64 { cache.removeAll() }
        cache[key] = palette
        return palette
    }

    private static func render(_ image: UIImage) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: 40, height: 40)
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }.cgImage
    }
}

/// 跟著封面變色的背景（播放畫面用）：封面色塊＋往下漸暗成黑色
struct ArtworkBackdrop: View {
    let palette: ArtworkPalette.Palette?

    var body: some View {
        ZStack {
            Color.black
            if let palette {
                Color.clear
                    .overlay {
                        Image(uiImage: palette.wash)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFill()
                    }
                    .clipped()
                    .opacity(0.85)
                LinearGradient(stops: [
                    .init(color: palette.color.opacity(0.35), location: 0),
                    .init(color: .black.opacity(0.45), location: 0.45),
                    .init(color: .black.opacity(0.92), location: 1),
                ], startPoint: .top, endPoint: .bottom)
            } else {
                LinearGradient(colors: [Color(white: 0.22), .black], startPoint: .top, endPoint: .bottom)
            }
        }
        .animation(.easeInOut(duration: 0.6), value: palette)
        .accessibilityHidden(true)
    }
}
