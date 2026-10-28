//  CanvasView.swift — the picture on screen: an MTKView tagged Display P3.
//
//  Draws on demand (`isPaused` + `enableSetNeedsDisplay`, as the Mac canvas
//  does), so a still picture costs nothing and a slider costs one Layer 2 and
//  one output-transform pass at the preview's size per change.

import MetalKit
import SwiftUI

struct CanvasView: UIViewRepresentable {
    let renderer: Renderer
    /// The engine's live print (ROMM-encoded), or nil before a photo is open.
    let print: MTLTexture?
    let uniforms: Layer2Uniforms
    /// Working space → Display P3, from the engine.
    let transform: ColourTransform?

    func makeCoordinator() -> Coordinator { Coordinator(renderer: renderer) }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        view.delegate = context.coordinator
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.colorPixelFormat = Renderer.drawableFormat
        view.framebufferOnly = true
        // A neutral dark ground, as Display P3 code values.
        view.clearColor = MTLClearColor(red: 0.16, green: 0.16, blue: 0.16, alpha: 1)
        if let layer = view.layer as? CAMetalLayer {
            // The drawable holds Display P3 code values — `outputTransform` put
            // them there — so the tag says so and the system shows them as such.
            layer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
            layer.wantsExtendedDynamicRangeContent = false
        }
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.print = print
        context.coordinator.uniforms = uniforms
        context.coordinator.transform = transform
        view.setNeedsDisplay()
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        let renderer: Renderer
        var print: MTLTexture?
        var uniforms = Layer2Uniforms()
        var transform: ColourTransform?

        init(renderer: Renderer) { self.renderer = renderer }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { view.setNeedsDisplay() }

        func draw(in view: MTKView) {
            renderer.drawCanvas(in: view, print: print, uniforms: uniforms, transform: transform)
        }
    }
}
