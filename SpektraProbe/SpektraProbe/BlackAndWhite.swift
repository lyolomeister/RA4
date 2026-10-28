//  BlackAndWhite.swift — a lens filter and a paper grade for black-and-white film.
//
//  Both are in the engine already, and neither has a control in the Mac app yet
//  (its `FeatureFlags.blackAndWhite` note: "the lens filter and the paper grade
//  have no control yet"). spektrafilm's unreleased `dev` branch reaches for the
//  same thing (coloured filters on a one-channel black-and-white pipeline); this
//  is SpektraLab's version, with SpektraLab's data:
//
//  - **Lens filter** — the wire's `camera_filter` (API-SPEC §15). A Kodak
//    Wratten transmittance multiplies the film's spectral sensitivity before
//    the scene exposes it, with the filter factor given, so mid-grey keeps its
//    exposure and only the colours' greys move: red darkens a blue sky and
//    pales skin, green lightens foliage. Offered on black-and-white film only:
//    the engine would take one on colour film, as a cast, but nobody has looked.
//  - **Paper grade** — Multigrade filter 00 … 5 as the enlarger's neutral pack
//    and print exposure (`engine/resources_product/paper_grades.json`, bundled
//    by `engine/build-ios.sh`; the engine itself never reads it). 2 is the Mac
//    app's fixed choice; lower is softer, higher is harder. No half grades —
//    the paper's sheet has none.

import SwiftUI

enum LensFilter: String, CaseIterable, Identifiable, Codable, Sendable {
    case none = "", w8, w11, w12, w15, w21, w25, w47, w58

    var id: String { rawValue }

    /// The Wratten number, as photographers name the filter.
    var number: String { String(rawValue.dropFirst()) }

    var title: String {
        switch self {
        case .none: String(localized: "None", bundle: .ui)
        case .w8: String(localized: "Yellow 8", bundle: .ui)
        case .w11: String(localized: "Yellow-green 11", bundle: .ui)
        case .w12: String(localized: "Deep yellow 12", bundle: .ui)
        case .w15: String(localized: "Deep yellow 15", bundle: .ui)
        case .w21: String(localized: "Orange 21", bundle: .ui)
        case .w25: String(localized: "Red 25", bundle: .ui)
        case .w47: String(localized: "Blue 47", bundle: .ui)
        case .w58: String(localized: "Green 58", bundle: .ui)
        }
    }

    /// What it does to a black-and-white picture, in a photographer's words.
    var effect: String {
        switch self {
        case .none: String(localized: "Every colour turns grey as the film sees it.", bundle: .ui)
        case .w8: String(localized: "Darkens a blue sky a little, so clouds stand out — the classic outdoor filter.", bundle: .ui)
        case .w11: String(localized: "Like yellow, and lightens foliage; flatters skin outdoors.", bundle: .ui)
        case .w12, .w15: String(localized: "Darkens a blue sky more and cuts haze.", bundle: .ui)
        case .w21: String(localized: "A dramatic sky, lighter skin and brick, less haze.", bundle: .ui)
        case .w25: String(localized: "A very dark sky and strong clouds; skin and red lips go pale.", bundle: .ui)
        case .w47: String(localized: "Lightens blue and darkens red and green: more haze, a moody look.", bundle: .ui)
        case .w58: String(localized: "Lightens foliage, darkens skin and red.", bundle: .ui)
        }
    }
}

/// Multigrade filter grades as the wire fields that print them.
struct PaperGrades: Sendable {
    struct Grade: Sendable {
        let c: Double, m: Double, y: Double
        /// What holds mid-grey at this grade; 1 at grade 2.
        let printExposure: Double
    }

    /// The paper the table is for (Ilford Multigrade IV RC).
    let paper: String
    let grades: [String: Grade]

    /// The grades in the order the paper's sheet lists them.
    static let order = ["00", "0", "1", "2", "3", "4", "5"]
    static let normal = "2"

    /// From the app's bundled `engine/paper_grades.json`; nil if it is missing,
    /// in which case the print stays at the Mac's grade 2.
    static let shared: PaperGrades? = {
        guard let url = Bundle.main.url(forResource: "engine", withExtension: nil)?
                .appending(path: "paper_grades.json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let paper = root["paper"] as? String,
              let table = root["grades"] as? [String: [String: Double]]
        else { return nil }
        var grades: [String: Grade] = [:]
        for (name, row) in table {
            guard let m = row["m_filter_neutral"], let y = row["y_filter_neutral"],
                  let e = row["print_exposure"] else { continue }
            grades[name] = Grade(c: row["c_filter_neutral"] ?? 0, m: m, y: y, printExposure: e)
        }
        return PaperGrades(paper: paper, grades: grades)
    }()
}

// MARK: - the controls

/// The lens filter, under the camera's white balance. Shows itself only while
/// a black-and-white film is chosen.
struct LensFilterSection: View {
    @ObservedObject var model: ProbeModel

    var body: some View {
        let current = model.settings.lensFilter
        if model.settings.filmIsMonochrome {
            PanelSection("Lens filter", trailing: {
                SectionButton("None") { model.settings.lensFilter = .none }
                    .disabled(current == .none)
            }) {
                FlowLayout(spacing: 8) {
                    ForEach(LensFilter.allCases.filter { $0 != .none }) { filter in
                        Chip(verbatim: filter.title, selected: current == filter) {
                            model.settings.lensFilter = current == filter ? .none : filter
                        }
                    }
                }
                Caption(verbatim: current.effect)
                Caption("A colour filter on a black-and-white camera: colours of its own hue print lighter, the opposite ones darker. Mid-grey keeps its exposure.")
            }
            .disabled(!model.hasPhoto || model.busy != nil)
        }
    }
}

/// The Multigrade grade, for the Print tool. Shows itself only while a
/// black-and-white film is printed on the paper the grades table is for.
struct PaperGradeSection: View {
    @ObservedObject var model: ProbeModel

    var body: some View {
        let s = model.settings
        if s.filmIsMonochrome, s.printIsMonochrome, PaperGrades.shared?.paper == s.printStock {
            PanelSection("Paper grade", trailing: {
                SectionButton("Normal") { model.settings.paperGrade = PaperGrades.normal }
                    .disabled(s.paperGrade == PaperGrades.normal)
            }) {
                // The seven grades read as one scale, so one row: tighter than
                // the panel's other chips (all seven take about 292 pt of the
                // 340 pt panel), wrapping only when a larger text size needs it.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) { gradeChips(s) }
                    FlowLayout(spacing: 8) { gradeChips(s) }
                }
                Caption("The Multigrade filter on the enlarger: 00 prints the softest, 5 the hardest, 2 is normal. Mid-grey stays where it is.")
            }
            .disabled(!model.hasPhoto || model.busy != nil)
        }
    }

    private func gradeChips(_ s: FilmSettings) -> some View {
        ForEach(PaperGrades.order, id: \.self) { grade in
            Chip(verbatim: grade, selected: s.paperGrade == grade) {
                model.settings.paperGrade = grade
            }
        }
    }
}
