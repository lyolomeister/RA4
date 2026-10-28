//  ContentView.swift — the canvas, and a panel in the Mac app's order: film and
//  paper, camera, the film's effects, its format, Scene Placement, the print,
//  then the adjustments, export and the diagnostics the probe has always shown.

import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = ProbeModel()
    @State private var picking = false
    @State private var pickingPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @Environment(\.scenePhase) private var scenePhase
    @State private var open: Set<String> = ["film", "camera", "adjustments", "export"]
    @Environment(\.horizontalSizeClass) private var sizeClass

    private let scanTag = "__scan__"
    private var catalog: StockCatalog { .shared }

    var body: some View {
        NavigationStack {
            Group {
                if sizeClass == .compact {
                    VStack(spacing: 0) {
                        VStack(spacing: 0) { canvas; filmstrip }.frame(maxHeight: 460)
                        Divider()
                        panel
                    }
                } else {
                    HStack(spacing: 0) {
                        VStack(spacing: 0) { canvas; filmstrip }
                        Divider()
                        panel.frame(width: 380)
                    }
                }
            }
            .navigationTitle(AppName.current)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Menu {
                        Button("From Files…", systemImage: "folder") { picking = true }
                        Button("From Photos…", systemImage: "photo.on.rectangle") { pickingPhotos = true }
                    } label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                    }
                    .disabled(model.busy != nil)
                    Button("Previous", systemImage: "chevron.left") { Task { await model.previous() } }
                        .keyboardShortcut(.leftArrow, modifiers: [])
                        .disabled(!model.hasPrevious || model.busy != nil)
                    Button("Next", systemImage: "chevron.right") { Task { await model.next() } }
                        .keyboardShortcut(.rightArrow, modifiers: [])
                        .disabled(!model.hasNext || model.busy != nil)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Undo", systemImage: "arrow.uturn.backward") { model.undo() }
                        .keyboardShortcut("z", modifiers: .command)
                        .disabled(!model.canUndo || model.busy != nil)
                    Button("Redo", systemImage: "arrow.uturn.forward") { model.redo() }
                        .keyboardShortcut("z", modifiers: [.command, .shift])
                        .disabled(!model.canRedo || model.busy != nil)
                    Button("Copy results") { model.copyResults() }
                }
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.rawImage, .image],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await model.importFiles(urls) }
            case .failure(let error): model.error = error.localizedDescription
            }
        }
        .photosPicker(isPresented: $pickingPhotos, selection: $photoItems, matching: .images,
                      preferredItemEncoding: .current)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                await model.importFromPhotos(items)
                photoItems = []
            }
        }
        // Leaving the screen saves; coming back picks up photos added in Files.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refreshLibrary() } else { model.appLeavingScreen() }
        }
    }

    // MARK: the picture

    @ViewBuilder private var canvas: some View {
        ZStack {
            Color(white: 0.16)
            if let renderer = model.renderer {
                CanvasView(renderer: renderer, print: model.print,
                           uniforms: model.adjustments.uniforms, transform: model.displayTransform)
            }
            if !model.hasPhoto && model.busy == nil {
                Text("Import a photo: Import › From Files or From Photos.\nPhotos added to Files › On My iPad › \(AppName.current) appear here too.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.7))
                    .padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: the filmstrip

    /// The library, in name order: each photo as it was last left (the print,
    /// once opened), a dot on the edited ones, the open one outlined.
    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(model.photos) { photo in
                        Button { Task { await model.open(photo) } } label: { cell(photo) }
                            .buttonStyle(.plain)
                            .disabled(model.busy != nil)
                            .id(photo.name)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .frame(height: 92)
            .background(Color(white: 0.1))
            .onChange(of: model.current) { _, photo in
                if let photo { withAnimation { proxy.scrollTo(photo.name, anchor: .center) } }
            }
        }
    }

    private func cell(_ photo: LibraryPhoto) -> some View {
        let isOpen = model.current == photo
        return ZStack(alignment: .topTrailing) {
            Group {
                if let image = model.thumbnails[photo.name] {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Color(white: 0.2)
                }
            }
            .frame(width: 112, height: 74)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            if model.edited.contains(photo.name) {
                Circle().fill(.orange).frame(width: 8, height: 8).padding(5)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(isOpen ? Color.accentColor : .clear, lineWidth: 3))
        .accessibilityLabel(photo.name + (model.edited.contains(photo.name) ? ", edited" : ""))
    }

    // MARK: the panel

    private var panel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let note = model.crashNote { crashBanner(note) }
                if let busy = model.busy {
                    HStack(spacing: 8) { ProgressView(); Text(busy).font(.callout) }
                } else if model.rendering {
                    HStack(spacing: 8) { ProgressView(); Text("Rendering…").font(.callout) }
                }
                if let error = model.error {
                    Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
                group("film", "Film and paper") { filmAndPaper }
                group("camera", "Camera") { camera }
                group("effects", "Film effects") { effects }
                group("format", "Film format") { format }
                group("placement", "Scene placement") { placement }
                group("print", "Print") { print }
                group("adjustments", "Adjustments") { adjustmentsSection }
                group("export", "Export") { exportSection }
                group("diagnostics", "Diagnostics") { diagnostics }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(.secondarySystemBackground))
    }

    private func group<Content: View>(_ key: String, _ title: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        let built = content()
        return DisclosureGroup(isExpanded: Binding(get: { open.contains(key) },
                                                   set: { if $0 { open.insert(key) } else { open.remove(key) } })) {
            VStack(alignment: .leading, spacing: 10) { built }
                .padding(.top, 8)
        } label: {
            Text(title).font(.headline)
        }
    }

    // MARK: Layer 1 — the engine's settings

    private var filmAndPaper: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Film") {
                Picker("Film", selection: Binding(get: { model.settings.filmStock },
                                                  set: { model.selectFilm($0) })) {
                    ForEach(catalog.filmGroups, id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.stocks) { Text($0.name).tag($0.id) }
                        }
                    }
                }
            }
            LabeledContent("Paper") {
                Picker("Paper", selection: Binding(
                    get: { model.settings.scanFilm ? scanTag : model.settings.printStock },
                    set: { $0 == scanTag ? model.selectNoPrint() : model.selectPaper($0) })) {
                    Text("No print (scan the film)").tag(scanTag)
                    ForEach(catalog.paperGroups(for: model.settings.filmStock), id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.stocks) { Text($0.name).tag($0.id) }
                        }
                    }
                }
                .disabled(model.settings.filmIsPositive)
            }
            if model.settings.filmIsPositive {
                caption("A slide film has no print stage: it is scanned as it is.")
            } else if model.settings.scanFilm {
                caption("Scanning the negative itself, orange mask and all. Pick a paper to print it.")
            }
        }
        .pickerStyle(.menu)
        .disabled(model.busy != nil)
    }

    private var camera: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Metering") {
                Picker("Metering", selection: $model.settings.metering) {
                    ForEach(Metering.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
            }
            AdjustmentSlider(title: "Film exposure", value: $model.settings.exposureCompensationEV,
                             range: -4...4, step: 1.0 / 3, format: { String(format: "%+.1f EV", $0) })
            Button("As shot") { model.filmExposureAsShot() }
                .buttonStyle(.bordered)
                .disabled(model.settings.metering == .custom && model.settings.exposureCompensationEV == 0)
            caption(model.settings.metering == .custom
                    ? "Custom: the meter is off, so Film Exposure starts from the camera's own exposure."
                    : "The meter sets the film's exposure; Film Exposure is an offset from it.")
        }
        .disabled(model.busy != nil)
    }

    private var effects: some View {
        let s = model.settings
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer()
                Button("Reset") { model.resetEffects() }
                    .disabled(s.effects == EffectStrengths())
            }
            Toggle("Grain", isOn: $model.settings.grainActive)
            AdjustmentSlider(title: "Grain strength", value: $model.settings.effects.grain,
                             range: EffectStrengths.grainRange, step: 0.05, resetValue: 1, format: Self.times)
                .disabled(!s.grainActive)
            if !s.filmIsMonochrome {
                Toggle("Grain in three sub-layers", isOn: $model.settings.effects.grainLayered)
                    .disabled(!s.grainActive)
            }
            Divider()
            Toggle("Halation", isOn: $model.settings.halationActive)
            AdjustmentSlider(title: "Halation strength", value: $model.settings.effects.halation,
                             range: EffectStrengths.halationRange, step: 0.05, resetValue: 1, format: Self.times)
                .disabled(!s.halationActive)
            AdjustmentSlider(title: "Scatter", value: $model.settings.effects.scatter,
                             range: EffectStrengths.scatterRange, step: 0.05, resetValue: 1, format: Self.times)
                .disabled(!s.halationActive)
            AdjustmentSlider(title: "Highlight boost", value: $model.settings.effects.highlightBoost,
                             range: EffectStrengths.highlightBoostRange, step: 0.5,
                             format: { String(format: "%.1f EV", $0) })
                .disabled(!s.halationActive)
            if s.filmHasNoAntihalationLayer {
                caption("This film has no anti-halation layer.")
            } else {
                Toggle("Remove the anti-halation layer", isOn: $model.settings.effects.antihalationRemoved)
            }
            if s.filmHasNoAntihalationLayer || s.effects.antihalationRemoved {
                AdjustmentSlider(title: "Highlight headroom", value: $model.settings.effects.highlightHeadroom,
                                 range: EffectStrengths.highlightHeadroomRange, step: 0.5, resetValue: 4,
                                 format: { String(format: "%.1f EV", $0) })
            }
            Divider()
            Toggle("Colour couplers", isOn: $model.settings.effects.couplersActive)
            AdjustmentSlider(title: "Coupler strength", value: $model.settings.effects.couplers,
                             range: EffectStrengths.couplersRange, step: 0.05, resetValue: 1, format: Self.times)
                .disabled(!s.effects.couplersActive)
            Divider()
            Toggle("Glare", isOn: $model.settings.glareActive)
                .disabled(s.scanFilm || !s.printEffects)
            AdjustmentSlider(title: "Glare strength", value: $model.settings.effects.glare,
                             range: EffectStrengths.glareRange, step: 0.5, resetValue: 1, format: Self.times)
                .disabled(!s.glareActive || s.scanFilm || !s.printEffects)
        }
        .disabled(model.busy != nil)
    }

    private var format: some View {
        let s = model.settings
        return VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Film type") {
                Picker("Film type", selection: Binding(get: { s.filmFrame }, set: { model.setFrame($0) })) {
                    Section("Still") { ForEach(FilmFrame.still) { Text($0.id).tag($0.id) } }
                    Section("Cine") { ForEach(FilmFrame.cine) { Text($0.id).tag($0.id) } }
                }
                .pickerStyle(.menu)
            }
            Picker("Side", selection: Binding(get: { s.filmSide }, set: { model.setSide($0) })) {
                ForEach(FilmSide.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            AdjustmentSlider(title: "Side length", value: Binding(get: { s.sideLengthMM },
                                                                    set: { model.setSideLength($0) }),
                             range: 4...120, step: 0.5, resetValue: 24, format: { String(format: "%.1f mm", $0) })
            caption(String(format: "Long edge sent to the engine: %.1f mm. Grain and halation are sized in real micrometres, so a smaller format shows coarser grain. Moving Side length makes the type Custom.",
                           s.filmFormatMM))
        }
        .disabled(model.busy != nil)
    }

    private var placement: some View {
        let committed = model.settings.placement
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(model.latitudeLines, id: \.self) { line in
                Text(line).font(.system(.caption, design: .monospaced))
            }
            AdjustmentSlider(title: "Highlights pull-back", value: $model.highlightDraft,
                             range: ScenePlacement.range, step: 0.25,
                             format: { $0 == 0 ? "off" : String(format: "%.2f stops", $0) },
                             onRelease: { Task { await model.place(highlight: model.highlightDraft,
                                                                   shadow: committed.shadowPullBack) } })
            AdjustmentSlider(title: "Shadows pull-back", value: $model.shadowDraft,
                             range: ScenePlacement.range, step: 0.25,
                             format: { $0 == 0 ? "off" : String(format: "%.2f stops", $0) },
                             onRelease: { Task { await model.place(highlight: committed.highlightPullBack,
                                                                   shadow: model.shadowDraft) } })
            HStack {
                Button("Suggest") { Task { await model.suggestPlacement() } }
                    .buttonStyle(.bordered)
                Button("Off") { model.resetPlacement() }
                    .buttonStyle(.bordered)
                    .disabled(!committed.active && committed.highlightPullBack == 0 && committed.shadowPullBack == 0)
            }
            if let note = model.placementNote {
                Text(note).font(.callout).foregroundStyle(.orange)
            }
            caption("Fits a scene wider than the film onto it: the highlights are pulled back, the shadows lifted, before the film sees them. The engine solves each change and refuses one it cannot place.")
        }
        .disabled(model.busy != nil || !model.hasPhoto)
    }

    private var print: some View {
        let s = model.settings
        return VStack(alignment: .leading, spacing: 8) {
            Toggle("Print effects", isOn: $model.settings.printEffects)
                .disabled(s.scanFilm)
            caption("Glare and pre-flash. Off leaves the paper's colour transformation and nothing else.")
            Toggle("EDR (extended range)", isOn: $model.settings.extendedDynamicRange)
                .disabled(s.scanFilm || s.printIsMonochrome)
            caption(s.printIsMonochrome
                    ? "The silver paper has no EDR calibration."
                    : "A calibrated per-paper profile with more room in the highlight shoulder and the toe. What you see is what the export carries.")
        }
        .disabled(model.busy != nil)
    }

    // MARK: Layer 2, export, diagnostics

    private var adjustmentsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer()
                Button("Reset") { model.resetAdjustments() }
                    .disabled(model.adjustments.isNeutral)
            }
            Text("White balance").font(.subheadline).foregroundStyle(.secondary)
            AdjustmentSlider(title: "Temperature", value: $model.adjustments.temperature, range: -100...100)
            AdjustmentSlider(title: "Tint", value: $model.adjustments.tint, range: -100...100)
            Text("Tone").font(.subheadline).foregroundStyle(.secondary)
            AdjustmentSlider(title: "Exposure", value: $model.adjustments.exposure, range: -3...3, step: 0.01,
                             format: { String(format: "%+.2f EV", $0) })
            AdjustmentSlider(title: "Contrast", value: $model.adjustments.contrast, range: -50...50)
            AdjustmentSlider(title: "Highlights", value: $model.adjustments.highlights, range: -100...100)
            AdjustmentSlider(title: "Shadows", value: $model.adjustments.shadows, range: -100...100)
            AdjustmentSlider(title: "Black point", value: $model.adjustments.blackPoint, range: 0...50,
                             format: { String(format: "%.0f", $0) })
            AdjustmentSlider(title: "White point", value: $model.adjustments.whitePoint, range: 0...50,
                             format: { String(format: "%.0f", $0) })
            Text("Colour").font(.subheadline).foregroundStyle(.secondary)
            AdjustmentSlider(title: "Saturation", value: $model.adjustments.saturation, range: -100...100)
            AdjustmentSlider(title: "Vibrance", value: $model.adjustments.vibrance, range: -100...100)
            caption("Double-tap a name to reset it.")
        }
        .disabled(!model.hasPhoto)
    }

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            AdjustmentSlider(title: "JPEG quality", value: $model.exportQuality, range: 10...100, resetValue: 95,
                             format: { String(format: "%.0f", $0) })
            HStack {
                Button("Export JPEG (sRGB)") { Task { await model.exportJPEG() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.hasPhoto || model.busy != nil)
                if let url = model.lastExport {
                    ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
                }
            }
            ForEach(model.exportLines, id: \.self) { line in
                Text(line).font(.system(.caption, design: .monospaced))
            }
        }
        .textSelection(.enabled)
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button("Render full resolution") { Task { await model.renderFull() } }
                .buttonStyle(.bordered)
                .disabled(!model.hasPhoto || model.busy != nil)
            section("Full-resolution render", model.fullLines)
            section("Preview", model.previewLines)
            section("Photo", model.photoLines)
            section("Device", model.deviceLines)
        }
    }

    @ViewBuilder private func section(_ title: String, _ lines: [String]) -> some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.bold())
                ForEach(lines, id: \.self) { line in
                    Text(line).font(.system(.caption, design: .monospaced))
                }
            }
            .textSelection(.enabled)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    private static let times: (Double) -> String = { String(format: "×%.2f", $0) }

    private func crashBanner(_ note: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(note).font(.callout).textSelection(.enabled)
            Button("Dismiss") { model.dismissCrashNote() }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A labelled slider with its value; double-tapping the label resets it.
/// `onRelease` runs when a drag ends, for a control the engine solves on
/// release (Scene Placement) rather than on every step.
struct AdjustmentSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var resetValue: Double = 0
    var format: (Double) -> String = { String(format: "%+.0f", $0) }
    var onRelease: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value)).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.callout)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                value = resetValue
                onRelease?()
            }
            Slider(value: $value, in: range, step: step) { editing in
                if !editing { onRelease?() }
            }
        }
    }
}
