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
    private let displayState: MTLRenderPipelineState

    // The canvas's intermediates, reused while the picture's size is the same.
    // Main thread only.
    private var canvasAdjusted: MTLTexture?
    private var canvasDisplay: MTLTexture?
    private var canvasStats: MTLBuffer?

    init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let layer2 = library.makeFunction(name: "layer2"),
              let transform = library.makeFunction(name: "outputTransform"),
              let vertex = library.makeFunction(name: "displayVertex"),
              let fragment = library.makeFunction(name: "displayFragment")
        else { throw Failure(description: "the canvas shaders are missing from the app") }
        self.queue = queue
        layer2State = try device.makeComputePipelineState(function: layer2)
        transformState = try device.makeComputePipelineState(function: transform)
        let pipeline = MTLRenderPipelineDescriptor()
        pipeline.vertexFunction = vertex
        pipeline.fragmentFunction = fragment
        pipeline.colorAttachments[0].pixelFormat = Renderer.drawableFormat
        displayState = try device.makeRenderPipelineState(descriptor: pipeline)
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

    /// Draws `print` with `adjustments`, converted to Display P3, letterboxed
    /// into `view`. Main thread.
    func drawCanvas(in view: MTKView, print: MTLTexture?, uniforms: Layer2Uniforms,
                    transform: ColourTransform?) {
        guard let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor,
              let buffer = queue.makeCommandBuffer() else { return }
        if let print, let transform {
            if canvasAdjusted?.width != print.width || canvasAdjusted?.height != print.height {
                canvasAdjusted = makeTexture(width: print.width, height: print.height, storage: .private)
                canvasDisplay = makeTexture(width: print.width, height: print.height, storage: .private)
            }
            if canvasStats == nil { canvasStats = makeStatsBuffer() }
            if let adjusted = canvasAdjusted, let shown = canvasDisplay, let stats = canvasStats {
                encodeLayer2(buffer, source: print, into: adjusted, uniforms: uniforms)
                encodeTransform(buffer, source: adjusted, into: shown, transform: transform, stats: stats)
                drawQuad(buffer, pass: pass, picture: shown, drawableSize: view.drawableSize)
            }
        } else if let clear = buffer.makeRenderCommandEncoder(descriptor: pass) {
            clear.endEncoding()
        }
        buffer.present(drawable)
        buffer.commit()
    }

    private func drawQuad(_ buffer: MTLCommandBuffer, pass: MTLRenderPassDescriptor, picture: MTLTexture,
                          drawableSize: CGSize) {
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        // Aspect-fit the picture inside the drawable, in NDC (left, bottom, right, top).
        let viewAspect = Double(drawableSize.width / max(drawableSize.height, 1))
        let picAspect = Double(picture.width) / Double(max(picture.height, 1))
        var halfW = 1.0, halfH = 1.0
        if picAspect > viewAspect { halfH = viewAspect / picAspect } else { halfW = picAspect / viewAspect }
        var rect = SIMD4<Float>(Float(-halfW), Float(-halfH), Float(halfW), Float(halfH))
        encoder.setRenderPipelineState(displayState)
        encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setFragmentTexture(picture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }

    // MARK: export

    /// Layer 2 then the output transform at the print's own size, into a
    /// CPU-readable texture. Blocks until the GPU is done. Any thread.
    func finish(print: MTLTexture, uniforms: Layer2Uniforms,
                transform: ColourTransform) throws -> (texture: MTLTexture, stats: TransformStats) {
        guard let adjusted = makeTexture(width: print.width, height: print.height, storage: .private),
              let converted = makeTexture(width: print.width, height: print.height, storage: .shared),
              let stats = makeStatsBuffer(),
              let buffer = queue.makeCommandBuffer()
        else { throw Failure(description: "not enough GPU memory for a \(print.width) × \(print.height) export") }
        encodeLayer2(buffer, source: print, into: adjusted, uniforms: uniforms)
        encodeTransform(buffer, source: adjusted, into: converted, transform: transform, stats: stats)
        buffer.commit()
        buffer.waitUntilCompleted()
        if let error = buffer.error { throw Failure(description: "the GPU failed: \(error.localizedDescription)") }
        let counts = stats.contents().bindMemory(to: UInt32.self, capacity: 3)
        let total = Double(print.width * print.height)
        return (converted, TransformStats(outsideFraction: Double(counts[2]) / total,
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
