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
        /// The camera's own white balance, read before any override; nil for
        /// a file that is not a RAW.
        var asShot: AsShot? = nil
        /// Whether the RAW carries a lens correction Core Image can apply.
        var lensCorrectionSupported = false
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

    static let context: CIContext = CIContext(mtlDevice: MTLCreateSystemDefaultDevice()!, options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!,
        .workingFormat: CIFormat.RGBAh,
        .cacheIntermediates: false,
        .highQualityDownsample: true,
    ])

    static func decode(_ url: URL, camera: CameraDecode) throws -> Decoded {
        if let (filter, asShot) = rawFilter(url, camera: camera, linear: true) {
            guard let image = filter.outputImage else {
                throw Failure(description: "Core Image could not decode \(url.lastPathComponent)")
            }
            var decoded = try sized(image, isRAW: true)
            decoded.asShot = asShot
            decoded.lensCorrectionSupported = filter.isLensCorrectionSupported
            return decoded
        }
        // Not a RAW iPadOS can decode: a JPEG/TIFF still exercises the engine.
        guard let image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else {
            throw Failure(description: "iPadOS has no decoder for \(url.lastPathComponent)")
        }
        return try sized(image, isRAW: false)
    }

    /// The Mac's `ImageDecoder.rawFilter(_:look:settings:)`: a filter set up for
    /// the engine's frame (`linear`, Apple's tone rendering off) or for Apple's
    /// own picture of the RAW (the "before"), with the camera's pair read
    /// before the override replaces it. The lens correction is the same in
    /// both, or before and after would be two registrations of the frame.
    static func rawFilter(_ url: URL, camera: CameraDecode, linear: Bool) -> (CIRAWFilter, AsShot)? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        let asShot = AsShot(temperature: Double(filter.neutralTemperature), tint: Double(filter.neutralTint))
        filter.isLensCorrectionEnabled = camera.lensCorrection && filter.isLensCorrectionSupported
        filter.isDraftModeEnabled = false
        if linear {
            filter.boostAmount = 0
            filter.boostShadowAmount = 0
            filter.isGamutMappingEnabled = false
            filter.localToneMapAmount = 0
            filter.extendedDynamicRangeAmount = 0
        }
        if camera.whiteBalance != .asShot {
            filter.neutralTemperature = Float(camera.temperature)
            filter.neutralTint = Float(camera.tint)
        }
        return (filter, asShot)
    }

    /// The kelvin and tint that make the point `p` (normalised to the frame,
    /// top-left origin) neutral, by the RAW filter's own estimate — the Mac's
    /// `ImageDecoder.neutral(at:in:)`.
    static func neutral(at p: CGPoint, in url: URL, camera: CameraDecode) -> AsShot? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        filter.isLensCorrectionEnabled = camera.lensCorrection && filter.isLensCorrectionSupported
        let e = filter.outputImage?.extent ?? .zero
        guard !e.isEmpty, !e.isInfinite else { return nil }
        filter.neutralLocation = CGPoint(x: e.origin.x + p.x.clamped(to: 0...1) * e.width,
                                         y: e.origin.y + (1 - p.y.clamped(to: 0...1)) * e.height)
        return AsShot(temperature: Double(filter.neutralTemperature), tint: Double(filter.neutralTint))
    }

    /// The "before" of before/after: the photograph as iPadOS develops it, with
    /// no film — Apple's own rendering of the RAW at this white balance and
    /// lens correction, or the image itself for a JPEG — at most `longEdge`
    /// pixels long, as Display P3 code values (what the canvas's other
    /// texture holds after the output transform). Top row first, like the
    /// engine's frame, so the two line up pixel for pixel.
    static func beforeTexture(_ url: URL, camera: CameraDecode, longEdge: Int,
                              device: MTLDevice) -> MTLTexture? {
        autoreleasepool {
            var image: CIImage?
            if let (filter, _) = rawFilter(url, camera: camera, linear: false) {
                let native = filter.nativeSize
                let long = max(native.width, native.height)
                if long > 0 { filter.scaleFactor = Float(min(1, Double(longEdge) / Double(long))) }
                image = filter.outputImage
            } else if let plain = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) {
                let long = max(plain.extent.width, plain.extent.height)
                let s = min(1, Double(longEdge) / max(Double(long), 1))
                image = plain.transformed(by: .init(scaleX: s, y: s))
            }
            guard let image, let decoded = try? sized(image, isRAW: false) else { return nil }
            let w = decoded.width, h = decoded.height
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h,
                                                             mipmapped: false)
            d.usage = [.shaderRead]
            guard let texture = device.makeTexture(descriptor: d) else { return nil }
            var pixels = Data(count: w * h * 8)
            pixels.withUnsafeMutableBytes { raw in
                context.render(decoded.image, toBitmap: raw.baseAddress!, rowBytes: w * 8,
                               bounds: CGRect(x: 0, y: 0, width: w, height: h),
                               format: .RGBAh, colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!)
                texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                                withBytes: raw.baseAddress!, bytesPerRow: w * 8)
            }
            return texture
        }
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
}
