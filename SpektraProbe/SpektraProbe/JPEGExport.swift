//  JPEGExport.swift — writing the finished picture as an sRGB JPEG.
//
//  The Mac app's `Exporter.write` and `redraw`, for the one format this build
//  writes. The pixels arrive already in sRGB from `outputTransform`; this only
//  drops them to 8 bits **in their own space** (a depth reduction, not a
//  conversion) and hands them to ImageIO with the quality and the camera's
//  EXIF. Orientation is not written: the RAW decode is already upright.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum JPEGExport {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// Where exports go: Documents/Exports, which Files shows under
    /// On My iPad › SpektraProbe › Exports.
    static var folder: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appending(path: "Exports", directoryHint: .isDirectory)
    }

    /// `<photo name>.jpg`, or `<photo name> 2.jpg` and so on, so an export never
    /// replaces an earlier one.
    static func freshURL(for photo: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = (photo as NSString).deletingPathExtension
        var url = folder.appending(path: "\(base).jpg")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appending(path: "\(base) \(n).jpg")
            n += 1
        }
        return url
    }

    /// Writes `image` (already in its destination space) as a JPEG at
    /// `quality` (0.1…1). Written under a hidden name and moved into place,
    /// so a failure never leaves a truncated file under the real name.
    static func write(_ image: CGImage, to url: URL, quality: Double, sourceEXIF: [CFString: Any]?) throws {
        guard let space = image.colorSpace,
              let eight = redraw(image, in: space)
        else { throw Failure(description: "could not reduce the picture to 8 bits") }
        let partial = url.deletingLastPathComponent()
            .appending(path: ".\(url.lastPathComponent).partial-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: partial) }
        guard let destination = CGImageDestinationCreateWithURL(partial as CFURL, UTType.jpeg.identifier as CFString,
                                                                1, nil)
        else { throw Failure(description: "could not create \(url.lastPathComponent)") }
        var properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: min(max(quality, 0.1), 1),
        ]
        // EXIF is a side channel, passed through unchanged (as the Mac app does);
        // ImageIO writes the file's own pixel dimensions. No GPS: the RAW's GPS
        // dictionary is a separate one and is not copied.
        if let sourceEXIF { properties[kCGImagePropertyExifDictionary] = sourceEXIF }
        CGImageDestinationAddImage(destination, eight, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw Failure(description: "could not write \(url.lastPathComponent)")
        }
        try FileManager.default.moveItem(at: partial, to: url)
    }

    /// 8 bits per channel in the image's *own* space: Core Graphics redraws
    /// without converting colour, because source and destination are the same.
    private static func redraw(_ image: CGImage, in space: CGColorSpace) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// The RAW's EXIF block, read once at open, for the export to carry.
    static func sourceEXIF(of url: URL) -> [CFString: Any]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        return properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
    }
}
