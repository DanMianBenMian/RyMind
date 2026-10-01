import Foundation
import UIKit
import CoreGraphics

/// 本地位图生成器（100% 离线、不用联网下载权重）。
///
/// 两条路：
///  · 有参考图 → **img2img**：以参考图每个像素的色相/亮度当底子，用 fBm 噪声调制明暗和细节，
///    相当于"在参考图基础上改进"，而不是凭空画个圆。
///  · 没参考图 → 程序化生成：fBm 分形噪声 + 调色板 + 构图（星云 / 山脊 / 波纹 / 网格）。
///
/// 先算 180×180 的小图再放大到目标尺寸（放大用高质量插值），这样在 iPad 上也是秒级出图。
struct RMBitmap {

    typealias RGB = (r: Float, g: Float, b: Float)

    // MARK: - 调色板

    static let palettes: [String: [RGB]] = [
        "青蓝": [(0.05, 0.16, 0.28), (0.10, 0.42, 0.55), (0.18, 0.72, 0.78), (0.78, 0.95, 0.98)],
        "日落": [(0.35, 0.06, 0.18), (0.72, 0.20, 0.24), (0.95, 0.55, 0.25), (1.00, 0.90, 0.70)],
        "紫金": [(0.12, 0.06, 0.28), (0.36, 0.16, 0.55), (0.72, 0.42, 0.80), (0.98, 0.82, 0.45)],
        "墨绿": [(0.03, 0.12, 0.10), (0.10, 0.34, 0.26), (0.28, 0.66, 0.44), (0.85, 0.95, 0.80)],
        "暖灰": [(0.10, 0.10, 0.11), (0.30, 0.30, 0.32), (0.55, 0.55, 0.57), (0.88, 0.88, 0.90)]
    ]

    enum Style: Int, CaseIterable {
        case nebula, ridge, wave, grid
        var name: String {
            switch self {
            case .nebula: return "星云"
            case .ridge:  return "山脊"
            case .wave:   return "波纹"
            case .grid:   return "网格"
            }
        }
    }

    // MARK: - 主入口

    /// 生成一张图。referencing 有值就是 img2img（参考图基础上改）。
    static func render(size: Int = 512, seed: UInt64, style: Style,
                       paletteName: String, referencing img: UIImage?) -> UIImage? {
        let small = 180
        var buf = [UInt8](repeating: 0, count: small * small * 4)

        // 参考图取色底子
        var refLum = [Float](repeating: -1, count: small * small)
        var refRGB = [RGB](repeating: (0, 0, 0), count: small * small)
        if let img = img, let cg = img.cgImage {
            drawReference(cg, into: &refLum, &refRGB, size: small)
        }

        let pal = palettes[paletteName] ?? palettes["青蓝"]!
        let hasRef = img != nil

        var s = seed == 0 ? 0x2545F4914F6CDD1D : seed
        let nX = Double(small)

        for y in 0..<small {
            for x in 0..<small {
                let i = y * small + x
                let u = Double(x) / nX
                let v = Double(y) / nX

                // 位置噪声（贴图坐标会随 seed 偏一点，图就不一样）
                s = next(&s)
                let ox = Double(Int(s % 64)) * 0.9 - 28.0
                s = next(&s)
                let oy = Double(Int(s % 64)) * 0.9 - 28.0

                var f1 = fbm(x: Double(x) + ox, y: Double(y) + oy, seed: seed, octaves: 5)
                var f2 = fbm(x: Double(x) * 2.0 + ox, y: Double(y) * 2.0 + oy, seed: seed ^ 0x9E37, octaves: 4)

                // 构图调制
                var shape: Double = 0.5
                switch style {
                case .nebula:
                    let dx = u - 0.5, dy = v - 0.5
                    shape = 1.0 - min(1.0, sqrt(dx * dx + dy * dy) * 2.2)
                    shape = shape * 0.6 + f1 * 0.4
                case .ridge:
                    let h = 0.35 + 0.30 * Double(f1)
                    shape = v > h ? 0.25 : 1.0
                    shape = shape * 0.75 + f2 * 0.25
                case .wave:
                    shape = 0.5 + 0.5 * sin((u * 7.0 + f1 * 2.2) * Double.pi)
                    shape = shape * 0.8 + v * 0.2
                case .grid:
                    let gx = abs((u * 9.0) - ((u * 9.0).rounded()))
                    let gy = abs((v * 9.0) - ((v * 9.0).rounded()))
                    let line = max(0.0, 1.0 - (min(gx, gy) * 26.0))
                    shape = 0.35 + line * 0.5 + f1 * 0.25
                }

                f1 = min(1.0, max(0.0, f1))
                f2 = min(1.0, max(0.0, f2))
                var t = min(1.0, max(0.0, shape * 0.75 + f2 * 0.35))

                var col: RGB
                if hasRef {
                    // img2img：保留参考图颜色，噪声只动明暗和细节
                    let base = refRGB[i]
                    let lum0: Float = refLum[i] >= 0 ? refLum[i] : Float(t)
                    let detail: Double = 0.55 + f1 * 0.5 - 0.25
                    let bright: Float = Float(min(1.4, max(0.15, Double(lum0) * detail + (t - 0.5) * 0.35)))
                    col = (base.r * bright, base.g * bright, base.b * bright)
                    // 叠一点调色板的环境色，免得看过去还是原图
                    let pIdx = Int(min(pal.count - 1, Int(t * Double(pal.count - 1))))
                    let p = pal[pIdx]
                    let mix: Float = 0.30
                    col = (col.r * (1 - mix) + p.r * mix,
                           col.g * (1 - mix) + p.g * mix,
                           col.b * (1 - mix) + p.b * mix)
                } else {
                    let pIdx = Int(min(pal.count - 1, Int(t * Double(pal.count - 1))))
                    let p0 = pal[pIdx]
                    let p1 = pal[min(pal.count - 1, pIdx + 1)]
                    let frac = Double(t * Double(pal.count - 1)) - Double(pIdx)
                    col = (Float(lerp(Double(p0.r), Double(p1.r), frac)),
                           Float(lerp(Double(p0.g), Double(p1.g), frac)),
                           Float(lerp(Double(p0.b), Double(p1.b), frac)))
                }

                let o = i * 4
                buf[o]     = UInt8(max(0, min(255, Int(col.r * 255))))
                buf[o + 1] = UInt8(max(0, min(255, Int(col.g * 255))))
                buf[o + 2] = UInt8(max(0, min(255, Int(col.b * 255))))
                buf[o + 3] = 255
            }
        }

        guard let smallImg = drawBuffer(buf, size: small) else { return nil }
        return upscale(smallImg, to: size)
    }

    // MARK: - 噪声

    private static func next(_ s: inout UInt64) -> UInt64 {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        return s >> 33
    }

    private static func hash(_ x: Int, _ y: Int, _ seed: UInt64) -> Double {
        var h = UInt64(x) &* 374761393 &+ UInt64(y) &* 668265263 &+ seed
        h = (h ^ (h >> 13)) &* 1274126177
        h = h ^ (h >> 16)
        return Double(h & 0xFFFF) / 65535.0
    }

    private static func smooth(_ t: Double) -> Double {
        return t * t * t * (t * (t * 6 - 15) + 10)
    }

    private static func valueNoise(x: Double, y: Double, seed: UInt64) -> Double {
        let xi = Int(x), yi = Int(y)
        let xf = x - Double(xi), yf = y - Double(yi)
        let u = smooth(xf), v = smooth(yf)
        let a = hash(xi, yi, seed)
        let b = hash(xi + 1, yi, seed)
        let c = hash(xi, yi + 1, seed)
        let d = hash(xi + 1, yi + 1, seed)
        return lerp(lerp(a, b, u), lerp(c, d, u), v)
    }

    /// 分形噪声（fBm）
    private static func fbm(x: Double, y: Double, seed: UInt64, octaves: Int) -> Double {
        var amp = 0.5
        var freq = 1.0
        var sum = 0.0
        var norm = 0.0
        for i in 0..<octaves {
            sum += valueNoise(x: x * freq, y: y * freq, seed: seed &+ UInt64(i * 7919)) * amp
            norm += amp
            amp *= 0.5
            freq *= 2.05
        }
        return sum / max(norm, 0.0001)
    }

    private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

    // MARK: - 绘制

    private static func drawBuffer(_ buf: [UInt8], size: Int) -> UIImage? {
        guard let cg = cgFromBuffer(buf, size: size) else { return nil }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: size * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
        return ctx.makeImage().flatMap { UIImage(cgImage: $0) }
    }

    private static func cgFromBuffer(_ buf: [UInt8], size: Int) -> CGImage? {
        let cs = CGColorSpaceCreateDeviceRGB()
        let data = Data(buf)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: size * 4, space: cs,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }

    /// 小图放大（高质量插值，iPad 上非常快）
    private static func upscale(_ img: UIImage, to size: Int) -> UIImage? {
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        fmt.opaque = true
        fmt.preferredRange = .standard
        let rend = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: fmt)
        return rend.image { ctx in
            ctx.cgContext.imageInterpolationQuality = .high
            img.draw(in: CGRect(x: 0, y: 0, width: size, height: size))
        }
    }

    /// 把参考图缩到 small×small，取每点的亮度和颜色
    private static func drawReference(_ cg: CGImage, into lum: inout [Float],
                                      _ rgb: inout [RGB], size: Int) {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: size * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let out = ctx.makeImage(),
              let prov = out.dataProvider,
              let raw = prov.data as Data? else { return }
        raw.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            let b = p.baseAddress!
            for i in 0..<(size * size) {
                let o = i * 4
                let r = Float(b[o]) / 255.0
                let g = Float(b[o + 1]) / 255.0
                let bl = Float(b[o + 2]) / 255.0
                rgb[i] = (r, g, bl)
                lum[i] = 0.299 * r + 0.587 * g + 0.114 * bl
            }
        }
    }
}
