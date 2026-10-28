//  Renderer.swift — Layer 2 and the output transform on the GPU, for the canvas
//  and for export.
//
//  The chain is the Mac app's (`Exporter.filePixels`, `Renderer.applyLayer2`,
//  `applyOutputTransform`): the engine's ROMM-encoded print → `layer2` in the
//  working space → `outputTransform` into the destination, once. Textures
//  between the passes are RGBA16Unorm, as on the Mac, so nothing is quantised
//  to 8 bits before the very end.
//
//  The canvas's passes run on the main thread inside an MTKView draw; an
//  export runs on the engine's queue with textures of its own. Pipeline states
//  and the command queue are safe to share between the two.
//
//  The canvas keeps its Layer 2 and output-transform result and reruns them
//  only when the print, the adjustments or the transform change, so a pan or
//  a zoom costs one draw of a quad — which is what makes panning a
//  full-resolution 40 MP print smooth. Geometry, zoom and before/after are the
//  quad's (`canvasFragment`); they never touch the cached pixels.

import CoreGraphics
import Metal
import MetalKit

/// What one run of the output transform did, beyond the pixels.
struct TransformStats {
    /// Pixels the destination could not hold (chroma past its gamut at that
    /// lightness and hue, before the roll-off) — the honest "how much did the
    /// conversion change this picture".
    let outsideFraction: Double
    /// Pixels at or past 0 or 1 after encoding: detail the container took.
    let clippedFraction: Double
}

/// Must match `CanvasUniforms` in Canvas.metal, field for field and in order.
/// Pairs first, then scalars, then the geometry block (8-byte aligned at 56).
struct CanvasUniforms {
    var viewportSize = SIMD2<Float>(1, 1)
    var imageSize = SIMD2<Float>(1, 1)
    var offset = SIMD2<Float>(0, 0)
    var pivot = SIMD2<Float>(0.5, 0.5)
    var scale: Float = 1
    var surroundGray: Float = 0.16
    var magnification: Float = 0
    var compareSplit: Float = 0.5
    var compare: UInt32 = 0
    var editingCrop: UInt32 = 0
    var geometry = Geometry.Uniform()
}

final class Renderer: @unchecked Sendable {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// The drawable: half-float, as the Mac canvas uses, tagged Display P3.
    static let drawableFormat: MTLPixelFormat = .rgba16Float

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let layer2State: MTLComputePipelineState
    private let transformState: MTLComputePipelineState
    private let geometryState: MTLComputePipelineState
    private let canvasState: MTLRenderPipelineState

    // The canvas's intermediates, reused while the picture's size is the same.
    // Main thread only.
    private var canvasAdjusted: MTLTexture?
    private var canvasDisplay: MTLTexture?
    private var canvasStats: MTLBuffer?
    /// What `canvasDisplay` was made from, so an unchanged picture is not
    /// converted again: the print, the adjustments' bytes, the transform.
    private var cachedSource: ObjectIdentifier?
    private var cachedAdjustments: Data?
    private var cachedTransform: ObjectIdentifier?

    init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let layer2 = library.makeFunction(name: "layer2"),
              let transform = library.makeFunction(name: "outputTransform"),
              let geometry = library.makeFunction(name: "geometryResample"),
              let vertex = library.makeFunction(name: "canvasVertex"),
              let fragment = library.makeFunction(name: "canvasFragment")
        else { throw Failure(description: "the canvas shaders are missing from the app") }
        // The two layouts the shaders read; a mismatch draws the wrong part of
        // the frame and says nothing.
        precondition(MemoryLayout<Geometry.Uniform>.stride == 48)
        precondition(MemoryLayout<CanvasUniforms>.offset(of: \.geometry) == 56
                     && MemoryLayout<CanvasUniforms>.stride == 104)
        self.queue = queue
        layer2State = try device.makeComputePipelineState(function: layer2)
        transformState = try device.makeComputePipelineState(function: transform)
        geometryState = try device.makeComputePipelineState(function: geometry)
        let pipeline = MTLRenderPipelineDescriptor()
        pipeline.vertexFunction = vertex
        pipeline.fragmentFunction = fragment
        pipeline.colorAttachments[0].pixelFormat = Renderer.drawableFormat
        canvasState = try device.makeRenderPipelineState(descriptor: pipeline)
    }

    func makeTexture(width: Int, height: Int, storage: MTLStorageMode) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Unorm, width: width,
                                                         height: height, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = storage
        return device.makeTexture(descriptor: d)
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, _ state: MTLComputePipelineState,
                          width: Int, height: Int) {
        let w = state.threadExecutionWidth
        let h = max(1, state.maxTotalThreadsPerThreadgroup / w)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
    }

    private func encodeLayer2(_ buffer: MTLCommandBuffer, source: MTLTexture, into target: MTLTexture,
                              uniforms: Layer2Uniforms) {
        guard let encoder = buffer.makeComputeCommandEncoder() else { return }
        var u = uniforms
        encoder.setComputePipelineState(layer2State)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(target, index: 1)
        encoder.setBytes(&u, length: MemoryLayout<Layer2Uniforms>.stride, index: 0)
        dispatch(encoder, layer2State, width: target.width, height: target.height)
        encoder.endEncoding()
    }

    private func encodeTransform(_ buffer: MTLCommandBuffer, source: MTLTexture, into target: MTLTexture,
                                 transform: ColourTransform, stats: MTLBuffer) {
        guard let encoder = buffer.makeComputeCommandEncoder() else { return }
        var u = transform.uniforms
        encoder.setComputePipelineState(transformState)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(target, index: 1)
        encoder.setBytes(&u, length: MemoryLayout<OutputTransformUniforms>.stride, index: 0)
        encoder.setBuffer(transform.cmax, offset: 0, index: 1)
        encoder.setBuffer(stats, offset: 0, index: 2)
        dispatch(encoder, transformState, width: target.width, height: target.height)
        encoder.endEncoding()
    }

    private func makeStatsBuffer() -> MTLBuffer? {
        guard let stats = device.makeBuffer(length: 3 * MemoryLayout<UInt32>.size, options: .storageModeShared)
        else { return nil }
        memset(stats.contents(), 0, stats.length)
        return stats
    }

    // MARK: the canvas

    /// Draws `print` with `adjustments`, converted to Display P3, placed by
    /// `canvas` (zoom, pan, geometry, before/after). `before` is already in
    /// Display P3. Main thread.
    ///
    /// `enlarger`, while a film or paper change is showing: the canvas is
    /// copied into its `from` on the first draw after the change — before the
    /// new print exists, so the copy is the old picture — and the shader
    /// composites the negative, the light and the new print.
    func drawCanvas(in view: MTKView, print: MTLTexture?, before: MTLTexture?,
                    adjustments: Layer2Uniforms, transform: ColourTransform?, canvas: CanvasUniforms,
                    enlarger: EnlargerTransition? = nil) {
        guard let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor,
              let buffer = queue.makeCommandBuffer() else { return }
        let shown = print.flatMap { print in
            transform.flatMap { converted(print, adjustments: adjustments, transform: $0, buffer: buffer) }
        }
        var e = enlarger?.uniforms() ?? EnlargerUniforms()
        if let enlarger, let shown, e.active != 0, enlarger.wantsSnapshot {
            snapshot(shown, into: enlarger, buffer: buffer)
        }
        if e.active != 0 && enlarger?.from == nil { e.active = 0 }
        if let shown, let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) {
            var u = canvas
            if before == nil { u.compare = 0 }
            encoder.setRenderPipelineState(canvasState)
            encoder.setFragmentTexture(shown, index: 0)
            encoder.setFragmentTexture(before ?? shown, index: 1)
            encoder.setFragmentTexture(enlarger?.from ?? shown, index: 2)
            encoder.setFragmentBytes(&u, length: MemoryLayout<CanvasUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&e, length: MemoryLayout<EnlargerUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            encoder.endEncoding()
        } else if let clear = buffer.makeRenderCommandEncoder(descriptor: pass) {
            clear.endEncoding()
        }
        buffer.present(drawable)
        buffer.commit()
    }

    /// Copies the canvas's picture into the enlarger's `from`, made at the
    /// picture's own size (the preview, or the full print while zoomed).
    private func snapshot(_ shown: MTLTexture, into enlarger: EnlargerTransition, buffer: MTLCommandBuffer) {
        if enlarger.from?.width != shown.width || enlarger.from?.height != shown.height {
            enlarger.from = makeTexture(width: shown.width, height: shown.height, storage: .private)
        }
        guard let from = enlarger.from, let blit = buffer.makeBlitCommandEncoder() else { return }
        blit.copy(from: shown, to: from)
        blit.endEncoding()
        enlarger.snapshotTaken()
    }

    /// The canvas's Display P3 picture of `print`: the cached one when nothing
    /// it depends on changed, else Layer 2 and the transform encoded into
    /// `buffer` now.
    private func converted(_ print: MTLTexture, adjustments: Layer2Uniforms, transform: ColourTransform,
                           buffer: MTLCommandBuffer) -> MTLTexture? {
        var a = adjustments
        let bytes = Data(bytes: &a, count: MemoryLayout<Layer2Uniforms>.size)
        if canvasAdjusted?.width != print.width || canvasAdjusted?.height != print.height {
            canvasAdjusted = makeTexture(width: print.width, height: print.height, storage: .private)
            canvasDisplay = makeTexture(width: print.width, height: print.height, storage: .private)
            cachedSource = nil
        }
        if canvasStats == nil { canvasStats = makeStatsBuffer() }
        guard let adjusted = canvasAdjusted, let shown = canvasDisplay, let stats = canvasStats else { return nil }
        let source = ObjectIdentifier(print), made = ObjectIdentifier(transform.cmax)
        if cachedSource != source || cachedAdjustments != bytes || cachedTransform != made {
            encodeLayer2(buffer, source: print, into: adjusted, uniforms: adjustments)
            encodeTransform(buffer, source: adjusted, into: shown, transform: transform, stats: stats)
            cachedSource = source
            cachedAdjustments = bytes
            cachedTransform = made
        }
        return shown
    }

    // MARK: export

    /// Layer 2, the output transform and then the geometry (crop, straighten,
    /// quarter turns, flips) — the Mac's `geometryResample`, the canvas's own
    /// `geometryMap` — into a CPU-readable texture of the output's size.
    /// Blocks until the GPU is done. Any thread.
    func finish(print: MTLTexture, uniforms: Layer2Uniforms, transform: ColourTransform,
                geometry: Geometry = .default) throws -> (texture: MTLTexture, stats: TransformStats) {
        let cut = !geometry.isIdentity
        let size = geometry.outputSize(for: CGSize(width: print.width, height: print.height))
        let outW = cut ? Int(size.width) : print.width, outH = cut ? Int(size.height) : print.height
        guard let adjusted = makeTexture(width: print.width, height: print.height, storage: .private),
              let converted = makeTexture(width: print.width, height: print.height,
                                          storage: cut ? .private : .shared),
              let output = cut ? makeTexture(width: outW, height: outH, storage: .shared) : converted,
              let stats = makeStatsBuffer(),
              let buffer = queue.makeCommandBuffer()
        else { throw Failure(description: "not enough GPU memory for a \(print.width) × \(print.height) export") }
        encodeLayer2(buffer, source: print, into: adjusted, uniforms: uniforms)
        encodeTransform(buffer, source: adjusted, into: converted, transform: transform, stats: stats)
        if cut, let encoder = buffer.makeComputeCommandEncoder() {
            var g = geometry.uniform(for: CGSize(width: print.width, height: print.height))
            encoder.setComputePipelineState(geometryState)
            encoder.setTexture(converted, index: 0)
            encoder.setTexture(output, index: 1)
            encoder.setBytes(&g, length: MemoryLayout<Geometry.Uniform>.stride, index: 0)
            dispatch(encoder, geometryState, width: outW, height: outH)
            encoder.endEncoding()
        }
        buffer.commit()
        buffer.waitUntilCompleted()
        if let error = buffer.error { throw Failure(description: "the GPU failed: \(error.localizedDescription)") }
        let counts = stats.contents().bindMemory(to: UInt32.self, capacity: 3)
        let total = Double(print.width * print.height)
        return (output, TransformStats(outsideFraction: Double(counts[2]) / total,
                                          clippedFraction: Double(counts[1]) / total))
    }

    /// A 16-bit `CGImage` of an RGBA16Unorm texture, tagged `space` — the Mac
    /// app's `MTLTexture.makeCGImage(space:)`. The tag says what the numbers
    /// already are; nothing is converted here.
    static func makeCGImage(_ texture: MTLTexture, space: CGColorSpace) -> CGImage? {
        guard texture.pixelFormat == .rgba16Unorm else { return nil }
        let bytesPerRow = texture.width * 8
        var data = Data(count: bytesPerRow * texture.height)
        data.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!, bytesPerRow: bytesPerRow,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: texture.width, height: texture.height, bitsPerComponent: 16, bitsPerPixel: 64,
                       bytesPerRow: bytesPerRow, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue
                                                | CGBitmapInfo.byteOrder16Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
