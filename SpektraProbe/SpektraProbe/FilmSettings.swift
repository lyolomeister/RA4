//  FilmSettings.swift — the engine's settings for a frame (Layer 1).
//
//  A port of the Mac app's `Model/Params.swift` (`FilmParams`, `EffectStrengths`,
//  `SceneLatitudeSettings`, `FilmFrame`, `ExposureMethod`) for the controls this
//  build has: film and paper, the camera's metering and film exposure, the film
//  format, the film's effects, Scene Placement and the print's switches. Same
//  defaults, same ranges, same wire names and the same rules, so a frame opened
//  here renders as a fresh frame does on the Mac.
//
//  Not ported, and sent at the Mac's own defaults so the engine is told the same
//  thing: the enlarger (switched off in the Mac build too), the tone mask (off
//  there as well), the Digital Intermediate (it needs the Cineon view on the
//  canvas), the film edge and the date back.

import Foundation

/// A wire value, comparable so a change can be sent as a delta.
enum ParamValue: Equatable {
    case double(Double), bool(Bool), string(String)

    var json: Any {
        switch self {
        case .double(let d): d
        case .bool(let b): b
        case .string(let s): s
        }
    }
}

extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self { min(max(self, r.lowerBound), r.upperBound) }
}

/// A film type and its frame, in millimetres (the Mac's `FilmFrame`). The
/// engine takes one number, the frame's long edge, derived from these and the
/// photograph's own shape (`FilmSettings.filmFormatMM`).
struct FilmFrame: Identifiable, Hashable {
    let id: String
    let short: Double
    let long: Double
    let isCine: Bool

    static let custom = FilmFrame(id: "Custom", short: 24, long: 36, isCine: false)
    static let cine: [FilmFrame] = [
        .init(id: "Super 8", short: 4.01, long: 5.79, isCine: true),
        .init(id: "16mm", short: 7.49, long: 10.26, isCine: true),
        .init(id: "Super 16", short: 7.41, long: 12.52, isCine: true),
        .init(id: "Super 35", short: 14.00, long: 24.89, isCine: true),
        .init(id: "65mm", short: 23.01, long: 52.63, isCine: true),
    ]
    /// 120 is a film width: every 120 back exposes 56 mm across, so Side =
    /// Short at 56 covers 645, 6×6, 6×7 and 6×9 from the photo's own aspect.
    static let still: [FilmFrame] = [
        .init(id: "110", short: 13, long: 17, isCine: false),
        .init(id: "APS", short: 16.7, long: 30.2, isCine: false),
        .init(id: "135", short: 24, long: 36, isCine: false),
        .init(id: "120", short: 56, long: 56, isCine: false),
        custom,
    ]
    static var all: [FilmFrame] { still + cine }
    static func named(_ id: String) -> FilmFrame { all.first { $0.id == id } ?? custom }

    func side(_ s: FilmSide) -> Double { s == .short ? short : long }
}

/// Which side of the photograph the side length measures.
enum FilmSide: String, CaseIterable, Identifiable, Codable {
    case short, long
    var id: String { rawValue }
    var title: String { self == .short ? "Short" : "Long" }
}

/// The meter (the Mac's `AEMethod`): Custom is the meter switched off, so
/// Film Exposure is measured from the linear frame; the other four are the
/// engine's exposure intents, by their wire names.
enum Metering: String, CaseIterable, Identifiable, Codable {
    case custom
    case balanced
    case center
    case protectHighlights = "protect_highlights"
    case protectShadows = "protect_shadows"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .custom: "Custom"
        case .balanced: "Balanced"
        case .center: "Center"
        case .protectHighlights: "Protect highlights"
        case .protectShadows: "Protect shadows"
        }
    }
}

/// Each film effect's strength, as a multiplier on the stock's own (the Mac's
/// `EffectStrengths`, RFC-025/034). 1 is "this film, as modelled".
struct EffectStrengths: Equatable, Codable {
    var grain = 1.0                // 0…2
    var grainLayered = true
    var halation = 1.0             // 0…4, an area multiplier
    var antihalationRemoved = false
    var highlightBoost = 0.0       // 0…8 EV
    var highlightHeadroom = 4.0    // 0…8 EV, films with no anti-halation layer
    var scatter = 1.0              // 0…1
    var couplersActive = true
    var couplers = 1.0             // 0…1.5 (the inverse breaks above ~1.736)
    var glare = 1.0                // 0…30, an area multiplier

    static let grainRange = 0.0...2.0
    static let halationRange = 0.0...4.0
    static let scatterRange = 0.0...1.0
    static let highlightBoostRange = 0.0...8.0
    static let highlightHeadroomRange = 0.0...8.0
    static let couplersRange = 0.0...1.5
    static let glareRange = 0.0...30.0
}

/// Scene Placement (RFC-023, the Mac's `SceneLatitudeSettings`): the two
/// pull-backs are UI state; the curve the engine renders is what its Fit
/// solved from them, and only a fit the engine accepted is ever stored.
struct ScenePlacement: Equatable, Codable {
    var highlightPullBack = 0.0    // stops, 0…8; 0 = that side off
    var shadowPullBack = 0.0
    var active = false
    var norm = "power"
    var highlightKnee = 2.0
    var highlightRoom = 0.0
    var shadowKnee = -2.0
    var shadowRoom = 0.0
    var rolloff = 2.0
    var maxLift = 4.0

    static let range = 0.0...8.0

    /// Takes the engine's fit: its `params_delta` becomes the rendered curve.
    mutating func apply(highlight: Double, shadow: Double, delta: [String: Any]) {
        func number(_ key: String) -> Double? { (delta[key] as? NSNumber)?.doubleValue }
        highlightPullBack = highlight
        shadowPullBack = shadow
        active = (delta["scene_latitude_active"] as? Bool) ?? active
        norm = (delta["scene_latitude_norm"] as? String) ?? norm
        highlightKnee = number("scene_latitude_highlight_knee") ?? highlightKnee
        highlightRoom = number("scene_latitude_highlight_room") ?? highlightRoom
        shadowKnee = number("scene_latitude_shadow_knee") ?? shadowKnee
        shadowRoom = number("scene_latitude_shadow_room") ?? shadowRoom
        rolloff = number("scene_latitude_rolloff") ?? rolloff
        maxLift = number("scene_latitude_max_lift") ?? maxLift
    }
}

struct FilmSettings: Equatable, Codable {
    // The Mac's defaults for a new frame (`FilmParams.init`).
    var filmStock = "kodak_portra_400"
    var printStock = "kodak_supra_endura"
    var exposureCompensationEV = 0.0        // the rail shows −4…4 in thirds
    var metering = Metering.balanced
    var filmFrame = "135"
    var filmSide = FilmSide.short
    var sideLengthMM = 24.0
    /// Derived from the three above and the photo's aspect; 36 until a photo is open.
    var filmFormatMM = 36.0
    var grainActive = true
    var halationActive = true
    var glareActive = true
    /// "No print profile": scan the developed film. Always on for a slide film.
    var scanFilm = false
    var extendedDynamicRange = false
    var printEffects = true
    var effects = EffectStrengths()
    var placement = ScenePlacement()
    /// Black and white only (`BlackAndWhite.swift`): a colour filter on the
    /// lens, and the Multigrade grade the print is made at. Kept when a colour
    /// film is chosen, and sent only while a black-and-white one is.
    var lensFilter = LensFilter.none
    var paperGrade = PaperGrades.normal

    private var catalog: StockCatalog { .shared }
    var film: Stock? { catalog.stock(filmStock) }
    var filmIsPositive: Bool { film?.isPositive ?? false }
    var filmIsMonochrome: Bool { film?.isMonochrome ?? false }
    var printIsMonochrome: Bool { catalog.stock(printStock)?.isMonochrome ?? false }
    var filmHasNoAntihalationLayer: Bool { film?.hasNoAntihalationLayer ?? false }

    /// EDR only on an actual paper: not a film scan, not the silver paper,
    /// which has no EDR calibration (the engine refuses it by name).
    var effectiveExtendedDynamicRange: Bool { extendedDynamicRange && !scanFilm && !printIsMonochrome }

    /// The Mac's `selectFilmStock`: a film brings its declared paper unless
    /// the current one already is it; colour and black and white cannot share
    /// a paper; a slide film has no print stage, so it is scanned.
    mutating func selectFilm(_ id: String) {
        filmStock = id
        if let target = catalog.stock(id)?.targetPrint, catalog.stock(target) != nil,
           !catalog.isDeclaredPairing(film: id, paper: printStock) {
            printStock = target
        }
        if !catalog.canPrint(film: id, on: printStock) {
            printStock = catalog.stock(id)?.targetPrint ?? FilmSettings().printStock
        }
        if filmIsPositive { scanFilm = true }
    }

    /// The Mac's `selectPrintStock`: a slide film keeps its scan; a paper that
    /// cannot print this film is not taken.
    mutating func selectPaper(_ id: String) {
        guard !filmIsPositive, catalog.canPrint(film: filmStock, on: id) else { return }
        printStock = id
        scanFilm = false
    }

    /// The Mac's `Session.filmFormatMM(side:sideLengthMM:aspect:)`: the long edge.
    static func filmFormatMM(side: FilmSide, sideLengthMM: Double, aspect: Double) -> Double {
        let long = side == .long ? sideLengthMM : sideLengthMM * max(aspect, 1)
        return long.clamped(to: 4...200)
    }

    mutating func setFrame(_ id: String, aspect: Double) {
        filmFrame = id
        if id != FilmFrame.custom.id { sideLengthMM = FilmFrame.named(id).side(filmSide) }
        filmFormatMM = Self.filmFormatMM(side: filmSide, sideLengthMM: sideLengthMM, aspect: aspect)
    }

    mutating func setSide(_ side: FilmSide, aspect: Double) {
        filmSide = side
        if filmFrame != FilmFrame.custom.id { sideLengthMM = FilmFrame.named(filmFrame).side(side) }
        filmFormatMM = Self.filmFormatMM(side: side, sideLengthMM: sideLengthMM, aspect: aspect)
    }

    mutating func setSideLength(_ mm: Double, aspect: Double) {
        filmFrame = FilmFrame.custom.id
        sideLengthMM = mm.clamped(to: 1...500)
        filmFormatMM = Self.filmFormatMM(side: filmSide, sideLengthMM: sideLengthMM, aspect: aspect)
    }

    /// The Mac's per-film grain: the `grain_amount` at which a black-and-white
    /// film renders its maker's published granularity. 1 for colour.
    static func ownGrain(of stock: String) -> Double {
        switch stock {
        case "kodak_tri_x_400": 1.70
        case "ilford_hp5_plus_400": 1.49
        case "kodak_tmax_100": 0.74
        case "fujifilm_neopan_acros_100_ii": 0.64
        default: 1
        }
    }

    /// Multigrade filter 2 as the wire's neutral pack (C, M, Y), from
    /// `engine/resources_product/paper_grades.json` — the Mac's fixed grade,
    /// and this app's when the bundled table is missing.
    static let multigradeFilter2 = (c: 0.0, m: 0.0, y: 68.0)

    /// The grade's pack and print exposure, when the table is for this paper.
    var gradeOnPaper: PaperGrades.Grade? {
        guard let table = PaperGrades.shared, table.paper == printStock else { return nil }
        return table.grades[paperGrade]
    }

    /// Every field, as the Mac's `FilmParams.wire` sends it for these controls.
    var wire: [String: ParamValue] {
        let p = placement
        var w: [String: ParamValue] = [
            "film_stock": .string(filmStock),
            "print_stock": .string(printStock),
            "exposure_compensation_ev": .double(exposureCompensationEV),
            // Custom leaves the method alone and turns the meter off.
            "auto_exposure": .bool(metering != .custom),
            "film_format_mm": .double(filmFormatMM),
            "grain_active": .bool(grainActive),
            // Never on a black-and-white film: the sub-layers are the colour films' model.
            "grain_sublayers_active": .bool(grainActive && effects.grainLayered && !filmIsMonochrome),
            "halation_active": .bool(halationActive),
            // The enlarger is switched off in the Mac build: brightness 0 stops, no shift.
            "print_exposure": .double(1),
            "y_filter_shift": .double(0),
            "m_filter_shift": .double(0),
            "filter_shift_scale": .double(40),
            "glare_active": .bool(glareActive && printEffects),
            "scan_film": .bool(scanFilm),
            "extended_dynamic_range": .bool(effectiveExtendedDynamicRange),
            "preflash_exposure": .double(0),
            "contrast_mask_active": .bool(false),
            "scene_latitude_active": .bool(p.active),
            "scene_latitude_norm": .string(p.norm),
            "scene_latitude_highlight_knee": .double(p.highlightKnee),
            "scene_latitude_highlight_room": .double(p.highlightRoom),
            "scene_latitude_shadow_knee": .double(p.shadowKnee),
            "scene_latitude_shadow_room": .double(p.shadowRoom),
            "scene_latitude_rolloff": .double(p.rolloff),
            "scene_latitude_max_lift": .double(p.maxLift),
            "halation_amount": .double(effects.halation.clamped(to: EffectStrengths.halationRange)),
            "halation_scatter_amount": .double(effects.scatter.clamped(to: EffectStrengths.scatterRange)),
            "grain_amount": .double((effects.grain * Self.ownGrain(of: filmStock))
                .clamped(to: EffectStrengths.grainRange)),
            "dir_couplers_active": .bool(effects.couplersActive),
            "dir_couplers_amount": .double(effects.couplers.clamped(to: EffectStrengths.couplersRange)),
            "glare_amount": .double(effects.glare.clamped(to: EffectStrengths.glareRange)),
            "antihalation_removed": .bool(effects.antihalationRemoved),
            "halation_boost_ev": .double(effects.highlightBoost.clamped(to: EffectStrengths.highlightBoostRange)),
            "halation_headroom_ev": .double(effects.highlightHeadroom.clamped(to: EffectStrengths.highlightHeadroomRange)),
            "digital_intermediate": .bool(false),
            "digital_intermediate_blue_compensation": .bool(false),
            // Always sent, so going back to a colour film takes the filter off.
            "camera_filter": .string(filmIsMonochrome ? lensFilter.rawValue : ""),
        ]
        if metering != .custom { w["auto_exposure_method"] = .string(metering.rawValue) }
        // Black and white on its paper: the enlarger's pack, because the
        // engine's table has no row for a silver paper — the grade's, with the
        // print exposure that holds mid-grey at it (1 at grade 2).
        if filmIsMonochrome && printIsMonochrome {
            let grade = gradeOnPaper
            let f = grade.map { (c: $0.c, m: $0.m, y: $0.y) } ?? Self.multigradeFilter2
            w["c_filter_neutral"] = .double(f.c)
            w["m_filter_neutral"] = .double(f.m)
            w["y_filter_neutral"] = .double(f.y)
            w["print_exposure"] = .double(grade?.printExposure ?? 1)
        }
        return w
    }

    /// The fields of `wire` that differ from `sent`, ready for `spk_set_params`.
    func delta(from sent: [String: ParamValue]) -> [String: Any] {
        var d: [String: Any] = [:]
        for (key, value) in wire where sent[key] != value { d[key] = value.json }
        return d
    }
}
