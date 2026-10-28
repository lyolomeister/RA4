//  ImageExport.swift — writing the finished picture: JPEG, PNG, or TIFF at 8 or
//  16 bits, and estimating how big that file will be.
//
//  The Mac app's `Exporter.write` and `redraw`. The pixels arrive already in
//  sRGB from `outputTransform`, 16 bits deep; an 8-bit format drops them to 8
//  bits **in their own space** (a depth reduction, not a conversion), and
//  ImageIO writes the file with the camera's EXIF, make and model, but not
//  its serial numbers. The Mac pairs PNG with 8 bits and TIFF with 16; here
//  TIFF can also be 8, which is a third of the file for a picture that is
//  going nowhere near another edit. Orientation is not written: the RAW
//  decode is already upright.
//
//  **TIFF compression follows the depth, not the Mac.** The Mac writes LZW at
//  16 bits too, and on a 16-bit print LZW makes the file *larger* than no
//  compression at all — measured on a 40.6 MP M10-R frame: LZW 310 MB, none
//  244 MB, Deflate (ZIP) 231 MB. So 16 bits are Deflate and 8 bits stay LZW
//  (40 MB against Deflate's 66 MB on the same frame). Both are lossless and
//  both open in Photoshop, Lightroom, Capture One, Affinity and Preview.

import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable, Codable, Sendable {
    case jpeg = "JPEG", png = "PNG", tiff = "TIFF"

    var id: String { rawValue }
    var utType: UTType {
        switch self {
        case .jpeg: .jpeg
        case .png: .png
        case .tiff: .tiff
        }
    }
    var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .png: "png"
        case .tiff: "tif"
        }
    }
    var takesQuality: Bool { self == .jpeg }
    /// TIFF alone offers a choice; JPEG and PNG are 8 bits.
    var takesDepth: Bool { self == .tiff }

    /// How far the full-resolution file's size runs from the preview's, per
    /// byte per pixel: a full-size print has its grain at full resolution,
    /// which compresses worse than the downscaled preview's. Measured on the
    /// iPad (`--selftest-export`, a 40.6 MP M10-R frame on Portra 400: JPEG at
    /// quality 95 and 60 came out 2.04× and 2.10× the preview's rate, PNG
    /// 1.37×, TIFF 8-bit 1.57×).
    func fullResolutionFactor(bits: Int) -> Double {
        switch (self, bits) {
        case (.jpeg, _): 2.07
        case (.png, _): 1.37
        case (.tiff, 16): 1.0
        case (.tiff, _): 1.57
        }
    }

    /// The TIFF compression tag for a depth: Deflate (8) at 16 bits, LZW (5)
    /// at 8. See the file's header for the measurement.
    static func tiffCompression(bits: Int) -> Int { bits == 16 ? 8 : 5 }
}

/// What the Export panel is set to; remembered between photos and launches.
struct ExportOptions: Codable, Equatable, Sendable {
    var format = ExportFormat.jpeg
    /// JPEG quality, 10…100; 95 as on the Mac.
    var quality = 95.0
    /// TIFF's depth, 8 or 16. JPEG and PNG are always 8.
    var tiffBits = 16

    var bits: Int { format == .tiff ? tiffBits : 8 }

    /// "JPEG, quality 95", "PNG 8-bit", "TIFF 16-bit".
    var summary: String {
        format == .jpeg ? String(format: String(localized: "JPEG, quality %.0f", bundle: .ui), quality)
                        : "\(format.rawValue) \(bits)-bit"
    }

    private static let key = "RA4.exportOptions"
    static func load() -> ExportOptions {
        guard let data = UserDefaults.standard.data(forKey: key),
              let options = try? JSONDecoder().decode(ExportOptions.self, from: data) else { return ExportOptions() }
        return options
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

enum ImageExport {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// Where exports go: Documents/Exports, which Files shows under
    /// On My iPad › RA4 Light Lab › Exports.
    static var folder: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appending(path: "Exports", directoryHint: .isDirectory)
    }

    /// `<photo name>.<ext>`, or `<photo name> 2.<ext>` and so on, so an export
    /// never replaces an earlier one.
    static func freshURL(for photo: String, format: ExportFormat) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = (photo as NSString).deletingPathExtension, ext = format.fileExtension
        var url = folder.appending(path: "\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appending(path: "\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }

    /// Writes `image` (16 bits, already in its destination space) in the
    /// chosen format. Written under a hidden name and moved into place, so a
    /// failure never leaves a truncated file under the real name.
    static func write(_ image: CGImage, to url: URL, options: ExportOptions, source: [CFString: Any]?) throws {
        let pixels = try prepared(image, bits: options.bits)
        let partial = url.deletingLastPathComponent()
            .appending(path: ".\(url.lastPathComponent).partial-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: partial) }
        guard let destination = CGImageDestinationCreateWithURL(partial as CFURL,
                                                                options.format.utType.identifier as CFString, 1, nil)
        else { throw Failure(description: "could not create \(url.lastPathComponent)") }
        CGImageDestinationAddImage(destination, pixels, properties(options, source: source) as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw Failure(description: "could not write \(url.lastPathComponent)")
        }
        try FileManager.default.moveItem(at: partial, to: url)
    }

    /// The bytes `image` would take in this format — written to memory, never
    /// to disk. What the size estimate measures on the preview.
    static func encodedSize(_ image: CGImage, options: ExportOptions) -> Int? {
        guard let pixels = try? prepared(image, bits: options.bits) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData,
                                                                 options.format.utType.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, pixels, properties(options, source: nil) as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data.length
    }

    private static func properties(_ options: ExportOptions, source: [CFString: Any]?) -> [CFString: Any] {
        // The photo's own (`sourceMetadata`): ImageIO writes the file's own
        // pixel dimensions over its EXIF ones. No GPS: the RAW's GPS
        // dictionary is a separate one and is not copied.
        var properties = source ?? [:]
        if options.format == .jpeg {
            properties[kCGImageDestinationLossyCompressionQuality] = min(max(options.quality / 100, 0.1), 1)
        }
        // Lossless either way: Deflate at 16 bits, LZW at 8 (the header says why).
        if options.format == .tiff {
            var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            tiff[kCGImagePropertyTIFFCompression] = ExportFormat.tiffCompression(bits: options.bits)
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        return properties
    }

    /// The image at the depth the file is written at: 16 bits as it comes, or
    /// 8 bits redrawn in its own space.
    private static func prepared(_ image: CGImage, bits: Int) throws -> CGImage {
        if bits == 16 { return image }
        guard let space = image.colorSpace, let eight = redraw(image, in: space)
        else { throw Failure(description: "could not reduce the picture to 8 bits") }
        return eight
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

    /// What an export carries from the photo, read once at open: its EXIF
    /// block — exposure, lens, the time it was taken — **without the camera's
    /// and the lens's serial numbers**, which identify the equipment and have
    /// no place in a picture that is shared; and from its TIFF block the
    /// camera's make and model, which live there and not in EXIF (without
    /// them Lightroom and Photos show no camera), plus the photographer's own
    /// credit, artist and copyright.
    static func sourceMetadata(of url: URL) -> [CFString: Any]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        var kept: [CFString: Any] = [:]
        if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifBodySerialNumber] = nil
            exif[kCGImagePropertyExifLensSerialNumber] = nil
            kept[kCGImagePropertyExifDictionary] = exif
        }
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            let wanted = [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel,
                          kCGImagePropertyTIFFArtist, kCGImagePropertyTIFFCopyright]
            let camera = tiff.filter { wanted.contains($0.key) }
            if !camera.isEmpty { kept[kCGImagePropertyTIFFDictionary] = camera }
        }
        return kept.isEmpty ? nil : kept
    }
}

// MARK: - the Export panel's settings

/// Format, quality or depth, the estimated size, and the Export button: the
/// top of the Export tool. Estimates while it is on screen.
struct ExportOptionsSection: View {
    @ObservedObject var model: ProbeModel

    var body: some View {
        let o = model.exportOptions
        PanelSection("Format") {
            HStack(spacing: 8) {
                ForEach(ExportFormat.allCases) { format in
                    Chip(verbatim: format.rawValue, selected: o.format == format) { model.exportOptions.format = format }
                }
            }
            if o.format.takesQuality {
                ParamSlider(title: "Quality", value: $model.exportOptions.quality, range: 10...100, resetValue: 95,
                            format: { String(format: "%.0f", $0) })
            }
            if o.format.takesDepth {
                HStack(spacing: 8) {
                    Text("Depth").font(.subheadline).foregroundStyle(Theme.text)
                    Spacer()
                    ForEach([8, 16], id: \.self) { bits in
                        Chip(verbatim: "\(bits)-bit", selected: o.tiffBits == bits) { model.exportOptions.tiffBits = bits }
                    }
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text("Estimated size").font(.subheadline).foregroundStyle(Theme.text)
                Spacer()
                Text(verbatim: model.exportEstimate ?? "—")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Theme.secondaryText)
            }
            Caption(caption(o))
            Button {
                Task { await model.export() }
            } label: {
                Label(String(format: String(localized: "Export %@", bundle: .ui), o.format.rawValue),
                      systemImage: "square.and.arrow.up")
            }
            .buttonStyle(WideButtonStyle(prominent: true))
            .disabled(!model.hasPhoto || model.busy != nil)
        }
        .onAppear { model.exportPanelShown = true }
        .onDisappear { model.exportPanelShown = false }
    }

    private func caption(_ o: ExportOptions) -> LocalizedStringKey {
        switch (o.format, o.bits) {
        case (.jpeg, _): "Full resolution in sRGB, with the camera's EXIF and no location. Smallest; every app opens it."
        case (.png, _): "Full resolution in sRGB, 8 bits, lossless. Larger than a JPEG, no compression artefacts."
        case (.tiff, 16): "Full resolution in sRGB, 16 bits, lossless (ZIP): the most room for further editing, and the largest file."
        default: "Full resolution in sRGB, 8 bits, lossless (LZW)."
        }
    }
}
