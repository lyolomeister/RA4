//  CameraDecode.swift — the camera's white balance and lens correction, applied
//  when the RAW is read.
//
//  The Mac app's `DecodeSettings` (`Model/Sidecar.swift`), with its presets,
//  kelvin values and slider ranges. Not to be confused with Adjust's
//  temperature and tint, which tint the *finished print* like a scan
//  correction: these set what the camera recorded, so the film is exposed to
//  a scene already balanced at this kelvin, the way a colour-correction filter
//  on the lens would.
//
//  Changing either reads the RAW again and reopens the engine (about a second
//  for a 40 MP frame), so the sliders apply when they are let go. A JPEG, HEIC
//  or TIFF has no RAW white balance to change, and the controls say so.

import Foundation

struct CameraDecode: Codable, Equatable, Sendable {
    enum WhiteBalance: String, Codable, CaseIterable, Identifiable, Sendable {
        case asShot = "As Shot", daylight = "Daylight", cloudy = "Cloudy", shade = "Shade",
             tungsten = "Tungsten", fluorescent = "Fluorescent", custom = "Custom"

        var id: String { rawValue }

        /// The presets' colour temperatures, the Mac's.
        var kelvin: Double? {
            switch self {
            case .daylight: 5500
            case .cloudy: 6500
            case .shade: 7500
            case .tungsten: 3200
            case .fluorescent: 4000
            case .asShot, .custom: nil
            }
        }

        var title: String {
            switch self {
            case .asShot: String(localized: "As Shot")
            case .daylight: String(localized: "Daylight")
            case .cloudy: String(localized: "Cloudy")
            case .shade: String(localized: "Shade")
            case .tungsten: String(localized: "Tungsten")
            case .fluorescent: String(localized: "Fluorescent")
            case .custom: String(localized: "Custom")
            }
        }

        /// The choices offered as presets; Custom is what a slider makes.
        static let presets: [WhiteBalance] = [.asShot, .daylight, .cloudy, .shade, .tungsten, .fluorescent]
    }

    var whiteBalance: WhiteBalance = .asShot
    /// Kelvin and tint applied at decode, except under `.asShot`, where the
    /// camera's own pair is used and these are ignored.
    var temperature: Double = 5500
    var tint: Double = 0
    /// The lens's own distortion and vignetting correction, as Core Image
    /// reads it from the RAW (`CIRAWFilter.isLensCorrectionEnabled`).
    ///
    /// **On by default here, unlike the Mac** (which starts it off): this app
    /// always applied it before the switch existed, so every photo already
    /// edited on the iPad was developed with it, and turning it off by default
    /// would quietly change those. It changes the frame's geometry, so a crop
    /// made with it on frames slightly different content with it off — the
    /// Mac's reason for its default.
    var lensCorrection = true

    /// The Mac's slider ranges and steps (`WhiteBalanceRows`).
    static let temperatureRange: ClosedRange<Double> = 2000...12000
    static let tintRange: ClosedRange<Double> = -150...150
    static let temperatureStep: Double = 100
    static let tintStep: Double = 5

    var isNeutral: Bool { self == CameraDecode() }

    /// The pair the decode actually uses, given the camera's own.
    func applied(asShot: AsShot?) -> AsShot {
        if whiteBalance == .asShot, let asShot { return asShot }
        return AsShot(temperature: temperature, tint: tint)
    }
}

extension CameraDecode {
    /// Every field may be missing, so a decode saved by an older or newer
    /// build still opens; a missing field takes its default.
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        whiteBalance = (try? c.decodeIfPresent(WhiteBalance.self, forKey: .whiteBalance)) ?? whiteBalance
        temperature = (try? c.decodeIfPresent(Double.self, forKey: .temperature)) ?? temperature
        tint = (try? c.decodeIfPresent(Double.self, forKey: .tint)) ?? tint
        lensCorrection = (try? c.decodeIfPresent(Bool.self, forKey: .lensCorrection)) ?? lensCorrection
    }
}

/// A white balance as kelvin and tint: the camera's own ("as shot"), or one
/// the eyedropper measured.
struct AsShot: Equatable, Sendable {
    var temperature: Double
    var tint: Double
}
