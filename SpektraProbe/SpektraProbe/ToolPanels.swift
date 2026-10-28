//  ToolPanels.swift — the six tools and their panels, in darkroom order.
//
//  The negative: Film (the stock), Camera (the RAW's white balance and lens
//  correction, the meter, film exposure and Scene Placement — where the scene
//  lands on the film), Effects (the frame's size and the film's grain,
//  halation, couplers and glare). The print: Print (the paper and its
//  switches). The finish: Crop (geometry, after the engine), Adjust (Layer 2,
//  one draw) and Export.
//
//  The controls, their ranges and their rules are the ones the probe's single
//  panel had, which are the Mac app's; only where they sit has changed.

import SwiftUI

enum Tool: String, CaseIterable, Identifiable {
    // `exposure` keeps its raw value, which the open tool is saved under.
    case film, exposure, effects, print, crop, adjust, export

    var id: String { rawValue }

    /// The name under the icon in the strip.
    var label: LocalizedStringKey {
        switch self {
        case .film: "Film"
        case .exposure: "Camera"
        case .effects: "Effects"
        case .print: "Print"
        case .crop: "Crop"
        case .adjust: "Adjust"
        case .export: "Export"
        }
    }

    /// The panel's own title, which can say more.
    var title: LocalizedStringKey {
        switch self {
        case .film: "Film"
        case .exposure: "Camera and exposure"
        case .effects: "Format and effects"
        case .print: "Paper and print"
        case .crop: "Crop"
        case .adjust: "Adjust"
        case .export: "Export"
        }
    }

    var symbol: String {
        switch self {
        case .film: "film"
        case .exposure: "camera.aperture"
        case .effects: "circle.hexagongrid"
        case .print: "printer"
        case .crop: "crop"
        case .adjust: "slider.horizontal.3"
        case .export: "square.and.arrow.up"
        }
    }

    /// The first tool of a stage — the print, the finish — gets a divider above it.
    var beginsStage: Bool { self == .print || self == .crop }
}

/// The open tool's panel: its title, then its controls in a scroll view.
struct ToolPanel: View {
    let tool: Tool
    @ObservedObject var model: ProbeModel
    /// Opens another tool (the Film panel's "Change paper").
    let open: (Tool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(tool.title)
                    .font(.headline)
                    .foregroundStyle(Theme.text)
                Spacer()
                if model.rendering {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 46)
            Theme.hairline.frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    switch tool {
                    case .film: FilmPanel(model: model, open: open)
                    case .exposure: ExposurePanel(model: model)
                    case .effects: EffectsPanel(model: model)
                    case .print: PrintPanel(model: model)
                    case .crop: CropPanel(model: model)
                    case .adjust: AdjustPanel(model: model)
                    case .export: ExportPanel(model: model)
                    }
                }
                .padding(16)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.immediately)
        }
        .background(Theme.rail)
    }
}

// MARK: - Film

/// Film names as their box says them: maker, the film, its speed.
enum Stocks {
    static func maker(_ name: String) -> String {
        String(name.split(separator: " ").first ?? "")
    }

    /// "Kodak Portra 400" → "Portra 400"; "Kodak Professional Supra Endura" →
    /// "Supra Endura".
    static func shortName(_ name: String) -> String {
        var words = name.split(separator: " ").map(String.init)
        if words.count > 1 { words.removeFirst() }
        if words.count > 1 && words.first == "Professional" { words.removeFirst() }
        return words.joined(separator: " ")
    }

    /// The speed in the name: the last run of two to four digits, so "Vision3
    /// 500T" is 500 and "Portra 800 (Push 1)" is 800.
    static func speed(_ name: String) -> String? {
        name.matches(of: #/\d{2,4}/#).last.map { String($0.output) }
    }

    /// The colour of the maker's boxes, as a band down the tile's edge.
    static func colour(_ maker: String) -> Color {
        switch maker {
        case "Kodak": Color(red: 0.98, green: 0.74, blue: 0.10)
        case "Fujifilm": Color(red: 0.16, green: 0.66, blue: 0.38)
        case "Ilford": Color(white: 0.86)
        case "CineStill": Color(red: 0.88, green: 0.24, blue: 0.24)
        default: Theme.secondaryText
        }
    }
}

struct FilmPanel: View {
    @ObservedObject var model: ProbeModel
    let open: (Tool) -> Void
    @State private var group = "Negative"

    private var catalog: StockCatalog { .shared }

    var body: some View {
        let s = model.settings
        let groups = catalog.filmGroups
        let stocks = groups.first { $0.title == group }?.stocks ?? []
        VStack(alignment: .leading, spacing: 16) {
            Picker("Film type", selection: $group) {
                ForEach(groups, id: \.title) { Text(LocalizedStringKey($0.title)).tag($0.title) }
            }
            .pickerStyle(.segmented)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                      spacing: 10) {
                ForEach(stocks) { stock in
                    FilmTile(stock: stock, selected: s.filmStock == stock.id) { model.selectFilm(stock.id) }
                }
            }
        }
        .disabled(model.busy != nil)
        .onAppear { group = groupTitle(of: s.filmStock) }
        .onChange(of: s.filmStock) { _, id in group = groupTitle(of: id) }

        PanelSection("Printed on") {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: paperName(s))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.text)
                    if s.filmIsPositive {
                        Caption("A slide film has no print stage: it is scanned as it is.")
                    } else if s.scanFilm {
                        Caption("Scanning the negative itself, orange mask and all.")
                    }
                }
                Spacer()
                Button("Change") { open(.print) }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .buttonStyle(.borderless)
                    .disabled(s.filmIsPositive)
            }
            .padding(14)
            .background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.corner))
        }
    }

    private func groupTitle(of film: String) -> String {
        catalog.filmGroups.first { $0.stocks.contains { $0.id == film } }?.title ?? "Negative"
    }

    private func paperName(_ s: FilmSettings) -> String {
        if s.filmIsPositive || s.scanFilm { return String(localized: "No print (scan the film)") }
        return catalog.name(s.printStock)
    }
}

/// A film as a tile: the maker's colour down the edge, the film's name, its
/// speed large.
struct FilmTile: View {
    let stock: Stock
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let maker = Stocks.maker(stock.name)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(verbatim: maker)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.secondaryText)
                    Spacer(minLength: 0)
                    if stock.isCine {
                        Text("Cine")
                            .font(.system(size: 9, weight: .bold))
                            .textCase(.uppercase)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .foregroundStyle(Theme.secondaryText)
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.tertiaryText, lineWidth: 1))
                    }
                }
                Text(verbatim: Stocks.shortName(stock.name))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                HStack(alignment: .lastTextBaseline, spacing: 3) {
                    if let speed = Stocks.speed(stock.name) {
                        Text(verbatim: speed)
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(selected ? Theme.accent : Theme.text.opacity(0.85))
                        Text(verbatim: "ISO")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.tertiaryText)
                    }
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                    }
                }
            }
            .padding(.leading, 16).padding(.trailing, 10).padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .background(selected ? Theme.wellPressed : Theme.well)
            .overlay(alignment: .leading) {
                Stocks.colour(maker).frame(width: 5)
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.corner))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner)
                .stroke(selected ? Theme.accent : .clear, lineWidth: 2))
            .contentShape(RoundedRectangle(cornerRadius: Theme.corner))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: stock.name))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Exposure

struct ExposurePanel: View {
    @ObservedObject var model: ProbeModel

    var body: some View {
        let s = model.settings
        CameraPanel(model: model)

        PanelSection("Metering", trailing: {
            SectionButton("As shot") { model.filmExposureAsShot() }
                .disabled(s.metering == .custom && s.exposureCompensationEV == 0)
        }) {
            FlowLayout(spacing: 8) {
                ForEach(Metering.allCases) { m in
                    Chip(LocalizedStringKey(m.title), selected: s.metering == m) {
                        model.settings.metering = m
                    }
                }
            }
            ParamSlider(title: "Film exposure", value: $model.settings.exposureCompensationEV,
                        range: -4...4, step: 1.0 / 3, format: { String(format: "%+.1f EV", $0) })
            Caption(s.metering == .custom
                    ? "Custom: the meter is off, so Film Exposure starts from the camera's own exposure."
                    : "The meter sets the film's exposure; Film Exposure is an offset from it.")
        }
        .disabled(model.busy != nil)

        PanelSection("Latitude") {
            if let reading = model.latitude {
                LatitudeChart(reading: reading)
            } else {
                Caption("Open a photo to measure how its scene fits the film.")
            }
        }

        let committed = s.placement
        PanelSection("Scene placement", trailing: {
            HStack(spacing: 14) {
                SectionButton("Suggest") { Task { await model.suggestPlacement() } }
                SectionButton("Off") { model.resetPlacement() }
                    .disabled(!committed.active && committed.highlightPullBack == 0 && committed.shadowPullBack == 0)
            }
        }) {
            ParamSlider(title: "Highlights pull-back", value: $model.highlightDraft,
                        range: ScenePlacement.range, step: 0.25,
                        format: Self.pullBack,
                        onRelease: { Task { await model.place(highlight: model.highlightDraft,
                                                              shadow: committed.shadowPullBack) } })
            ParamSlider(title: "Shadows pull-back", value: $model.shadowDraft,
                        range: ScenePlacement.range, step: 0.25,
                        format: Self.pullBack,
                        onRelease: { Task { await model.place(highlight: committed.highlightPullBack,
                                                              shadow: model.shadowDraft) } })
            if let note = model.placementNote {
                Label {
                    Text(verbatim: note)
                } icon: {
                    Image(systemName: "exclamationmark.circle")
                }
                .font(.callout)
                .foregroundStyle(Theme.warning)
            }
            Caption("Fits a scene wider than the film onto it: the highlights are pulled back, the shadows lifted, before the film sees them. The engine solves each change and refuses one it cannot place.")
        }
        .disabled(model.busy != nil || !model.hasPhoto)
    }

    private static let pullBack: (Double) -> String = {
        $0 == 0 ? String(localized: "off") : String(format: String(localized: "%.2f stops"), $0)
    }
}

/// The film and paper's latitude as an amber band on an EV scale, and the
/// scene's range as a white bar across it: what sticks out is what the film
/// cannot hold.
struct LatitudeChart: View {
    let reading: LatitudeReading

    var body: some View {
        let r = reading
        let valid = [r.filmShadowEV, r.filmHighlightEV, r.sceneDarkestEV, r.sceneBrightestEV].allSatisfy(\.isFinite)
        VStack(alignment: .leading, spacing: 10) {
            if valid {
                let lo = min(-8, (min(r.sceneDarkestEV, r.filmShadowEV) - 0.5).rounded(.down))
                let hi = max(8, (max(r.sceneBrightestEV, r.filmHighlightEV) + 0.5).rounded(.up))
                GeometryReader { g in
                    let w = g.size.width
                    let x = { (ev: Double) in CGFloat((ev - lo) / (hi - lo)) * w }
                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 4).fill(Theme.well)
                            .frame(height: 34).offset(y: 6)
                        RoundedRectangle(cornerRadius: 4).fill(Theme.accent.opacity(0.32))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.accent, lineWidth: 1))
                            .frame(width: max(2, x(r.filmHighlightEV) - x(r.filmShadowEV)), height: 34)
                            .offset(x: x(r.filmShadowEV), y: 6)
                        Capsule().fill(Theme.text)
                            .frame(width: max(2, x(r.sceneBrightestEV) - x(r.sceneDarkestEV)), height: 6)
                            .offset(x: x(r.sceneDarkestEV), y: 20)
                        Rectangle().fill(Theme.text.opacity(0.5))
                            .frame(width: 1, height: 44).offset(x: x(0), y: 1)
                        ForEach(Array(stride(from: (lo / 4).rounded(.up) * 4, through: hi, by: 4)), id: \.self) { ev in
                            Text(verbatim: ev == 0 ? "0" : String(format: "%+.0f", ev))
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(Theme.tertiaryText)
                                .fixedSize()
                                .frame(width: 30)
                                .offset(x: x(ev) - 15, y: 48)
                        }
                    }
                }
                .frame(height: 62)
                HStack(spacing: 16) {
                    legend(colour: Theme.accent.opacity(0.6),
                           text: String(format: String(localized: "Film and paper: %.1f stops"), r.stops))
                    legend(colour: Theme.text,
                           text: String(format: String(localized: "Scene: %.1f stops"),
                                        r.sceneBrightestEV - r.sceneDarkestEV))
                }
                let below = max(0, r.filmShadowEV - r.sceneDarkestEV)
                let above = max(0, r.sceneBrightestEV - r.filmHighlightEV)
                Caption(verbatim: below == 0 && above == 0
                        ? String(localized: "The whole scene fits on the film.")
                        : String(format: String(localized: "Outside the film: %.1f stops in the shadows, %.1f in the highlights."),
                                 below, above))
                if let h = r.suggestedHighlight, let s = r.suggestedShadow, h.isFinite, s.isFinite {
                    Caption(verbatim: String(format: String(localized: "Suggested pull-back: highlights %.2f, shadows %.2f stops."),
                                             h, s))
                }
            } else {
                Caption("The latitude could not be measured for this film and paper.")
            }
        }
    }

    private func legend(colour: Color, text: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(colour).frame(width: 12, height: 8)
            Text(verbatim: text).font(.caption).foregroundStyle(Theme.secondaryText)
        }
    }
}

// MARK: - Effects

struct EffectsPanel: View {
    @ObservedObject var model: ProbeModel

    var body: some View {
        let s = model.settings
        PanelSection("Film format") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Still").font(.caption).foregroundStyle(Theme.tertiaryText)
                FlowLayout(spacing: 8) {
                    ForEach(FilmFrame.still) { f in
                        Chip(LocalizedStringKey(f.id), selected: s.filmFrame == f.id) { model.setFrame(f.id) }
                    }
                }
                Text("Cine").font(.caption).foregroundStyle(Theme.tertiaryText).padding(.top, 4)
                FlowLayout(spacing: 8) {
                    ForEach(FilmFrame.cine) { f in
                        Chip(verbatim: f.id, selected: s.filmFrame == f.id) { model.setFrame(f.id) }
                    }
                }
            }
            Picker("Side", selection: Binding(get: { s.filmSide }, set: { model.setSide($0) })) {
                ForEach(FilmSide.allCases) { Text(LocalizedStringKey($0.title)).tag($0) }
            }
            .pickerStyle(.segmented)
            ParamSlider(title: "Side length", value: Binding(get: { s.sideLengthMM },
                                                               set: { model.setSideLength($0) }),
                        range: 4...120, step: 0.5, resetValue: 24, format: { String(format: "%.1f mm", $0) })
            Caption(verbatim: String(format: String(localized: "Long edge sent to the engine: %.1f mm. Grain and halation are sized in real micrometres, so a smaller format shows coarser grain. Moving Side length makes the type Custom."),
                                     s.filmFormatMM))
        }
        .disabled(model.busy != nil)

        PanelSection("Effects", trailing: {
            SectionButton("Reset") { model.resetEffects() }
                .disabled(s.effects == EffectStrengths())
        }) {
            EffectCard {
                SwitchRow("Grain", isOn: $model.settings.grainActive)
                ParamSlider(title: "Strength", value: $model.settings.effects.grain,
                            range: EffectStrengths.grainRange, step: 0.05, resetValue: 1, format: Self.times)
                    .disabled(!s.grainActive)
                if !s.filmIsMonochrome {
                    SwitchRow("Grain in three sub-layers", isOn: $model.settings.effects.grainLayered)
                        .disabled(!s.grainActive)
                }
            }
            EffectCard {
                SwitchRow("Halation", isOn: $model.settings.halationActive)
                Group {
                    ParamSlider(title: "Strength", value: $model.settings.effects.halation,
                                range: EffectStrengths.halationRange, step: 0.05, resetValue: 1, format: Self.times)
                    ParamSlider(title: "Scatter", value: $model.settings.effects.scatter,
                                range: EffectStrengths.scatterRange, step: 0.05, resetValue: 1, format: Self.times)
                    ParamSlider(title: "Highlight boost", value: $model.settings.effects.highlightBoost,
                                range: EffectStrengths.highlightBoostRange, step: 0.5,
                                format: { String(format: "%.1f EV", $0) })
                }
                .disabled(!s.halationActive)
                if s.filmHasNoAntihalationLayer {
                    Caption("This film has no anti-halation layer.")
                } else {
                    SwitchRow("Remove the anti-halation layer", isOn: $model.settings.effects.antihalationRemoved)
                }
                if s.filmHasNoAntihalationLayer || s.effects.antihalationRemoved {
                    ParamSlider(title: "Highlight headroom", value: $model.settings.effects.highlightHeadroom,
                                range: EffectStrengths.highlightHeadroomRange, step: 0.5, resetValue: 4,
                                format: { String(format: "%.1f EV", $0) })
                }
            }
            EffectCard {
                SwitchRow("Colour couplers", isOn: $model.settings.effects.couplersActive)
                ParamSlider(title: "Strength", value: $model.settings.effects.couplers,
                            range: EffectStrengths.couplersRange, step: 0.05, resetValue: 1, format: Self.times)
                    .disabled(!s.effects.couplersActive)
            }
            EffectCard {
                SwitchRow("Glare", isOn: $model.settings.glareActive)
                    .disabled(s.scanFilm || !s.printEffects)
                ParamSlider(title: "Strength", value: $model.settings.effects.glare,
                            range: EffectStrengths.glareRange, step: 0.5, resetValue: 1, format: Self.times)
                    .disabled(!s.glareActive || s.scanFilm || !s.printEffects)
                if s.scanFilm {
                    Caption("Glare is the print's, and a scanned film has no print.")
                } else if !s.printEffects {
                    Caption("Print effects is off in the Print panel.")
                }
            }
        }
        .disabled(model.busy != nil)
    }

    static let times: (Double) -> String = { String(format: "×%.2f", $0) }
}

// MARK: - Print

struct PrintPanel: View {
    @ObservedObject var model: ProbeModel

    private var catalog: StockCatalog { .shared }

    var body: some View {
        let s = model.settings
        PanelSection("Paper") {
            if s.filmIsPositive {
                Caption("A slide film has no print stage: it is scanned as it is.")
            }
            VStack(spacing: 0) {
                PaperRow(name: Text("No print (scan the film)"), detail: nil,
                         selected: s.scanFilm || s.filmIsPositive) { model.selectNoPrint() }
                ForEach(catalog.paperGroups(for: s.filmStock), id: \.title) { group in
                    HStack {
                        Text(LocalizedStringKey(group.title))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.tertiaryText)
                            .textCase(.uppercase)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 4)
                    ForEach(group.stocks) { paper in
                        PaperRow(name: Text(verbatim: Stocks.shortName(paper.name)),
                                 detail: catalog.isDeclaredPairing(film: s.filmStock, paper: paper.id)
                                    ? Text("The film's own paper") : nil,
                                 selected: !s.scanFilm && !s.filmIsPositive && s.printStock == paper.id) {
                            model.selectPaper(paper.id)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
            .background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.corner))
            .disabled(s.filmIsPositive)
            if s.scanFilm && !s.filmIsPositive {
                Caption("Scanning the negative itself, orange mask and all. Pick a paper to print it.")
            }
        }
        .disabled(model.busy != nil)

        // Shows itself only for a black-and-white film on Multigrade.
        PaperGradeSection(model: model)

        PanelSection("Print") {
            SwitchRow("Print effects", isOn: $model.settings.printEffects)
                .disabled(s.scanFilm)
            Caption("Glare and pre-flash. Off leaves the paper's colour transformation and nothing else.")
            SwitchRow("EDR (extended range)", isOn: $model.settings.extendedDynamicRange)
                .disabled(s.scanFilm || s.printIsMonochrome)
            Caption(s.printIsMonochrome
                    ? "The silver paper has no EDR calibration."
                    : "A calibrated per-paper profile with more room in the highlight shoulder and the toe. What you see is what the export carries.")
        }
        .disabled(model.busy != nil)
    }
}

struct PaperRow: View {
    let name: Text
    let detail: Text?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    name.font(.subheadline.weight(selected ? .semibold : .regular))
                        .foregroundStyle(Theme.text)
                    if let detail {
                        detail.font(.caption).foregroundStyle(Theme.accent.opacity(0.85))
                    }
                }
                Spacer()
                Image(systemName: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .opacity(selected ? 1 : 0)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Adjust

struct AdjustPanel: View {
    @ObservedObject var model: ProbeModel

    var body: some View {
        Group {
            PanelSection("White balance") {
                ParamSlider(title: "Temperature", value: $model.adjustments.temperature, range: -100...100,
                            ends: (Color(red: 0.35, green: 0.55, blue: 0.95), Color(red: 0.95, green: 0.75, blue: 0.3)))
                ParamSlider(title: "Tint", value: $model.adjustments.tint, range: -100...100,
                            ends: (Color(red: 0.35, green: 0.8, blue: 0.4), Color(red: 0.85, green: 0.35, blue: 0.8)))
            }
            PanelSection("Tone") {
                ParamSlider(title: "Exposure", value: $model.adjustments.exposure, range: -3...3, step: 0.01,
                            format: { String(format: "%+.2f EV", $0) })
                ParamSlider(title: "Contrast", value: $model.adjustments.contrast, range: -50...50)
                ParamSlider(title: "Highlights", value: $model.adjustments.highlights, range: -100...100)
                ParamSlider(title: "Shadows", value: $model.adjustments.shadows, range: -100...100)
                ParamSlider(title: "Black point", value: $model.adjustments.blackPoint, range: 0...50,
                            format: { String(format: "%.0f", $0) })
                ParamSlider(title: "White point", value: $model.adjustments.whitePoint, range: 0...50,
                            format: { String(format: "%.0f", $0) })
            }
            PanelSection("Colour") {
                ParamSlider(title: "Saturation", value: $model.adjustments.saturation, range: -100...100)
                ParamSlider(title: "Vibrance", value: $model.adjustments.vibrance, range: -100...100)
            }
            VStack(alignment: .leading, spacing: 10) {
                Button("Reset adjustments") { model.resetAdjustments() }
                    .buttonStyle(WideButtonStyle())
                    .disabled(model.adjustments.isNeutral)
                Caption("Adjustments work on the finished print and are instant. Double-tap a name to reset it.")
            }
        }
        .disabled(!model.hasPhoto)
    }
}

// MARK: - Export

struct ExportPanel: View {
    @ObservedObject var model: ProbeModel

    var body: some View {
        // JPEG, PNG or TIFF, its options, an estimated size and the button
        // (ImageExport.swift).
        ExportOptionsSection(model: model)

        if let url = model.lastExport {
            PanelSection("Last export") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: url.lastPathComponent)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let summary = model.lastExportSummary {
                        Text(verbatim: summary).font(.caption.monospacedDigit()).foregroundStyle(Theme.secondaryText)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.corner))
                ShareLink(item: url) {
                    Label("Share or save to Photos", systemImage: "square.and.arrow.up.on.square")
                }
                .buttonStyle(WideButtonStyle())
                Caption("Also saved in Files › On My iPad › \(AppName.current) › Exports.")
            }
        }
    }
}
