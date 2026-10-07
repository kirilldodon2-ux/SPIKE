import AppKit

// Sample only the supplied local Now Playing image. No audio or network input.
struct ArtworkPalette: Sendable {
    let primary: SIMD3<Float>
    let secondary: SIMD3<Float>

    static func extract(_ image: NSImage) -> ArtworkPalette? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let size = 32
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let drawn = pixels.withUnsafeMutableBytes { memory -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: memory.baseAddress, width: size, height: size,
                    bitsPerComponent: 8, bytesPerRow: size * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        guard drawn else { return nil }
        // Small RGB histogram: frequency wins; saturation gently favors cover accents.
        var counts = [Int](repeating: 0, count: 512)
        var sums = [SIMD3<Float>](repeating: .zero, count: 512)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Float(pixels[i + 3]) / 255
            guard alpha > 0.5 else { continue }
            let rgb = SIMD3(Float(pixels[i]), Float(pixels[i + 1]), Float(pixels[i + 2])) / (255 * alpha)
            let bucket = min(7, Int(rgb.x * 8)) * 64 + min(7, Int(rgb.y * 8)) * 8 + min(7, Int(rgb.z * 8))
            counts[bucket] += 1
            sums[bucket] += rgb
        }
        let candidates = counts.indices.filter { counts[$0] > 0 }.map { index in
            let rgb = sums[index] / Float(counts[index])
            let top = max(rgb.x, max(rgb.y, rgb.z)), low = min(rgb.x, min(rgb.y, rgb.z))
            let saturation = top > 0 ? (top - low) / top : 0
            return (rgb: rgb, score: Float(counts[index]) * (0.5 + saturation))
        }.sorted { $0.score > $1.score }
        guard let first = candidates.first else { return nil }
        let second = candidates.first { candidate in
            let delta = candidate.rgb - first.rgb
            return delta.x * delta.x + delta.y * delta.y + delta.z * delta.z > 0.09
        }?.rgb ?? first.rgb
        return ArtworkPalette(primary: visible(first.rgb), secondary: visible(second))
    }

    static func luminance(_ rgb: SIMD3<Float>) -> Float {
        func linear(_ value: Float) -> Float {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return linear(rgb.x) * 0.2126 + linear(rgb.y) * 0.7152 + linear(rgb.z) * 0.0722
    }

    private static func visible(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        // Keep the sampled hue, lifting dark colors toward white until their
        // full-coverage contrast against #000 is at least 4.6:1. Glyph edges fade.
        var low: Float = 0, high: Float = 1
        if luminance(rgb) >= 0.18 { return rgb }
        for _ in 0..<14 {
            let amount = (low + high) / 2
            let color = rgb + (SIMD3<Float>(repeating: 1) - rgb) * amount
            if luminance(color) < 0.18 { low = amount } else { high = amount }
        }
        return rgb + (SIMD3<Float>(repeating: 1) - rgb) * high
    }
}

func checkArtworkPalette() {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8,
        bytesPerRow: 128, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.16, green: 0.01, blue: 0.02, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 20, height: 32))
    context.setFillColor(CGColor(red: 0.01, green: 0.04, blue: 0.4, alpha: 1))
    context.fill(CGRect(x: 20, y: 0, width: 12, height: 32))
    let palette = ArtworkPalette.extract(NSImage(cgImage: context.makeImage()!, size: NSSize(width: 32, height: 32)))!
    precondition(palette.primary.x > palette.primary.z && palette.secondary.z > palette.secondary.x)
    precondition(ArtworkPalette.luminance(palette.primary) >= 0.18 && ArtworkPalette.luminance(palette.secondary) >= 0.18)
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
    let mono = ArtworkPalette.extract(NSImage(cgImage: context.makeImage()!, size: NSSize(width: 32, height: 32)))!
    precondition(mono.primary == mono.secondary && mono.primary.x == mono.primary.y)
    print("Artwork palette checks passed: cover colors, dark-color contrast, monochrome")
}
