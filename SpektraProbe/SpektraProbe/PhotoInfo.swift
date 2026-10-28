//  PhotoInfo.swift — what the camera recorded about a photo, and the overlay
//  that shows it over the picture.
//
//  Read with ImageIO from the imported file itself (EXIF, TIFF, the DNG
//  dictionary, GPS), plus the one number only the RAW decoder knows: the
//  white balance as shot in kelvin and tint, which is what the Camera panel's
//  As Shot means. What is shown, and why:
//
//  - **Shot** — date and time, camera, lens, focal length (and the 35 mm
//    equivalent when the camera records one), aperture, shutter, ISO, exposure
//    compensation, exposure mode, metering, flash: what a photographer reads
//    first. A manual lens (a Leica M) records no f-number, only an APEX
//    aperture value, so the f-number is worked out from that.
//  - **Colour** — the camera's white-balance setting and light source, the
//    recorded white balance in kelvin and tint, and the camera's neutral
//    (DNG `AsShotNeutral`) for whoever wants the raw multipliers.
//  - **File** — name, format, size, pixel dimensions, firmware, author.
//  - **Location** — only when the photo has one. Exports never carry it.
//
//  Serial numbers are left out on purpose: nobody edits by them, and a
//  screenshot of this overlay should not identify the camera.

import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct PhotoInfo: Equatable {
    struct Row: Equatable, Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    struct Section: Equatable, Identifiable {
        let title: String
        let rows: [Row]
        var id: String { title }
    }

    let sections: [Section]

    /// Reads the file's metadata; `asShot` is the decoder's own reading and
    /// `pixels` the frame's size as RA4 develops it.
    static func read(url: URL, asShot: AsShot?, pixels: CGSize) -> PhotoInfo {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        let props = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] } ?? [:]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let aux = props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let dng = props[kCGImagePropertyDNGDictionary] as? [CFString: Any] ?? [:]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]

        func text(_ d: [CFString: Any], _ k: CFString) -> String? {
            (d[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        }
        func number(_ d: [CFString: Any], _ k: CFString) -> Double? {
            if let n = d[k] as? NSNumber { return n.doubleValue }
            if let a = d[k] as? [NSNumber] { return a.first?.doubleValue }
            return nil
        }

        // Shot
        var shot: [Row] = []
        func add(_ rows: inout [Row], _ label: String, _ value: String?) {
            if let value { rows.append(Row(label: label, value: value)) }
        }
        add(&shot, String(localized: "Date", bundle: .ui), dateTaken(exif, tiff))
        add(&shot, String(localized: "Camera", bundle: .ui), camera(make: text(tiff, kCGImagePropertyTIFFMake),
                                                       model: text(tiff, kCGImagePropertyTIFFModel)))
        add(&shot, String(localized: "Lens", bundle: .ui), text(exif, kCGImagePropertyExifLensModel)
                                             ?? text(aux, kCGImagePropertyExifAuxLensModel))
        if let f = number(exif, kCGImagePropertyExifFocalLength) {
            var value = Self.decimal(f) + " mm"
            if let e = number(exif, kCGImagePropertyExifFocalLenIn35mmFilm), e > 0, abs(e - f) >= 1 {
                value += " · " + String(format: String(localized: "%@ mm in 35 mm terms", bundle: .ui), Self.decimal(e))
            }
            shot.append(Row(label: String(localized: "Focal length", bundle: .ui), value: value))
        }
        if let n = number(exif, kCGImagePropertyExifFNumber), n > 0 {
            shot.append(Row(label: String(localized: "Aperture", bundle: .ui), value: "ƒ/" + Self.decimal(n)))
        } else if let av = number(exif, kCGImagePropertyExifApertureValue) {
            // APEX: N = 2^(AV/2). A manual lens's camera records only this.
            shot.append(Row(label: String(localized: "Aperture", bundle: .ui), value: "ƒ/" + Self.decimal(pow(2, av / 2))))
        }
        add(&shot, String(localized: "Shutter", bundle: .ui), number(exif, kCGImagePropertyExifExposureTime).map(Self.shutter))
        add(&shot, "ISO", number(exif, kCGImagePropertyExifISOSpeedRatings).map { String(Int($0.rounded())) })
        add(&shot, String(localized: "Exposure compensation", bundle: .ui),
            number(exif, kCGImagePropertyExifExposureBiasValue).map { String(format: "%+.1f EV", $0) })
        add(&shot, String(localized: "Mode", bundle: .ui), number(exif, kCGImagePropertyExifExposureProgram).flatMap(Self.program))
        add(&shot, String(localized: "Metering", bundle: .ui), number(exif, kCGImagePropertyExifMeteringMode).flatMap(Self.metering))
        add(&shot, String(localized: "Flash", bundle: .ui), number(exif, kCGImagePropertyExifFlash).map {
            Int($0) & 1 == 1 ? String(localized: "Fired", bundle: .ui) : String(localized: "Did not fire", bundle: .ui)
        })

        // Colour
        var colour: [Row] = []
        if let wb = number(exif, kCGImagePropertyExifWhiteBalance) {
            var value = wb == 1 ? String(localized: "Manual", bundle: .ui) : String(localized: "Auto", bundle: .ui)
            if let light = number(exif, kCGImagePropertyExifLightSource).flatMap(Self.lightSource) {
                value += " · " + light
            }
            colour.append(Row(label: String(localized: "Camera setting", bundle: .ui), value: value))
        }
        add(&colour, String(localized: "As shot", bundle: .ui), asShot.map {
            String(format: String(localized: "%.0f K, tint %+.0f", bundle: .ui), $0.temperature, $0.tint)
        })
        if let neutral = dng[kCGImagePropertyDNGAsShotNeutral] as? [NSNumber], neutral.count == 3 {
            colour.append(Row(label: String(localized: "Camera neutral", bundle: .ui),
                              value: neutral.map { String(format: "%.3f", $0.doubleValue) }.joined(separator: " · ")))
        }

        // File
        var file: [Row] = []
        file.append(Row(label: String(localized: "Name", bundle: .ui), value: url.lastPathComponent))
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
        add(&file, String(localized: "Format", bundle: .ui), values?.contentType?.localizedDescription)
        add(&file, String(localized: "File size", bundle: .ui), values?.fileSize.map {
            ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
        })
        if pixels.width > 0 {
            file.append(Row(label: String(localized: "Pixels", bundle: .ui),
                            value: String(format: "%.0f × %.0f · %.1f MP", pixels.width, pixels.height,
                                          pixels.width * pixels.height / 1e6)))
        }
        add(&file, String(localized: "Firmware", bundle: .ui), text(tiff, kCGImagePropertyTIFFSoftware))
        add(&file, String(localized: "Author", bundle: .ui), text(tiff, kCGImagePropertyTIFFArtist))
        add(&file, String(localized: "Copyright", bundle: .ui), text(tiff, kCGImagePropertyTIFFCopyright))

        // Location
        var location: [Row] = []
        if let lat = number(gps, kCGImagePropertyGPSLatitude), let lon = number(gps, kCGImagePropertyGPSLongitude) {
            let ns = text(gps, kCGImagePropertyGPSLatitudeRef) ?? "N", ew = text(gps, kCGImagePropertyGPSLongitudeRef) ?? "E"
            location.append(Row(label: String(localized: "Coordinates", bundle: .ui),
                                value: String(format: "%.5f° %@, %.5f° %@", lat, ns, lon, ew)))
            add(&location, String(localized: "Altitude", bundle: .ui),
                number(gps, kCGImagePropertyGPSAltitude).map { String(format: "%.0f m", $0) })
        }

        var sections = [Section(title: String(localized: "Shot", bundle: .ui), rows: shot),
                        Section(title: String(localized: "Colour", bundle: .ui), rows: colour),
                        Section(title: String(localized: "File", bundle: .ui), rows: file)]
        if !location.isEmpty { sections.append(Section(title: String(localized: "Location", bundle: .ui), rows: location)) }
        return PhotoInfo(sections: sections.filter { !$0.rows.isEmpty })
    }

    // MARK: wording

    private static func decimal(_ x: Double) -> String {
        x == x.rounded() ? String(format: "%.0f", x) : String(format: "%.1f", x)
    }

    /// 1/45 s below a second, 2.5 s above.
    private static func shutter(_ t: Double) -> String {
        guard t > 0 else { return "—" }
        return t < 0.5 ? "1/\(Int((1 / t).rounded())) s" : decimal(t) + " s"
    }

    /// "LEICA M10-R" rather than "Leica Camera AG LEICA M10-R".
    private static func camera(make: String?, model: String?) -> String? {
        guard let model else { return make }
        guard let make, let brand = make.split(separator: " ").first,
              !model.lowercased().hasPrefix(brand.lowercased()) else { return model }
        return "\(brand) \(model)"
    }

    /// When the camera wrote the picture, as it recorded the wall clock — with
    /// its time zone when it saved one, never converted to the iPad's.
    private static func dateTaken(_ exif: [CFString: Any], _ tiff: [CFString: Any]) -> String? {
        guard let raw = (exif[kCGImagePropertyExifDateTimeOriginal] as? String)
                ?? (tiff[kCGImagePropertyTIFFDateTime] as? String) else { return nil }
        let parse = DateFormatter()
        parse.locale = Locale(identifier: "en_US_POSIX")
        parse.timeZone = TimeZone(secondsFromGMT: 0)
        parse.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard let date = parse.date(from: raw) else { return raw }
        let show = DateFormatter()
        show.timeZone = TimeZone(secondsFromGMT: 0)
        show.dateStyle = .medium
        show.timeStyle = .medium
        var text = show.string(from: date)
        if let offset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String { text += " (UTC\(offset))" }
        return text
    }

    private static func program(_ v: Double) -> String? {
        switch Int(v) {
        case 1: String(localized: "Manual", bundle: .ui)
        case 2: String(localized: "Program", bundle: .ui)
        case 3: String(localized: "Aperture priority", bundle: .ui)
        case 4: String(localized: "Shutter priority", bundle: .ui)
        case 5: String(localized: "Creative", bundle: .ui)
        case 6: String(localized: "Action", bundle: .ui)
        case 7: String(localized: "Portrait", bundle: .ui)
        case 8: String(localized: "Landscape", bundle: .ui)
        default: nil
        }
    }

    private static func metering(_ v: Double) -> String? {
        switch Int(v) {
        case 1: String(localized: "Average", bundle: .ui)
        case 2: String(localized: "Center-weighted", bundle: .ui)
        case 3: String(localized: "Spot", bundle: .ui)
        case 4: String(localized: "Multi-spot", bundle: .ui)
        case 5: String(localized: "Matrix", bundle: .ui)
        case 6: String(localized: "Partial", bundle: .ui)
        default: nil
        }
    }

    private static func lightSource(_ v: Double) -> String? {
        switch Int(v) {
        case 1, 9: String(localized: "Daylight", bundle: .ui)
        case 2, 12, 13, 14, 15: String(localized: "Fluorescent", bundle: .ui)
        case 3, 17: String(localized: "Tungsten", bundle: .ui)
        case 4: String(localized: "Flash", bundle: .ui)
        case 10: String(localized: "Cloudy", bundle: .ui)
        case 11: String(localized: "Shade", bundle: .ui)
        default: nil
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

// MARK: - the overlay

/// The photo's information on a dark, see-through card over the picture,
/// top-left. Tap the close button, or the button that opened it, to hide it;
/// the rest of the picture still takes touches.
struct PhotoInfoOverlay: View {
    @ObservedObject var model: ProbeModel
    @ObservedObject private var language = LanguageSettings.shared
    @State private var info: PhotoInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Photo information").font(.headline)
                Spacer()
                Button {
                    model.showingInfo = false
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.title3).symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Close"))
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)
            // The card is as tall as what it says, and scrolls only when the
            // picture is shorter than that (a phone's cover screen).
            ViewThatFits(in: .vertical) {
                rows
                ScrollView { rows }
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: 380, alignment: .leading)
        .background(.ultraThinMaterial.opacity(0.9), in: RoundedRectangle(cornerRadius: 14))
        .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Read again for another photo, or another language (its rows'
        // labels and values are written in it).
        .task(id: [model.current?.name ?? "", language.localization]) {
            guard let photo = model.current else { info = nil; return }
            let asShot = model.asShot, pixels = model.sourceSize
            info = await Task.detached(priority: .userInitiated) {
                PhotoInfo.read(url: photo.url, asShot: asShot, pixels: pixels)
            }.value
        }
        .transition(.opacity)
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(info?.sections ?? []) { section in
                VStack(alignment: .leading, spacing: 5) {
                    Text(section.title.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.55))
                    ForEach(section.rows) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(row.label)
                                .foregroundStyle(.white.opacity(0.65))
                                .frame(width: 112, alignment: .leading)
                            Text(row.value)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.footnote)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }
}
