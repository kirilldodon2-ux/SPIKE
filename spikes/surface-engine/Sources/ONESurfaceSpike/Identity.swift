import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct IdentityAsset: Sendable {
    let frames: [CGImage]
    let frameEnds: [TimeInterval]
    var isAnimated: Bool { frames.count > 1 }

    func frameIndex(elapsed: TimeInterval, reduceMotion: Bool) -> Int {
        guard isAnimated, !reduceMotion, let duration = frameEnds.last, duration > 0 else { return 0 }
        let position = max(0, elapsed).truncatingRemainder(dividingBy: duration)
        return frameEnds.firstIndex(where: { position < $0 }) ?? 0
    }
}

private struct IdentityError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

enum IdentityImages {
    static let maximumBytes = 16 * 1024 * 1024
    static let maximumFrames = 240

    static func load(_ url: URL) throws -> (Data, IdentityAsset) {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= maximumBytes else {
            throw IdentityError("Выберите PNG, JPEG или GIF до 16 МБ.")
        }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source),
              [UTType.png.identifier, UTType.jpeg.identifier, UTType.gif.identifier].contains(type as String)
        else { throw IdentityError("Не удалось прочитать картинку. Поддерживаются PNG, JPEG и GIF.") }
        let count = CGImageSourceGetCount(source)
        guard count > 0, count <= maximumFrames else {
            throw IdentityError("В GIF должно быть не больше 240 кадров. Выберите более короткую анимацию.")
        }
        var frames: [CGImage] = []
        var ends: [TimeInterval] = []
        var duration: TimeInterval = 0
        for index in 0..<count {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                  width.intValue > 0, height.intValue > 0,
                  width.intValue <= 4096, height.intValue <= 4096 else {
                throw IdentityError("Картинка слишком большая: максимум 4096 × 4096 пикселей.")
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 128,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
                throw IdentityError("Не удалось загрузить кадр картинки. Попробуйте другой файл.")
            }
            let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue ?? 0.1
            duration += delay.isFinite && delay >= 0.02 ? delay : 0.1
            frames.append(image)
            ends.append(duration)
        }
        return (data, IdentityAsset(frames: frames, frameEnds: ends))
    }

    static func store(source: URL, destination: URL) throws -> IdentityAsset {
        let (data, asset) = try load(source)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                               withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
        return asset
    }

    static func reset(_ destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
    }
}

@MainActor final class IdentityController: ObservableObject {
    @Published private(set) var asset: IdentityAsset?
    @Published private(set) var isLoading = false
    @Published private(set) var effect: IdentityEffect
    @Published private(set) var effectStrength: Double
    @Published var previewVisible = false
    private(set) var animationStarted = Date()
    private(set) var effectStarted = Date()
    private let storedURL: URL
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        effect = IdentityEffect(rawValue: defaults.string(forKey: "identity.effect") ?? "") ?? .pulse
        let savedStrength = defaults.object(forKey: "identity.effectStrength") as? Double ?? 0.2
        effectStrength = savedStrength.isFinite ? min(1, max(0, savedStrength)) : 0.2
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        storedURL = support.appendingPathComponent("local.one.surface-spike/identity-image")
        guard FileManager.default.fileExists(atPath: storedURL.path) else { return }
        isLoading = true
        let url = storedURL
        Task {
            do {
                let loaded = try await Task.detached(priority: .userInitiated) { try IdentityImages.load(url).1 }.value
                apply(loaded)
            } catch { showError(error) }
            isLoading = false
        }
    }

    func chooseImage() {
        guard !isLoading else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Выбрать"
        panel.message = "Ваша картинка или GIF для правого крыла SPIKE"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let source = panel.url else { return }
        isLoading = true
        let destination = storedURL
        Task {
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    try IdentityImages.store(source: source, destination: destination)
                }.value
                apply(loaded)
            } catch { showError(error) }
            isLoading = false
        }
    }

    func restoreLogo() {
        guard !isLoading else { return }
        do {
            try IdentityImages.reset(storedURL)
            asset = nil
        } catch { showError(error) }
    }

    func selectEffect(_ value: IdentityEffect) {
        guard effect != value else { return }
        effectStarted = Date()
        effect = value
        defaults.set(value.rawValue, forKey: "identity.effect")
    }

    func setEffectStrength(_ value: Double) {
        guard value.isFinite else { return }
        effectStrength = min(1, max(0, value))
        defaults.set(effectStrength, forKey: "identity.effectStrength")
    }

    private func apply(_ loaded: IdentityAsset) {
        animationStarted = Date()
        asset = loaded
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Не удалось сменить картинку SPIKE"
        alert.informativeText = error.localizedDescription
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

@MainActor func checkIdentityImages() {
    do {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func image(_ color: CGColor) -> CGImage {
            let context = CGContext(data: nil, width: 256, height: 128, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(color)
            context.fill(CGRect(x: 0, y: 0, width: 256, height: 128))
            return context.makeImage()!
        }
        let red = image(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        let blue = image(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        let gifURL = folder.appendingPathComponent("test.gif")
        let gif = CGImageDestinationCreateWithURL(gifURL as CFURL, UTType.gif.identifier as CFString, 2, nil)!
        CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for (frame, delay) in [(red, 0.1), (blue, 0.2)] {
            CGImageDestinationAddImage(gif, frame,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
        }
        precondition(CGImageDestinationFinalize(gif))
        let saved = folder.appendingPathComponent("support/identity-image")
        let asset = try IdentityImages.store(source: gifURL, destination: saved)
        precondition(asset.isAnimated && asset.frames.count == 2)
        precondition(asset.frames.allSatisfy { $0.width == 128 && $0.height == 64 })
        func color(_ image: CGImage) -> [UInt8] {
            var rgba = [UInt8](repeating: 0, count: 4)
            rgba.withUnsafeMutableBytes { bytes in
                let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                    bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            return rgba
        }
        let first = color(asset.frames[0]), second = color(asset.frames[1])
        precondition(first[0] > 200 && first[2] < 30 && second[2] > 200 && second[0] < 30)
        precondition(asset.frameIndex(elapsed: 0.05, reduceMotion: false) == 0)
        precondition(asset.frameIndex(elapsed: 0.15, reduceMotion: false) == 1)
        precondition(asset.frameIndex(elapsed: 0.35, reduceMotion: false) == 0)
        precondition(asset.frameIndex(elapsed: 0.15, reduceMotion: true) == 0)
        let original = try Data(contentsOf: saved)
        try FileManager.default.removeItem(at: gifURL)
        let restored = try IdentityImages.load(saved).1
        precondition(restored.frames.count == 2)
        let bad = folder.appendingPathComponent("bad.png")
        try Data("not an image".utf8).write(to: bad)
        do {
            _ = try IdentityImages.store(source: bad, destination: saved)
            fatalError("Invalid identity must not replace saved image")
        } catch {}
        let preserved = try Data(contentsOf: saved)
        precondition(preserved == original)
        for type in [UTType.png, .jpeg] {
            let url = folder.appendingPathComponent("static.\(type.preferredFilenameExtension!)")
            let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, red, nil)
            precondition(CGImageDestinationFinalize(destination))
            let loaded = try IdentityImages.load(url).1
            precondition(!loaded.isAnimated && loaded.frames[0].width == 128)
        }
        try IdentityImages.reset(saved)
        precondition(!FileManager.default.fileExists(atPath: saved.path))
        print("Identity checks passed: PNG/JPEG/GIF thumbnails, timing/loop/Reduce Motion, owned copy, invalid import preserves choice, reset.")
    } catch { fatalError("Identity check: \(error)") }
}
