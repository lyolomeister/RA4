//  CanvasView.swift — the picture on screen, and what touching it does.
//
//  An MTKView tagged Display P3 that draws on demand (`isPaused` +
//  `enableSetNeedsDisplay`, as the Mac canvas does), with a transparent view
//  over it for the crop frame and the before/after divider. The canvas owns
//  every touch on the picture:
//
//  - **pinch** zooms about the fingers, from fit up to 400 %; **one finger**
//    pans once zoomed in. At fit a horizontal swipe is `onSwipe` (the next or
//    previous photo), so the two never compete;
//  - **double-tap** goes between fit and 100 % (one photo pixel per screen
//    pixel) at the tapped point; a **single tap** is `onTap`, or the white
//    balance eyedropper while it is armed;
//  - **touch and hold** shows the photograph without the film while held;
//  - with **before/after** on, the divider drags;
//  - while the **crop tool** is up (`model.cropping`), the whole frame shows,
//    turned under a level crop as in Capture One, and the handles drag.
//
//  Zooming in past what the live preview holds asks the model for the
//  full-resolution print once the hands have been still for a moment (the
//  Mac's "full when idle"), so 100 % shows real grain. The viewport lives here,
//  not in the model: a pan is sixty updates a second and the rest of the
//  interface has no reason to redraw for them.

import MetalKit
import SwiftUI

struct CanvasView: UIViewRepresentable {
    let renderer: Renderer
    private let model: ProbeModel
    private var onTap: (() -> Void)?
    private var onSwipe: ((_ forward: Bool) -> Void)?

    /// `onTap`: a single tap on the picture. `onSwipe`: a horizontal swipe at
    /// fit, `true` for the next photo (a swipe to the left).
    init(model: ProbeModel, renderer: Renderer, onTap: (() -> Void)? = nil,
         onSwipe: ((_ forward: Bool) -> Void)? = nil) {
        self.model = model
        self.renderer = renderer
        self.onTap = onTap
        self.onSwipe = onSwipe
    }

    func makeCoordinator() -> Coordinator { Coordinator(renderer: renderer) }

    func makeUIView(context: Context) -> CanvasHostView {
        let host = CanvasHostView(device: renderer.device)
        host.metal.delegate = context.coordinator
        context.coordinator.attach(to: host)
        // The enlarger transition animates by asking for frames; the Metal
        // view itself draws only when asked.
        model.enlarger.redraw = { [weak host] in host?.metal.setNeedsDisplay() }
        return host
    }

    func updateUIView(_ host: CanvasHostView, context: Context) {
        let c = context.coordinator
        c.model = model
        c.onTap = onTap
        c.onSwipe = onSwipe
        c.refresh()
    }

    // MARK: - the coordinator: viewport, gestures, drawing

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate, UIGestureRecognizerDelegate {
        let renderer: Renderer
        weak var model: ProbeModel?
        var onTap: (() -> Void)?
        var onSwipe: ((Bool) -> Void)?
        private weak var host: CanvasHostView?

        /// Screen pixels per output pixel; nil is "fit".
        private var zoom: Double?
        /// The point of the output (0…1 across it) at the middle of the view.
        private var centre = CGPoint(x: 0.5, y: 0.5)
        /// The photo and output size the viewport belongs to; a change fits again.
        private var viewKey = ""
        static let maxZoom = 4.0

        /// The crop being dragged, drawn and edited here and written to the
        /// model when the finger lifts: one undo step per drag.
        private var liveGeometry: Geometry?
        private var cropDrag: (handle: CropHandle, start: Geometry, startEdit: CGPoint)?
        private var draggingSplit = false
        private var compareSplit = 0.5
        private var holdingBefore = false
        private var pinchStart: (scale: Double, anchor: CGPoint)?
        private var fullTimer: Timer?

        /// The crop tool turns the photograph about its own middle.
        static let pivot = CGPoint(x: 0.5, y: 0.5)

        init(renderer: Renderer) { self.renderer = renderer }

        func attach(to host: CanvasHostView) {
            self.host = host
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
            let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
            pan.maximumNumberOfTouches = 1
            let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
            double.numberOfTapsRequired = 2
            let single = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            single.require(toFail: double)
            let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
            hold.minimumPressDuration = 0.35
            for g in [pinch, pan, double, single, hold] as [UIGestureRecognizer] {
                g.delegate = self
                host.addGestureRecognizer(g)
            }
            host.overlay.coordinator = self
        }

        func refresh() {
            host?.metal.setNeedsDisplay()
            host?.overlay.setNeedsDisplay()
        }

        // MARK: the layout of the moment

        /// Everything a draw and a touch need to agree on, in screen pixels.
        struct Layout {
            var viewSize: CGSize          // pixels
            var pointScale: CGFloat       // pixels per point
            var source: CGSize            // the frame's full-resolution size
            var geometry: Geometry
            var cropping: Bool
            var output: CGSize            // what `scale` multiplies: output (or source, cropping) pixels
            var scale: Double             // screen pixels per output pixel
            var fitScale: Double
            var offset: CGPoint           // where output (0, 0) is, pixels
            var editOrigin = CGPoint.zero // cropping: the edit point at offset

            var isZoomed: Bool { !cropping && scale > fitScale * 1.001 }

            /// A view point (in points) as 0…1 across the output — or, while
            /// cropping, as a point of edit space (normalised to the source).
            func picturePoint(_ p: CGPoint) -> CGPoint {
                CGPoint(x: (p.x * pointScale - offset.x) / (output.width * scale),
                        y: (p.y * pointScale - offset.y) / (output.height * scale))
            }

            /// The inverse, in points.
            func viewPoint(_ u: CGPoint) -> CGPoint {
                CGPoint(x: (offset.x + u.x * output.width * scale) / pointScale,
                        y: (offset.y + u.y * output.height * scale) / pointScale)
            }
        }

        private func layout() -> Layout? {
            guard let host else { return nil }
            let ps = host.metal.contentScaleFactor
            let view = CGSize(width: host.bounds.width * ps, height: host.bounds.height * ps)
            guard view.width > 0, view.height > 0 else { return nil }
            var source = model?.sourceSize ?? .zero
            if source.width <= 0 || source.height <= 0 {
                guard let t = model?.print else { return nil }
                source = CGSize(width: t.width, height: t.height)
            }
            let g = liveGeometry ?? model?.geometry ?? .default
            let cropping = model?.cropping ?? false
            if cropping {
                // The whole photograph, turned, with room around it for the handles.
                let box = g.editBounds(pivot: Self.pivot, in: source)
                let fit = min(view.width * 0.88 / (box.width * source.width),
                              view.height * 0.88 / (box.height * source.height))
                let offset = CGPoint(x: view.width / 2 - box.midX * source.width * fit,
                                     y: view.height / 2 - box.midY * source.height * fit)
                return Layout(viewSize: view, pointScale: ps, source: source, geometry: g, cropping: true,
                              output: source, scale: fit, fitScale: fit, offset: offset)
            }
            let out = g.outputSize(for: source)
            let fit = min(view.width / out.width, view.height / out.height)
            let key = "\(model?.current?.name ?? "")|\(out.width)x\(out.height)"
            if key != viewKey { viewKey = key; zoom = nil; centre = CGPoint(x: 0.5, y: 0.5) }
            let scale = min(max(zoom ?? fit, fit), max(Self.maxZoom, fit))
            // Keep the picture over the view: centred on an axis it does not
            // fill, and with no ground showing on one it does.
            func clamp(_ c: CGFloat, _ viewLength: CGFloat, _ length: CGFloat) -> CGFloat {
                let half = viewLength / 2 / (length * scale)
                return half >= 0.5 ? 0.5 : min(max(c, half), 1 - half)
            }
            centre = CGPoint(x: clamp(centre.x, view.width, out.width), y: clamp(centre.y, view.height, out.height))
            let offset = CGPoint(x: view.width / 2 - centre.x * out.width * scale,
                                 y: view.height / 2 - centre.y * out.height * scale)
            return Layout(viewSize: view, pointScale: ps, source: source, geometry: g, cropping: false,
                          output: out, scale: scale, fitScale: fit, offset: offset)
        }

        // MARK: drawing

        nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            MainActor.assumeIsolated { refresh() }
        }

        nonisolated func draw(in view: MTKView) {
            MainActor.assumeIsolated { drawNow(in: view) }
        }

        private func drawNow(in view: MTKView) {
            guard let model, let l = layout() else {
                renderer.drawCanvas(in: view, print: nil, before: nil, adjustments: Layer2Uniforms(),
                                    transform: nil, canvas: CanvasUniforms())
                return
            }
            // The full-resolution print, once the preview would be magnified.
            var texture = model.print
            if let preview = model.print {
                let previewMagnification = l.scale * l.source.width / Double(preview.width)
                if previewMagnification > 1.02 && !l.cropping {
                    if let full = model.fullPrint { texture = full } else { scheduleFullResolution() }
                }
            }
            var u = CanvasUniforms()
            fill(&u, l, texture: texture)
            if !l.cropping {
                if holdingBefore { u.compare = 2 } else if model.compare == .split { u.compare = 1 }
            }
            u.compareSplit = Float(compareSplit)
            renderer.drawCanvas(in: view, print: texture, before: model.before,
                                adjustments: model.adjustments.uniforms, transform: model.displayTransform,
                                canvas: u, enlarger: model.enlarger)
        }

        private func fill(_ u: inout CanvasUniforms, _ l: Layout, texture: MTLTexture?) {
            u.viewportSize = SIMD2(Float(l.viewSize.width), Float(l.viewSize.height))
            u.imageSize = SIMD2(Float(l.output.width), Float(l.output.height))
            u.offset = SIMD2(Float(l.offset.x), Float(l.offset.y))
            u.scale = Float(l.scale)
            u.geometry = l.geometry.uniform(for: l.source)
            u.editingCrop = l.cropping ? 1 : 0
            u.pivot = SIMD2(Float(Self.pivot.x), Float(Self.pivot.y))
            if let texture { u.magnification = Float(l.scale * l.source.width / Double(texture.width)) }
            // Theme.ground, as Display P3 code values (a grey is the same number in both).
            u.surroundGray = 0.16
        }

        private func scheduleFullResolution() {
            fullTimer?.invalidate()
            fullTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.model?.requestFullResolution() }
            }
        }

        // MARK: the overlay

        /// Draws the crop frame or the before/after divider, in points.
        func drawOverlay(in context: CGContext) {
            guard let model, let l = layout() else { return }
            if l.cropping {
                drawCropFrame(in: context, l)
            } else if model.compare == .split && !holdingBefore && model.before != nil {
                let top = l.viewPoint(CGPoint(x: compareSplit, y: 0)), bottom = l.viewPoint(CGPoint(x: compareSplit, y: 1))
                context.setStrokeColor(UIColor.white.withAlphaComponent(0.9).cgColor)
                context.setLineWidth(1.5)
                context.move(to: top)
                context.addLine(to: bottom)
                context.strokePath()
                let mid = CGPoint(x: top.x, y: (top.y + bottom.y) / 2)
                let knob = CGRect(x: mid.x - 15, y: mid.y - 15, width: 30, height: 30)
                context.setFillColor(UIColor.white.cgColor)
                context.fillEllipse(in: knob)
                context.setStrokeColor(UIColor(white: 0.2, alpha: 1).cgColor)
                context.setLineWidth(1.8)
                for dir: CGFloat in [-1, 1] {
                    context.move(to: CGPoint(x: mid.x + dir * 3, y: mid.y - 5))
                    context.addLine(to: CGPoint(x: mid.x + dir * 8, y: mid.y))
                    context.addLine(to: CGPoint(x: mid.x + dir * 3, y: mid.y + 5))
                }
                context.strokePath()
            }
        }

        private func drawCropFrame(in context: CGContext, _ l: Layout) {
            let g = l.geometry
            let c = g.editPoint(forSource: g.centre, pivot: Self.pivot, imageSize: l.source)
            let a = l.viewPoint(CGPoint(x: c.x - g.crop.width / 2, y: c.y - g.crop.height / 2))
            let b = l.viewPoint(CGPoint(x: c.x + g.crop.width / 2, y: c.y + g.crop.height / 2))
            let r = CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
            context.setStrokeColor(UIColor.white.withAlphaComponent(0.45).cgColor)
            context.setLineWidth(0.75)
            for i in 1...2 {
                let t = CGFloat(i) / 3
                context.move(to: CGPoint(x: r.minX + r.width * t, y: r.minY))
                context.addLine(to: CGPoint(x: r.minX + r.width * t, y: r.maxY))
                context.move(to: CGPoint(x: r.minX, y: r.minY + r.height * t))
                context.addLine(to: CGPoint(x: r.maxX, y: r.minY + r.height * t))
            }
            context.strokePath()
            context.setStrokeColor(UIColor.white.cgColor)
            context.setLineWidth(1.5)
            context.stroke(r)
            // Corner grips, and a short bar at the middle of each edge.
            let arm = min(22, r.width / 3, r.height / 3)
            context.setLineWidth(4)
            context.setLineCap(.square)
            for (x, sx) in [(r.minX, CGFloat(1)), (r.maxX, -1)] {
                for (y, sy) in [(r.minY, CGFloat(1)), (r.maxY, -1)] {
                    context.move(to: CGPoint(x: x + sx * arm, y: y))
                    context.addLine(to: CGPoint(x: x, y: y))
                    context.addLine(to: CGPoint(x: x, y: y + sy * arm))
                }
            }
            let bar = min(14, r.width / 6, r.height / 6)
            context.move(to: CGPoint(x: r.midX - bar, y: r.minY)); context.addLine(to: CGPoint(x: r.midX + bar, y: r.minY))
            context.move(to: CGPoint(x: r.midX - bar, y: r.maxY)); context.addLine(to: CGPoint(x: r.midX + bar, y: r.maxY))
            context.move(to: CGPoint(x: r.minX, y: r.midY - bar)); context.addLine(to: CGPoint(x: r.minX, y: r.midY + bar))
            context.move(to: CGPoint(x: r.maxX, y: r.midY - bar)); context.addLine(to: CGPoint(x: r.maxX, y: r.midY + bar))
            context.strokePath()
        }

        // MARK: gestures

        nonisolated func gestureRecognizer(_ g: UIGestureRecognizer,
                                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // Pinch and pan together is a two-finger move while zooming.
            (g is UIPinchGestureRecognizer && other is UIPanGestureRecognizer)
                || (g is UIPanGestureRecognizer && other is UIPinchGestureRecognizer)
        }

        nonisolated func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            MainActor.assumeIsolated {
                guard let model, model.hasPhoto else { return g is UITapGestureRecognizer }
                if model.cropping { return g is UIPanGestureRecognizer }
                return true
            }
        }

        @objc private func pinched(_ g: UIPinchGestureRecognizer) {
            guard let host, var l = layout(), !l.cropping else { return }
            let at = g.location(in: host)
            switch g.state {
            case .began:
                pinchStart = (l.scale, l.picturePoint(at))
            case .changed:
                guard let start = pinchStart else { return }
                let scale = min(max(start.scale * Double(g.scale), l.fitScale), max(Self.maxZoom, l.fitScale))
                zoom = scale
                // Keep the point that was under the fingers under them.
                l.scale = scale
                centre = CGPoint(x: start.anchor.x - (at.x * l.pointScale - l.viewSize.width / 2) / (l.output.width * scale),
                                 y: start.anchor.y - (at.y * l.pointScale - l.viewSize.height / 2) / (l.output.height * scale))
                refresh()
            default:
                pinchStart = nil
                if let z = zoom, let l = layout(), z <= l.fitScale * 1.001 { zoom = nil }
                reportZoom()
                refresh()
            }
        }

        @objc private func panned(_ g: UIPanGestureRecognizer) {
            guard let host, let model, let l = layout() else { return }
            let at = g.location(in: host)
            if l.cropping { cropPanned(g, at: at, l); return }
            switch g.state {
            case .began:
                draggingSplit = false
                if model.compare == .split, model.before != nil {
                    let line = l.viewPoint(CGPoint(x: compareSplit, y: 0.5))
                    draggingSplit = abs(at.x - line.x) < 36
                }
            case .changed:
                if draggingSplit {
                    compareSplit = min(max(l.picturePoint(at).x, 0), 1)
                    refresh()
                } else if l.isZoomed, pinchStart == nil {
                    let d = g.translation(in: host)
                    g.setTranslation(.zero, in: host)
                    centre.x -= d.x * l.pointScale / (l.output.width * l.scale)
                    centre.y -= d.y * l.pointScale / (l.output.height * l.scale)
                    refresh()
                }
            case .ended:
                if !draggingSplit && !l.isZoomed && pinchStart == nil {
                    let d = g.translation(in: host)
                    if abs(d.x) > 80, abs(d.x) > abs(d.y) * 2 { onSwipe?(d.x < 0) }
                }
                draggingSplit = false
            default:
                draggingSplit = false
            }
        }

        @objc private func doubleTapped(_ g: UITapGestureRecognizer) {
            guard let host, let l = layout(), !l.cropping else { return }
            if l.isZoomed {
                zoom = nil
            } else {
                // 100 %: one photo pixel per screen pixel, about the tapped point.
                let target = max(1.0, l.fitScale * 2)
                centre = l.picturePoint(g.location(in: host))
                zoom = min(target, max(Self.maxZoom, l.fitScale))
            }
            reportZoom()
            refresh()
        }

        @objc private func tapped(_ g: UITapGestureRecognizer) {
            guard let host else { return }
            if let model, model.pickingNeutral, let l = layout(), !l.cropping {
                let u = l.picturePoint(g.location(in: host))
                guard (0...1).contains(u.x), (0...1).contains(u.y) else { return }
                model.pickNeutral(atOutput: u)
                return
            }
            onTap?()
        }

        @objc private func held(_ g: UILongPressGestureRecognizer) {
            switch g.state {
            case .began:
                model?.ensureBefore()
                holdingBefore = true
            case .changed:
                return
            default:
                holdingBefore = false
            }
            refresh()
        }

        private func reportZoom() {
            guard let model, let l = layout() else { return }
            model.canvasZoomPercent = l.isZoomed ? Int((l.scale * 100).rounded()) : nil
        }

        // MARK: the crop tool

        private func cropPanned(_ g: UIPanGestureRecognizer, at p: CGPoint, _ l: Layout) {
            guard let model else { return }
            let e = l.picturePoint(p)
            switch g.state {
            case .began:
                let start = model.geometry
                let s = start.sourcePoint(forEdit: e, pivot: Self.pivot, imageSize: l.source)
                // A grab area of 30 points on screen, whatever the photo's size.
                let tolerance = 30 * l.pointScale / l.scale
                guard let handle = start.handle(at: s, in: l.source, tolerance: tolerance) else { return }
                cropDrag = (handle, start, e)
            case .changed:
                guard let drag = cropDrag else { return }
                let g0 = drag.start
                if drag.handle == .body {
                    // The finger moved Δ in edit space; the crop moves R(θ)Δ on
                    // the source, which keeps it under the finger.
                    let w = l.source.width, h = l.source.height
                    let dx = (e.x - drag.startEdit.x) * w, dy = (e.y - drag.startEdit.y) * h
                    let a = g0.angle * .pi / 180
                    let delta = CGSize(width: (dx * cos(a) - dy * sin(a)) / w, height: (dx * sin(a) + dy * cos(a)) / h)
                    liveGeometry = g0.moved(by: delta, in: l.source)
                } else {
                    let s = g0.sourcePoint(forEdit: e, pivot: Self.pivot, imageSize: l.source)
                    liveGeometry = g0.resized(handle: drag.handle, to: g0.unrotated(s, in: l.source), in: l.source)
                }
                refresh()
            default:
                if let live = liveGeometry { model.geometry = live }
                liveGeometry = nil
                cropDrag = nil
                refresh()
            }
        }
    }
}

/// The canvas's UIKit side: the Metal view, and a transparent view over it
/// for the lines that are not part of the picture.
final class CanvasHostView: UIView {
    let metal: MTKView
    let overlay = CanvasOverlayView()

    init(device: MTLDevice) {
        metal = MTKView(frame: .zero, device: device)
        super.init(frame: .zero)
        metal.isPaused = true
        metal.enableSetNeedsDisplay = true
        metal.colorPixelFormat = Renderer.drawableFormat
        metal.framebufferOnly = true
        // A neutral dark ground, as Display P3 code values (Theme.ground).
        metal.clearColor = MTLClearColor(red: 0.16, green: 0.16, blue: 0.16, alpha: 1)
        if let layer = metal.layer as? CAMetalLayer {
            // The drawable holds Display P3 code values — `outputTransform` put
            // them there — so the tag says so and the system shows them as such.
            layer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
            layer.wantsExtendedDynamicRangeContent = false
        }
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.isUserInteractionEnabled = false
        overlay.contentMode = .redraw
        addSubview(metal)
        addSubview(overlay)
        isMultipleTouchEnabled = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        metal.frame = bounds
        overlay.frame = bounds
        metal.setNeedsDisplay()
        overlay.setNeedsDisplay()
    }
}

final class CanvasOverlayView: UIView {
    weak var coordinator: CanvasView.Coordinator?

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        MainActor.assumeIsolated { coordinator?.drawOverlay(in: context) }
    }
}
