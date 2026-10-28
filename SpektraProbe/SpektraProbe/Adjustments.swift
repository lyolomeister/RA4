//  Adjustments.swift — Layer 2, the adjustments to the finished print.
//
//  The Mac app's Post-Dev model (`Model/Adjustments.swift`), reduced to the
//  sliders this build has, with the same ranges and the same arithmetic —
//  `uniforms` is `Layer2Uniforms.tone` from the Mac's `Model/Mask.swift`.
//  Vibrance is new here: the Mac app has none.
//
//  Zero is "nothing applied" for every field, so a fresh photo reads as the
//  pure film simulation. Order in the shader (`Canvas.metal`, `layer2Tone`):
//  white balance → exposure → contrast → highlights/shadows → black/white
//  point → saturation → vibrance.

import Foundation

struct Adjustments: Equatable, Codable {
    // White balance, post-print: an offset on the scan, not the camera's kelvin.
    var temperature: Double = 0    // −100…100, blue ↔ amber
    var tint: Double = 0           // −100…100, green ↔ magenta
    var exposure: Double = 0       // stops, −3…3
    var contrast: Double = 0       // −50…50
    var highlights: Double = 0     // −100…100
    var shadows: Double = 0        // −100…100
    var blackPoint: Double = 0     // 0…50  (percent of range lifted to black)
    var whitePoint: Double = 0     // 0…50
    var saturation: Double = 0     // −100…100
    var vibrance: Double = 0       // −100…100

    var isNeutral: Bool { self == Adjustments() }

    /// The uniform block `layer2` reads, computed once per change.
    var uniforms: Layer2Uniforms {
        var u = Layer2Uniforms()
        // Temperature and tint become channel gains, ±100 → about ±0.18 on the
        // opposing channels: the range of a scan correction, not a scene one.
        let t = Float(temperature) / 100, g = Float(tint) / 100
        u.wbR = 1 + 0.18 * t
        u.wbG = 1 - 0.12 * g
        u.wbB = 1 - 0.18 * t
        u.exposureGain = Float(pow(2.0, exposure))
        u.contrast = Float(contrast) / 100
        u.saturation = 1 + Float(saturation) / 100
        u.vibrance = Float(vibrance) / 100
        u.highlights = Float(highlights) / 100
        u.shadows = Float(shadows) / 100
        u.blackPoint = Float(blackPoint) / 100
        u.whitePoint = Float(whitePoint) / 100
        return u
    }
}

/// Must match `Layer2Uniforms` in Canvas.metal field for field and in order.
/// Scalars only, so the two layouts cannot disagree about a float3's padding.
struct Layer2Uniforms {
    var wbR: Float = 1, wbG: Float = 1, wbB: Float = 1
    var exposureGain: Float = 1
    var contrast: Float = 0
    /// The Mac app's brightness. Kept in the shader so `layer2Tone` stays the
    /// Mac's line for line; this build has no slider for it.
    var brightness: Float = 0
    var saturation: Float = 1
    var vibrance: Float = 0
    var highlights: Float = 0
    var shadows: Float = 0
    var blackPoint: Float = 0
    var whitePoint: Float = 0
    /// `pow(0.18, 1/1.8)`: mid-grey through ROMM γ1.8, the working space's own
    /// curve — the pivot every tone region uses (RFC-018 D1).
    var midGrey: Float = 0.3857
    var enabled: UInt32 = 1
}
