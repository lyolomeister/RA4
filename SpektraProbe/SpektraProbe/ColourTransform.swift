//  ColourTransform.swift — the working space, and the one conversion out of it.
//
//  The Mac app's `Canvas/ColourManagement.swift`, reduced to what this build
//  needs: ask the engine for the numbers (`spk_output_transform`), pack them
//  into the uniform block `outputTransform` reads, and keep the C_max table
//  on the GPU. No colour library of our own — every number is the engine's.

import CoreGraphics
import Foundation
import Metal

typealias Mat9f = (Float, Float, Float, Float, Float, Float, Float, Float, Float)
typealias K22f = (Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float,
                  Float, Float, Float, Float, Float, Float, Float, Float, Float, Float, Float)

/// Must match `OutputTransformUniforms` in Canvas.metal field for field and in
/// order. Copied from the Mac app's `ColourManagement.swift`.
struct OutputTransformUniforms {
    var matrix: Mat9f = (1, 0, 0, 0, 1, 0, 0, 0, 1)
    var cam16M2X: Mat9f = (1, 0, 0, 0, 1, 0, 0, 0, 1)
    var cam16M2R: Mat9f = (1, 0, 0, 0, 1, 0, 0, 0, 1)
    var cam16K: K22f = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    var sourceCctfMode: UInt32 = 0
    var targetCctfMode: UInt32 = 0
    var cam16Active: UInt32 = 0
    var cam16Lightness: UInt32 = 0
    var cmaxNL: UInt32 = 0
    var cmaxNH: UInt32 = 0
    var _pad0: UInt32 = 0
    var _pad1: UInt32 = 0
}

/// One destination: the engine's numbers, packed, plus the table on the device.
struct ColourTransform: @unchecked Sendable {
    /// The engine's name for the working space the pixels are in.
    let sourceName: String
    /// The engine's name for the destination ("Display P3", "sRGB").
    let targetName: String
    /// What the destination is to Core Graphics — the tag a file carries.
    let space: CGColorSpace
    let uniforms: OutputTransformUniforms
    let cmax: MTLBuffer

    /// The working space's name when the open reply does not say: the engine's
    /// default `io.output_color_space`, as in the Mac app's `Session`.
    static let defaultWorkingSpace = "ProPhoto RGB"

    /// The Mac app's export/canvas setting (`ColourManagement.gamutCompressionWithoutLightness`):
    /// the engine already ran CAM16's lightness shoulder once when it encoded
    /// ProPhoto, so the conversion keeps the chroma knee and drops only that.
    static let gamutCompressionWithoutLightness = #"{"lightness_compression_active": false}"#

    /// Fetched from the engine. Runs on the engine's queue.
    static func make(engine: Engine, source: String, targetName: String, space: CGColorSpace,
                     device: MTLDevice) throws -> ColourTransform {
        let (reply, cmax) = try engine.outputTransform(source: source, target: targetName,
                                                       gamutCompress: gamutCompressionWithoutLightness)
        func doubles(_ value: Any?) -> [Double] { (value as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? [] }
        let compress = reply["gamut_compress"] as? [String: Any] ?? [:]
        let matrix = doubles(reply["matrix"])
        let toXYZ = doubles(compress["m_to_xyz"]), toRGB = doubles(compress["m_to_rgb"])
        let k = doubles(compress["k"])
        let rows = (compress["cmax_rows"] as? NSNumber)?.intValue ?? 0
        let cols = (compress["cmax_cols"] as? NSNumber)?.intValue ?? 0
        guard matrix.count == 9, toXYZ.count == 9, toRGB.count == 9, k.count == 22,
              rows > 0, cols > 0, rows * cols == cmax.count,
              let sourceMode = (reply["source_cctf_mode"] as? NSNumber)?.uint32Value,
              let targetMode = (reply["target_cctf_mode"] as? NSNumber)?.uint32Value,
              let table = device.makeBuffer(bytes: cmax, length: cmax.count * MemoryLayout<Float>.size,
                                            options: .storageModeShared)
        else {
            throw Engine.Failure(description: "the engine's reply for \(source) → \(targetName) did not parse")
        }
        var u = OutputTransformUniforms()
        u.matrix = mat9(matrix)
        u.cam16M2X = mat9(toXYZ)
        u.cam16M2R = mat9(toRGB)
        u.cam16K = k22(k)
        u.sourceCctfMode = sourceMode
        u.targetCctfMode = targetMode
        u.cam16Active = (compress["algorithm"] as? String) == "off" ? 0 : 1
        u.cam16Lightness = (compress["lightness_compression_active"] as? Bool) == true ? 1 : 0
        u.cmaxNL = UInt32(rows)
        u.cmaxNH = UInt32(cols)
        return ColourTransform(sourceName: source, targetName: targetName, space: space,
                               uniforms: u, cmax: table)
    }

    private static func mat9(_ d: [Double]) -> Mat9f {
        (Float(d[0]), Float(d[1]), Float(d[2]), Float(d[3]), Float(d[4]), Float(d[5]),
         Float(d[6]), Float(d[7]), Float(d[8]))
    }

    private static func k22(_ d: [Double]) -> K22f {
        (Float(d[0]), Float(d[1]), Float(d[2]), Float(d[3]), Float(d[4]), Float(d[5]),
         Float(d[6]), Float(d[7]), Float(d[8]), Float(d[9]), Float(d[10]),
         Float(d[11]), Float(d[12]), Float(d[13]), Float(d[14]), Float(d[15]), Float(d[16]),
         Float(d[17]), Float(d[18]), Float(d[19]), Float(d[20]), Float(d[21]))
    }
}
