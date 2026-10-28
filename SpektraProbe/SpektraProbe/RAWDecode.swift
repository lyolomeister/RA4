//  RAWDecode.swift — the decode, exactly as the Mac app makes the engine's frame.
//
//  Mirrors `ImageDecoder.rawFilter(_:look: .linear, ...)` and `engineFrame`
//  in `modern_UI/Spektrafilm/Spektrafilm/Import/ImageDecoder.swift`: Apple's
//  tone rendering off (the film model wants sensor response), rendered into
//  float32 RGBA **linear ProPhoto**, top row first, with no vertical flip.

import CoreImage
import Metal

enum RAWDecode {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    struct Decoded {
        let image: CIImage
        let width: Int
        let height: Int
        let isRAW: Bool
    }

    /// Linear ProPhoto RGB: ROMM primaries against D50 at gamma 1, which Core
    /// Graphics does not ship by name. The same construction as the Mac app's.
    static let linearProPhoto: CGColorSpace = {
        let d50: [CGFloat] = [0.9642, 1.0000, 0.8249]
        let black: [CGFloat] = [0, 0, 0]
        let gamma: [CGFloat] = [1, 1, 1]
        let primaries: [CGFloat] = [
            0.7976749, 0.2880402, 0.0000000,
            0.1351917, 0.7118741, 0.0000000,
            0.0313534, 0.0000857, 0.8252100,
        ]
        return CGColorSpace(calibratedRGBWhitePoint: d50, blackPoint: black,
                            gamma: gamma, matrix: primaries)!
    }()

    /// The engine's output space: ROMM RGB, gamma 1.8 (ARCHITECTURE §7.5 row 5).
    static let workingSpace = CGColorSpace(name: CGColorSpace.rommrgb)!
    static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!

    static let context: CIContext = CIContext(mtlDevice: MTLCreateSystemDefaultDevice()!, options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!,
        .workingFormat: CIFormat.RGBAh,
        .cacheIntermediates: false,
        .highQualityDownsample: true,
    ])

    static func decode(_ url: URL) throws -> Decoded {
        if let filter = CIRAWFilter(imageURL: url) {
            filter.isLensCorrectionEnabled = filter.isLensCorrectionSupported
            filter.isDraftModeEnabled = false
            filter.boostAmount = 0
            filter.boostShadowAmount = 0
            filter.isGamutMappingEnabled = false
            filter.localToneMapAmount = 0
            filter.extendedDynamicRangeAmount = 0
            guard let image = filter.outputImage else {
                throw Failure(description: "Core Image could not decode \(url.lastPathComponent)")
            }
            return try sized(image, isRAW: true)
        }
        // Not a RAW iPadOS can decode: a JPEG/TIFF still exercises the engine.
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw Failure(description: "iPadOS has no decoder for \(url.lastPathComponent)")
        }
        return try sized(image, isRAW: false)
    }

    private static func sized(_ image: CIImage, isRAW: Bool) throws -> Decoded {
        guard !image.extent.isInfinite, !image.extent.isEmpty else {
            throw Failure(description: "the decoded frame has no pixels")
        }
        let extent = image.extent.integral
        let placed = image.transformed(by: .init(translationX: -extent.origin.x, y: -extent.origin.y))
        return Decoded(image: placed, width: Int(extent.width), height: Int(extent.height), isRAW: isRAW)
    }

    /// Renders the decode into `pointer` (width * height * 16 bytes): float32
    /// RGBA, linear ProPhoto, top row first.
    static func renderFrame(_ decoded: Decoded, into pointer: UnsafeMutableRawPointer) {
        autoreleasepool {
            context.render(decoded.image, toBitmap: pointer, rowBytes: decoded.width * 16,
                           bounds: CGRect(x: 0, y: 0, width: decoded.width, height: decoded.height),
                           format: .RGBAf, colorSpace: linearProPhoto)
        }
    }

    /// The engine's RGBA16 result, downscaled to `maxEdge` and converted from
    /// the working space to Display P3 for the screen.
    static func displayImage(_ rendered: Engine.Rendered, maxEdge: Int) -> CGImage? {
        let rowBytes = rendered.rowStridePx * 8
        let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: rendered.rgba16),
                        count: rowBytes * rendered.height, deallocator: .none)
        let size = CGSize(width: rendered.width, height: rendered.height)
        var image = CIImage(bitmapData: data, bytesPerRow: rowBytes, size: size,
                            format: .RGBA16, colorSpace: workingSpace)
        let scale = min(1.0, Double(maxEdge) / Double(max(rendered.width, rendered.height)))
        if scale < 1 {
            image = image.applyingFilter("CILanczosScaleTransform",
                                         parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0])
        }
        return autoreleasepool {
            context.createCGImage(image, from: image.extent.integral, format: .RGBA8, colorSpace: displayP3)
        }
    }
}
