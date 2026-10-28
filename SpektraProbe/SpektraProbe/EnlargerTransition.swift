//  EnlargerTransition.swift — what the canvas shows while a new film or paper
//  renders, in the order a darkroom would show it.
//
//  The moment a film or a paper is chosen, the picture on the canvas turns
//  into its own negative: dense and brown where the print was light and the
//  orange mask where it was dark for a colour negative, grey for black and
//  white, and for a slide (which has no negative) the frame dimmed as if on an
//  unlit light table. When the engine's new print has landed, a warm light
//  sweeps across the frame and the print develops in behind it.
//
//  It is honest about the wait rather than hiding it: the negative stays up
//  for as long as the render takes, and the light only runs once the new print
//  is there, so what it reveals is the real result. It never runs for a
//  slider, for undo, or for opening a photo — only for a change of stock — and
//  not at all under Reduce Motion or with the Settings switch off.
//
//  The negative is drawn from a copy of the canvas taken at the change
//  (`from`, which `Renderer.drawCanvas` fills), so it costs no engine render.
//  Main thread only.

import Metal
import QuartzCore
import UIKit

/// Must match `EnlargerUniforms` in Canvas.metal, field for field.
struct EnlargerUniforms {
    /// 0…1: how far the old frame has turned into its negative.
    var negative: Float = 0
    /// The light's position across the picture, 0…1; below 0 it has not
    /// entered yet, above 1 it has left.
    var sweep: Float = -1
    /// 0 a colour negative, 1 a black-and-white negative, 2 a slide.
    var kind: UInt32 = 0
    var active: UInt32 = 0
}

final class EnlargerTransition: NSObject {
    enum Kind: UInt32 { case colour = 0, monochrome = 1, slide = 2 }

    /// The Settings switch (on unless turned off).
    static let enabledKey = "RA4.enlargerAnimation"
    static var isEnabled: Bool {
        (UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true) && !UIAccessibility.isReduceMotionEnabled
    }

    /// The negative fades in over this long…
    static let fadeIn: CFTimeInterval = 0.18
    /// …and is shown at least this long, even when the print is quicker, so
    /// it reads as a step rather than a flicker.
    static let minimumNegative: CFTimeInterval = 0.35
    /// The light's pass across the frame.
    static let sweepDuration: CFTimeInterval = 0.8
    /// If the print never lands (an error), the light runs anyway after this.
    static let timeout: CFTimeInterval = 6
    /// Slow motion, set only by a launch argument (`-RA4.enlargerSlowdown 10`)
    /// so the steps can be screenshotted from the Mac, which cannot record
    /// this iPad's screen.
    private static var slowdown: CFTimeInterval {
        max(1, UserDefaults.standard.double(forKey: "RA4.enlargerSlowdown"))
    }

    /// Set by the canvas: asks it for one more frame.
    var redraw: (() -> Void)?
    /// The canvas as it was at the change, in Display P3. The renderer makes
    /// and fills it; it is read only while a transition runs.
    var from: MTLTexture?
    /// The renderer is to copy the canvas into `from` on its next draw.
    private(set) var wantsSnapshot = false

    private enum Phase { case idle, exposing(since: CFTimeInterval), sweeping(since: CFTimeInterval) }
    private var phase = Phase.idle
    private var kind = Kind.colour
    private var landed = false
    private var link: CADisplayLink?

    var isRunning: Bool { if case .idle = phase { false } else { true } }

    /// A film or paper was just chosen: show the negative of what is on the
    /// canvas until `settled()`.
    func begin(kind: Kind) {
        guard Self.isEnabled else { return }
        self.kind = kind
        landed = false
        wantsSnapshot = true
        phase = .exposing(since: CACurrentMediaTime())
        startLink()
        redraw?()
    }

    /// The engine has rendered everything the controls ask for.
    func settled() {
        landed = true
    }

    /// The renderer copied the canvas into `from`.
    func snapshotTaken() {
        wantsSnapshot = false
    }

    /// What the canvas draws with now, or nil when no transition runs.
    func uniforms() -> EnlargerUniforms? {
        let now = CACurrentMediaTime()
        switch phase {
        case .idle:
            return nil
        case .exposing(let since):
            let t = Float(min(1, (now - since) / (Self.fadeIn * Self.slowdown)))
            return EnlargerUniforms(negative: t * t * (3 - 2 * t), sweep: -1, kind: kind.rawValue, active: 1)
        case .sweeping(let since):
            let t = Float(min(1, (now - since) / (Self.sweepDuration * Self.slowdown)))
            let eased = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
            // From just before the left edge to just past the right, so the
            // light enters and leaves the frame rather than starting on it.
            return EnlargerUniforms(negative: 1, sweep: -0.08 + eased * 1.16, kind: kind.rawValue, active: 1)
        }
    }

    // MARK: the clock

    private func startLink() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick() {
        let now = CACurrentMediaTime()
        switch phase {
        case .idle:
            stopLink()
        case .exposing(let since):
            let waited = now - since
            if (landed && waited >= Self.minimumNegative * Self.slowdown) || waited >= Self.timeout * Self.slowdown {
                phase = .sweeping(since: now)
            }
        case .sweeping(let since):
            if now - since >= Self.sweepDuration * Self.slowdown {
                phase = .idle
                from = nil
                stopLink()
            }
        }
        redraw?()
    }
}
