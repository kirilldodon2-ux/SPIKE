import AppKit
import CoreText
import MetalKit
import SwiftUI

private struct FlowUniforms {
    var motion: SIMD4<Float> // dt, time, energy, bass
    var detail: SIMD4<Float> // mid, high, strength, decay
    var character: SIMD4<Float> = .zero // hue, onset, glyph character, transparent background
    var paletteA: SIMD4<Float> = .zero // cover RGB, available
    var paletteB: SIMD4<Float> = .zero // second cover RGB, reserved
    var surface: SIMD4<Float> = .zero // sRGB background, white/black ink polarity
}

@MainActor final class ASCIIFlowRenderer: NSObject, MTKViewDelegate {
    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let pipelines: [String: any MTLComputePipelineState]
    private let renderPipeline: any MTLRenderPipelineState
    private let atlas: any MTLTexture
    private var velocity: [any MTLTexture]
    private var dye: [any MTLTexture]
    private var pressure: [any MTLTexture]
    private let divergence: any MTLTexture
    private var failed = false
    private var previousTime: TimeInterval = 0
    private var elapsed: Float = 0
    private let inFlight = DispatchSemaphore(value: 2)
    var input = VisualAudioFrame()
    var strength: Float = 0.65
    var controller: AudioVisualController?
    var palette: ArtworkPalette?
    var appearance = SurfaceAppearance.black
    private var displayedPalette: ArtworkPalette?
    var failure: ((String) -> Void)?
    private(set) var gpuMilliseconds: Double = 0
    private(set) var framesDrawn = 0

    init(device: any MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw flowError("Metal queue недоступна") }
        self.queue = queue
        let url = Bundle.main.url(forResource: "ASCIIFlow", withExtension: "metal")
            ?? Bundle.module.url(forResource: "ASCIIFlow", withExtension: "metal")
        guard let url else { throw flowError("Shader ASCII Flow не найден") }
        let library = try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
        let names = ["flowAdvect", "flowForce", "flowDivergence", "flowPressure", "flowProject"]
        var pipelines: [String: any MTLComputePipelineState] = [:]
        for name in names {
            guard let function = library.makeFunction(name: name) else { throw flowError("Shader \(name) не найден") }
            pipelines[name] = try device.makeComputePipelineState(function: function)
        }
        self.pipelines = pipelines
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "flowVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "flowASCII")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        renderPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        func texture() throws -> any MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
                width: 96, height: 64, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .shared
            guard let texture = device.makeTexture(descriptor: descriptor) else { throw flowError("Flow texture недоступна") }
            let zeros = [Float](repeating: 0, count: 96 * 64 * 4)
            zeros.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, 96, 64),
                mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 96 * 16) }
            return texture
        }
        velocity = try [texture(), texture()]
        dye = try [texture(), texture()]
        pressure = try [texture(), texture()]
        divergence = try texture()
        atlas = try Self.makeAtlas(device: device)
        super.init()
    }

    private static func makeAtlas(device: any MTLDevice) throws -> any MTLTexture {
        let width = 720, height = 32
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { memory in
            guard let context = CGContext(data: memory.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw flowError("Glyph atlas недоступен")
            }
            let font = CTFontCreateWithName("Menlo" as CFString, 23, nil)
            for (i, character) in Array(" .:-=+*#%@" + " ·°oO0@#%8" + " /\\|<>[]{}").enumerated() {
                let text = NSAttributedString(string: String(character), attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): NSColor.white.cgColor
                ])
                context.textPosition = CGPoint(x: i * 24 + 5, y: 7)
                CTLineDraw(CTLineCreateWithAttributedString(text), context)
            }
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
            width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let atlas = device.makeTexture(descriptor: descriptor) else { throw flowError("Glyph texture недоступна") }
        bytes.withUnsafeBytes { atlas.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
            withBytes: $0.baseAddress!, bytesPerRow: width * 4) }
        return atlas
    }

    private func compute(_ name: String, _ textures: [any MTLTexture],
                         _ uniforms: FlowUniforms, in command: any MTLCommandBuffer) throws {
        guard let encoder = command.makeComputeCommandEncoder(), let pipeline = pipelines[name] else {
            throw flowError("Metal compute encoder недоступен")
        }
        encoder.setComputePipelineState(pipeline)
        for (i, texture) in textures.enumerated() { encoder.setTexture(texture, index: i) }
        var value = uniforms
        encoder.setBytes(&value, length: MemoryLayout<FlowUniforms>.stride, index: 0)
        encoder.dispatchThreads(MTLSize(width: 96, height: 64, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        encoder.endEncoding()
    }

    private func step(_ uniforms: FlowUniforms, in command: any MTLCommandBuffer) throws {
        var velocityUniforms = uniforms
        velocityUniforms.detail.w = 1.4
        try compute("flowAdvect", [velocity[0], velocity[0], velocity[1]], velocityUniforms, in: command)
        velocity.swapAt(0, 1)
        try compute("flowForce", [velocity[0], dye[0], velocity[1], dye[1]], uniforms, in: command)
        velocity.swapAt(0, 1); dye.swapAt(0, 1)
        try compute("flowDivergence", [velocity[0], divergence], uniforms, in: command)
        for _ in 0..<12 {
            try compute("flowPressure", [pressure[0], divergence, pressure[1]], uniforms, in: command)
            pressure.swapAt(0, 1)
        }
        try compute("flowProject", [velocity[0], pressure[0], velocity[1]], uniforms, in: command)
        velocity.swapAt(0, 1)
        var dyeUniforms = uniforms
        dyeUniforms.detail.w = 1.0
        try compute("flowAdvect", [dye[0], velocity[0], dye[1]], dyeUniforms, in: command)
        dye.swapAt(0, 1)
    }

    func resetClock() { previousTime = 0 }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { resetClock() }

    func draw(in view: MTKView) {
        guard !failed else { return }
        guard inFlight.wait(timeout: .now()) == .success else { return }
        guard let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor,
              let command = queue.makeCommandBuffer() else { inFlight.signal(); return }
        let time = ProcessInfo.processInfo.systemUptime
        let dt = Float(previousTime == 0 ? 1.0 / 30 : min(1.0 / 20, max(0.001, time - previousTime)))
        previousTime = time
        let frame = (controller?.frame ?? input).fresh(at: time)
        elapsed += dt * (0.25 + frame.energy * 0.8 + frame.bass * 0.6 + frame.onset * 2)
        let strength = controller?.strength ?? self.strength
        if let target = palette {
            let current = displayedPalette ?? target
            let blend = 1 - exp(-dt * 5)
            displayedPalette = ArtworkPalette(primary: current.primary + (target.primary - current.primary) * blend,
                secondary: current.secondary + (target.secondary - current.secondary) * blend)
        } else { displayedPalette = nil }
        let colors = displayedPalette
        var uniforms = FlowUniforms(motion: SIMD4(dt, elapsed, frame.energy, frame.bass),
            detail: SIMD4(frame.mid, frame.high, strength, 0),
            character: SIMD4(frame.hue, frame.onset, frame.character, appearance.needsClearCanvas ? 1 : 0),
            paletteA: colors.map { SIMD4($0.primary.x, $0.primary.y, $0.primary.z, 1) } ?? .zero,
            paletteB: colors.map { SIMD4($0.secondary.x, $0.secondary.y, $0.secondary.z, 0) } ?? .zero,
            surface: appearance.flowSurface)
        do { try step(uniforms, in: command) }
        catch {
            failed = true
            inFlight.signal()
            failure?(error.localizedDescription)
            return
        }
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            failed = true
            inFlight.signal()
            failure?("Metal render encoder недоступен")
            return
        }
        encoder.setRenderPipelineState(renderPipeline)
        encoder.setFragmentTexture(dye[0], index: 0)
        encoder.setFragmentTexture(atlas, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FlowUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        command.present(drawable)
        let semaphore = inFlight
        command.addCompletedHandler { [weak self] completed in
            semaphore.signal()
            let duration = (completed.gpuEndTime - completed.gpuStartTime) * 1000
            let error = completed.error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.gpuMilliseconds = duration
                self.framesDrawn += 1
                if let error { self.failed = true; self.failure?("Metal: \(error)") }
            }
        }
        command.commit()
    }

    // Offscreen deterministic check of real compute shaders, not subjective feel.
    func checkSimulation() throws {
        func simulate(energy: Float, steps: Int) throws -> Float {
            guard let command = queue.makeCommandBuffer() else { throw flowError("Test command unavailable") }
            for i in 0..<steps {
                let value = FlowUniforms(motion: SIMD4(1.0 / 30, Float(i) / 30, energy, energy),
                    detail: SIMD4(energy, 0, 0.65, 0))
                try step(value, in: command)
            }
            command.commit(); command.waitUntilCompleted()
            if let error = command.error { throw error }
            var data = [Float](repeating: 0, count: 96 * 64 * 4)
            data.withUnsafeMutableBytes { dye[0].getBytes($0.baseAddress!, bytesPerRow: 96 * 16,
                from: MTLRegionMake2D(0, 0, 96, 64), mipmapLevel: 0) }
            guard data.allSatisfy({ $0.isFinite && $0 >= 0 }) else { throw flowError("Invalid dye samples") }
            return stride(from: 0, to: data.count, by: 4).reduce(0) { $0 + data[$1] }
        }
        let silence = try simulate(energy: 0, steps: 2)
        let active = try simulate(energy: 0.7, steps: 30)
        let decay = try simulate(energy: 0, steps: 90)
        guard silence == 0, active > 10, decay < active * 0.35 else {
            throw flowError("Flow check failed: silence=\(silence) active=\(active) decay=\(decay)")
        }
        print("ASCII Flow Metal checks passed: silence=0, audio injects dye, pause dissipates; active=\(active) decay=\(decay)")
    }

    /// Read back real fragment output: colour changes must not leave a black tile.
    func checkAppearance() throws {
        let size = 140
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: size, height: size, mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor) else { throw flowError("Appearance target unavailable") }
        func render(_ appearance: SurfaceAppearance, density: Float,
                    palette: ArtworkPalette? = nil) throws -> [UInt8] {
            let field = [Float](repeating: density, count: 96 * 64 * 4)
            field.withUnsafeBytes { dye[0].replace(region: MTLRegionMake2D(0, 0, 96, 64),
                mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 96 * 16) }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = appearance.clearColor
            guard let command = queue.makeCommandBuffer(),
                  let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
                throw flowError("Appearance render unavailable")
            }
            var uniforms = FlowUniforms(motion: .zero, detail: SIMD4(0, 0, 0.65, 0),
                character: SIMD4(0.55, 0, 0.4, appearance.needsClearCanvas ? 1 : 0),
                paletteA: palette.map { SIMD4($0.primary.x, $0.primary.y, $0.primary.z, 1) } ?? .zero,
                paletteB: palette.map { SIMD4($0.secondary.x, $0.secondary.y, $0.secondary.z, 0) } ?? .zero,
                surface: appearance.flowSurface)
            encoder.setRenderPipelineState(renderPipeline)
            encoder.setFragmentTexture(dye[0], index: 0)
            encoder.setFragmentTexture(atlas, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FlowUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            command.commit(); command.waitUntilCompleted()
            if let error = command.error { throw error }
            var bytes = [UInt8](repeating: 0, count: size * size * 4)
            bytes.withUnsafeMutableBytes { target.getBytes($0.baseAddress!, bytesPerRow: size * 4,
                from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0) }
            return bytes
        }
        for rgb: SIMD3<Float> in [.zero, SIMD3(repeating: 1), SIMD3(0.25, 0.5, 0.8), SIMD3(repeating: 0.46)] {
            let appearance = SurfaceAppearance(backgroundRGB: rgb)
            let silence = try render(appearance, density: 0)
            let expected = [rgb.z, rgb.y, rgb.x].map { Int(($0 * 255).rounded()) }
            for i in stride(from: 0, to: silence.count, by: 4) {
                precondition((0..<3).allSatisfy { abs(Int(silence[i + $0]) - expected[$0]) <= 1 })
                precondition(silence[i + 3] == 255)
            }
            let active = try render(appearance, density: 0.8)
            let changed = stride(from: 0, to: active.count, by: 4).filter { i in
                (0..<3).contains { abs(Int(active[i + $0]) - expected[$0]) > 35 }
            }.count
            precondition(changed > 100, "Glyph ink vanished on \(rgb)")
            // The outer fade belongs to the same selected surface, also with audio.
            precondition((0..<3).allSatisfy { abs(Int(active[$0]) - expected[$0]) <= 1 })
            let transparent = SurfaceAppearance(backgroundRGB: rgb, isTransparent: true, opacity: 0)
            let empty = try render(transparent, density: 0)
            precondition(empty.allSatisfy { $0 == 0 }, "Silent transparent visual must be entirely clear")
            let glyphs = try render(transparent, density: 0.8)
            var visible = 0, clear = 0
            for i in stride(from: 0, to: glyphs.count, by: 4) {
                let alpha = glyphs[i + 3]
                precondition((0..<3).allSatisfy { Int(glyphs[i + $0]) <= Int(alpha) + 1 },
                             "Metal output must have premultiplied RGB")
                if alpha > 35 { visible += 1 }
                if alpha == 0 { clear += 1 }
            }
            precondition(visible > 100 && clear > 1000, "Transparent glyphs or clear background vanished")
        }
        // The manual colour remains saved, but Metal must clear to the resolved system background.
        for name: NSAppearance.Name in [.aqua, .darkAqua] {
            let colors = SurfaceSystemColors.resolve(for: NSAppearance(named: name)!)!
            var saved = SurfaceAppearance(backgroundRGB: SIMD3(1, 0.2, 0.5), isRainbow: true)
            saved.usesSystemColors = true
            let system = saved.resolvingSystemColors(colors)
            let expected = [colors.background.z, colors.background.y, colors.background.x]
                .map { Int(($0 * 255).rounded()) }
            for density: Float in [0, 0.8] {
                let frame = try render(system, density: density)
                precondition((0..<3).allSatisfy { abs(Int(frame[$0]) - expected[$0]) <= 1 },
                    "System visual must match the shell, including its outer fade")
                precondition(frame[3] == 255)
                if density == 0 {
                    for i in stride(from: 0, to: frame.count, by: 4) {
                        precondition((0..<3).allSatisfy { abs(Int(frame[i + $0]) - expected[$0]) <= 1 })
                    }
                }
            }
        }
        // Even an opaque Rainbow shell needs a clear visual to reveal the root gradient.
        for isTransparent in [false, true] {
            let rainbow = SurfaceAppearance(backgroundRGB: .zero, isTransparent: isTransparent,
                                            isRainbow: true)
            let empty = try render(rainbow, density: 0)
            precondition(empty.allSatisfy { $0 == 0 }, "Rainbow visual must not cover the gradient")
            let active = try render(rainbow, density: 0.8)
            var visible = 0, clear = 0
            for i in stride(from: 0, to: active.count, by: 4) {
                let alpha = active[i + 3]
                precondition((0..<3).allSatisfy { Int(active[i + $0]) <= Int(alpha) + 1 })
                if alpha > 35 { visible += 1 }
                if alpha == 0 { clear += 1 }
            }
            precondition(visible > 100 && clear > 1000)
        }
        // A neutral Glass shell must be visible through the entire empty stage.
        var glass = SurfaceAppearance.black
        glass.material = .glass
        let glassSilence = try render(glass, density: 0)
        precondition(glassSilence.allSatisfy { $0 == 0 }, "Glass visual must not leave a black tile")
        let glassActive = try render(glass, density: 0.8)
        let glassVisible = stride(from: 0, to: glassActive.count, by: 4).filter { glassActive[$0 + 3] > 35 }.count
        let glassClear = stride(from: 0, to: glassActive.count, by: 4).filter { glassActive[$0 + 3] == 0 }.count
        precondition(glassVisible > 100 && glassClear > 1000)
        for i in stride(from: 0, to: glassActive.count, by: 4) {
            precondition((0..<3).allSatisfy { Int(glassActive[i + $0]) <= Int(glassActive[i + 3]) + 1 })
        }
        // Regression: a white cover on pink must retain bright glyph cores,
        // rather than inheriting the black polarity of labels and controls.
        let pink = SurfaceAppearance(backgroundRGB: SIMD3(0.843137, 0.492925, 0.649659),
                                     isTransparent: true, opacity: 0)
        let whiteCover = ArtworkPalette(primary: SIMD3(repeating: 1), secondary: SIMD3(repeating: 1))
        let whiteGlyphs = try render(pink, density: 0.8, palette: whiteCover)
        let brightCores = stride(from: 0, to: whiteGlyphs.count, by: 4).filter { i in
            let alpha = Float(whiteGlyphs[i + 3])
            return alpha > 90 && (0..<3).allSatisfy { Float(whiteGlyphs[i + $0]) / alpha > 0.7 }
        }.count
        precondition(brightCores > 100, "A white cover must not turn into black ASCII on pink")
        let contrastCores = stride(from: 0, to: whiteGlyphs.count, by: 4).filter { i in
            let x = Float((i / 4) % size) / Float(size)
            let alpha = Float(whiteGlyphs[i + 3])
            guard (0.63...0.67).contains(x), alpha > 90 else { return false }
            let rgb = SIMD3(Float(whiteGlyphs[i + 2]), Float(whiteGlyphs[i + 1]),
                            Float(whiteGlyphs[i])) / alpha
            return SurfaceAppearance.contrast(rgb, pink.backgroundRGB) >= 4.3
        }.count
        precondition(contrastCores > 20, "The gradient must include a contrasting anchor on pink")
        print("Appearance Metal checks passed: solid/system-light-dark/transparent/Rainbow/Glass silent+active frames, clear glyph canvas, premultiplication, white-cover colour retention and contrasting gradient anchor")
    }
}

private func flowError(_ message: String) -> NSError {
    NSError(domain: "ONE.ASCIIFlow", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

private final class SurfaceFlowView: MTKView {
    override var isOpaque: Bool { false }
}

struct ASCIIFlowCanvas: NSViewRepresentable {
    @ObservedObject var controller: AudioVisualController
    let active: Bool
    let palette: ArtworkPalette?
    @Environment(\.surfaceAppearance) private var appearance
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var renderer: ASCIIFlowRenderer? }

    func makeNSView(context: Context) -> MTKView {
        let view = SurfaceFlowView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.clearColor = appearance.clearColor
        view.layer?.isOpaque = !appearance.needsClearCanvas
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 30
        view.isPaused = true
        do {
            guard let device = view.device else { throw flowError("Metal недоступен") }
            let renderer = try ASCIIFlowRenderer(device: device)
            renderer.controller = controller
            renderer.palette = palette
            renderer.appearance = appearance
            renderer.failure = { [weak controller] message in controller?.rendererFailed(message) }
            context.coordinator.renderer = renderer
            view.delegate = renderer
        } catch {
            let message = "ASCII Flow недоступен: \(error.localizedDescription)"
            Task { @MainActor in controller.rendererFailed(message) }
        }
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        let renderer = context.coordinator.renderer
        let colorChanged = renderer?.appearance != appearance
        renderer?.palette = palette
        renderer?.appearance = appearance
        view.clearColor = appearance.clearColor
        view.layer?.isOpaque = !appearance.needsClearCanvas
        let running = active && controller.enabled && renderer != nil
        if view.isPaused == running { renderer?.resetClock() }
        view.isPaused = !running
        if colorChanged && view.isPaused { view.draw() }
    }

    static func dismantleNSView(_ view: MTKView, coordinator: Coordinator) {
        view.isPaused = true
        view.delegate = nil
        coordinator.renderer = nil
    }
}

struct AudioVisualStage: View {
    @ObservedObject var controller: AudioVisualController
    let active: Bool
    var palette: ArtworkPalette? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.surfaceAppearance) private var appearance
    var body: some View {
        ZStack {
            if !appearance.needsClearCanvas { appearance.surface }
            if !reduceMotion {
                ASCIIFlowCanvas(controller: controller, active: active, palette: palette)
            }
        }
        .frame(width: SurfaceLayout.mediaTileSize, height: SurfaceLayout.mediaTileSize)
        .clipShape(RoundedRectangle(cornerRadius: SurfaceLayout.mediaTileCornerRadius, style: .continuous))
        .surfaceInkLegibility()
        .accessibilityLabel("Аудиореактивный поток")
    }
}

private extension SurfaceAppearance {
    var flowSurface: SIMD4<Float> {
        SIMD4(contrastRGB.x, contrastRGB.y, contrastRGB.z, usesLightInk ? 1 : 0)
    }
    var clearColor: MTLClearColor {
        if needsClearCanvas { return MTLClearColorMake(0, 0, 0, 0) }
        return MTLClearColorMake(Double(contrastRGB.x), Double(contrastRGB.y), Double(contrastRGB.z), 1)
    }
}

struct VisualSettingsView: View {
    @ObservedObject var controller: AudioVisualController
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Аудиореактивный визуал").font(.system(size: 14, weight: .medium))
            HStack {
                Text("Интенсивность").font(.system(size: 12))
                Spacer()
                Text("\(Int(controller.strength * 100))%")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            Slider(value: $controller.strength, in: 0...1).tint(.mint)
                .accessibilityLabel("Интенсивность визуала")
            if let diagnostic = controller.diagnostic {
                Text(diagnostic).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(22).frame(width: 280)
        .environment(\.colorScheme, .dark)
    }
}

@MainActor func checkASCIIFlow() {
    do {
        guard let device = MTLCreateSystemDefaultDevice() else { throw flowError("Metal device unavailable") }
        let renderer = try ASCIIFlowRenderer(device: device)
        try renderer.checkSimulation()
        try renderer.checkAppearance()
    } catch { fatalError("ASCII Flow check: \(error)") }
}

@MainActor func checkASCIIFlowAppearance() {
    do {
        guard let device = MTLCreateSystemDefaultDevice() else { throw flowError("Metal недоступен") }
        try ASCIIFlowRenderer(device: device).checkAppearance()
    } catch { fatalError("Appearance Metal check failed: \(error)") }
}
