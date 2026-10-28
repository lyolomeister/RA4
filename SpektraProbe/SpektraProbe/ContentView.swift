//  ContentView.swift — the window: canvas first.
//
//  The photograph takes the screen. A strip of six tools on the right, in
//  darkroom order (the negative: film, exposure, effects; the print; the
//  finish: adjust, export), opens one panel at a time beside it, or none. The
//  library is a column on the left that can be put away. On an iPhone, or an
//  iPad in a narrow window, the strip becomes a bar along the bottom and the
//  panel sits between it and the picture.
//
//  The canvas owns every touch on the picture (`CanvasView`): pinch to zoom,
//  double-tap for 100 %, hold for the original, swipe sideways at fit for the
//  next or previous photo, and a single tap shows the picture alone.

import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = ProbeModel()
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.scenePhase) private var scenePhase

    /// The open tool's raw value, or "" for none: kept across launches.
    @AppStorage("RA4.tool") private var toolRaw = Tool.film.rawValue
    @AppStorage("RA4.library") private var libraryShown = true
    @State private var focus = false
    @State private var picking = false
    @State private var pickingPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var settingsShown = false
    @State private var librarySheetShown = false

    private var tool: Tool? { Tool(rawValue: toolRaw) }

    var body: some View {
        GeometryReader { geometry in
            Group {
                if verticalSizeClass == .compact {
                    // A phone on its side: too short to stack a panel under
                    // the picture, so the panel goes beside it, as on an iPad.
                    regularLayout(width: geometry.size.width, phone: true)
                } else if sizeClass == .compact || geometry.size.width < 760 {
                    // A phone upright, the iPhone Duo's inner screen, an iPad
                    // in a narrow Split View: a panel beside the picture would
                    // leave it a strip.
                    compactLayout(height: geometry.size.height)
                } else {
                    regularLayout(width: geometry.size.width, phone: false)
                }
            }
        }
        .background(Theme.rail.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
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
        .sheet(isPresented: $settingsShown) { SettingsSheet(model: model) }
        .sheet(isPresented: $librarySheetShown) {
            LibraryGrid(model: model) { librarySheetShown = false }
                .presentationDetents([.medium, .large])
        }
        // Leaving the screen saves; coming back picks up photos added in Files.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refreshLibrary() } else { model.appLeavingScreen() }
        }
        .task { await demoEnlargerIfAsked() }
        // `--show-settings`, passed only from the Mac, so the sheet can be
        // screenshotted without a tap.
        .onAppear { if ProcessInfo.processInfo.arguments.contains("--show-settings") { settingsShown = true } }
    }

    /// `--demo-enlarger <film id>`, passed only from the Mac: two seconds after
    /// the photo opens, choose that film, so the enlarger transition can be
    /// screen-recorded without anyone tapping.
    private func demoEnlargerIfAsked() async {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--demo-enlarger"), i + 1 < args.count else { return }
        while !model.hasPhoto || model.busy != nil { try? await Task.sleep(for: .milliseconds(200)) }
        try? await Task.sleep(for: .seconds(2))
        model.selectFilm(args[i + 1])
    }

    // MARK: layouts

    /// iPad: library · picture · panel · strip. Below 1000 pt (an iPad held
    /// upright) the library steps aside while a panel is open, so the picture
    /// keeps a useful width. A phone on its side (`phone`) has no room for the
    /// library column, so its library is a sheet, and the panel is narrower.
    private func regularLayout(width: CGFloat, phone: Bool) -> some View {
        let narrow = width < 1000
        let libraryVisible = !phone && libraryShown && !focus && (!narrow || tool == nil)
        return VStack(spacing: 0) {
            if !focus {
                topBar(libraryInSheet: phone, narrow: narrow, tight: false)
                Theme.hairline.frame(height: 1)
            }
            HStack(spacing: 0) {
                if libraryVisible {
                    LibraryColumn(model: model)
                        .frame(width: Theme.libraryWidth)
                        .transition(.move(edge: .leading))
                    Theme.hairline.frame(width: 1)
                }
                canvasArea
                if let tool, !focus {
                    Theme.hairline.frame(width: 1)
                    ToolPanel(tool: tool, model: model, open: open)
                        .frame(width: phone ? Theme.phonePanelWidth : Theme.panelWidth)
                        .transition(.move(edge: .trailing))
                }
                if !focus {
                    Theme.hairline.frame(width: 1)
                    toolStrip
                        .frame(width: Theme.stripWidth)
                }
            }
            // Down to the screen's edge: the home indicator floats over the
            // canvas surround, not over a band of rail below it.
            .ignoresSafeArea(.container, edges: .bottom)
        }
    }

    /// iPhone: bar · picture · panel · tools.
    private func compactLayout(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            if !focus {
                topBar(libraryInSheet: true, narrow: true, tight: true)
                Theme.hairline.frame(height: 1)
            }
            canvasArea
            if let tool, !focus {
                Theme.hairline.frame(height: 1)
                ToolPanel(tool: tool, model: model, open: open)
                    .frame(height: min(380, height * 0.46))
                    .transition(.move(edge: .bottom))
            }
            if !focus {
                Theme.hairline.frame(height: 1)
                HStack(spacing: 0) {
                    ForEach(Tool.allCases) { t in
                        StripButton(tool: t, selected: tool == t, fills: true) { toggle(t) }
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
                .background(Theme.rail)
            }
        }
    }

    private func toggle(_ t: Tool) {
        withAnimation(.snappy(duration: 0.25)) { toolRaw = tool == t ? "" : t.rawValue }
    }

    private func open(_ t: Tool) {
        withAnimation(.snappy(duration: 0.25)) { toolRaw = t.rawValue }
    }

    // MARK: the bar

    /// The bar: library and import on the left, the photo in the middle,
    /// before/after, undo, redo and Settings on the right. `tight` (a phone
    /// upright) gives the name whatever room the buttons leave and drops the
    /// ‹ › arrows, which a swipe on the picture replaces; centred, a long name
    /// ran under the buttons.
    private func topBar(libraryInSheet: Bool, narrow: Bool, tight: Bool) -> some View {
        Group {
            if tight {
                HStack(spacing: 2) {
                    barLeading(libraryInSheet: libraryInSheet, narrow: narrow)
                    // The whole name when it fits; shortened while there is
                    // room for a useful part of it; else nothing — "L…G" says
                    // less than the library does.
                    ViewThatFits(in: .horizontal) {
                        photoTitle(subtitle: false).fixedSize()
                        photoTitle(subtitle: false).frame(minWidth: 90)
                        Color.clear.frame(width: 1, height: 1)
                    }
                    .padding(.horizontal, 4)
                    .frame(maxWidth: .infinity)
                    .background { arrowKeys }
                    barTrailing
                }
            } else {
                ZStack {
                    HStack(spacing: 2) {
                        barLeading(libraryInSheet: libraryInSheet, narrow: narrow)
                        Spacer()
                        barTrailing
                    }
                    titleBlock
                        .frame(maxWidth: 460)
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Theme.barHeight)
        .background(Theme.rail)
    }

    private func barLeading(libraryInSheet: Bool, narrow: Bool) -> some View {
        HStack(spacing: 2) {
            BarButton("Library", symbol: "sidebar.left", active: !libraryInSheet && libraryShown) {
                if libraryInSheet {
                    librarySheetShown = true
                } else {
                    withAnimation(.snappy(duration: 0.25)) {
                        libraryShown.toggle()
                        // Upright, the library and a panel do not both fit.
                        if libraryShown && narrow { toolRaw = "" }
                    }
                }
            }
            Menu {
                Button("From Files…", systemImage: "folder") { picking = true }
                Button("From Photos…", systemImage: "photo.on.rectangle") { pickingPhotos = true }
            } label: {
                BarIcon(symbol: "plus")
            }
            .accessibilityLabel(Text("Import"))
            .disabled(model.busy != nil)
        }
    }

    private var barTrailing: some View {
        HStack(spacing: 2) {
            if model.rendering || model.busy != nil {
                ProgressView().controlSize(.small).padding(.horizontal, 6)
            }
            BarButton("Photo information", symbol: model.showingInfo ? "info.circle.fill" : "info.circle",
                      active: model.showingInfo) {
                model.showingInfo.toggle()
            }
            .keyboardShortcut("i", modifiers: [])
            .disabled(!model.hasPhoto)
            BarButton("Before and after", symbol: "square.split.2x1",
                      active: model.compare != .off) {
                model.compare = model.compare == .off ? .split : .off
            }
            .disabled(model.cropping || !model.hasPhoto)
            BarButton("Undo", symbol: "arrow.uturn.backward") { model.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!model.canUndo || model.busy != nil)
            BarButton("Redo", symbol: "arrow.uturn.forward") { model.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.canRedo || model.busy != nil)
            BarButton("Settings", symbol: "gearshape") { settingsShown = true }
        }
    }

    /// ← → without the arrows on screen (the tight bar), for a keyboard.
    private var arrowKeys: some View {
        ZStack {
            Button("Previous") { Task { await model.previous() } }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(!model.hasPrevious || model.busy != nil)
            Button("Next") { Task { await model.next() } }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(!model.hasNext || model.busy != nil)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    /// ‹ the photo's name, and what it is on › — the arrows step through the
    /// library (also ← → on a keyboard, or a swipe on the picture).
    private var titleBlock: some View {
        HStack(spacing: 4) {
            BarButton("Previous", symbol: "chevron.left") { Task { await model.previous() } }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(!model.hasPrevious || model.busy != nil)
            photoTitle(subtitle: true)
                .frame(maxWidth: .infinity)
            BarButton("Next", symbol: "chevron.right") { Task { await model.next() } }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(!model.hasNext || model.busy != nil)
        }
    }

    private func photoTitle(subtitle: Bool) -> some View {
        VStack(spacing: 1) {
            Text(verbatim: model.current?.name ?? AppName.current)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.text)
            if model.hasPhoto && subtitle {
                Text(verbatim: processLine)
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .lineLimit(1)
        .truncationMode(.middle)
    }

    /// "Portra 400 → Supra Endura": the film, and the paper it is printed on.
    private var processLine: String {
        let s = model.settings, catalog = StockCatalog.shared
        let film = Stocks.shortName(catalog.name(s.filmStock))
        if s.filmIsPositive { return film + " · " + String(localized: "slide, scanned") }
        if s.scanFilm { return film + " · " + String(localized: "negative, scanned") }
        return film + " → " + Stocks.shortName(catalog.name(s.printStock))
    }

    // MARK: the strip

    private var toolStrip: some View {
        ScrollView(.vertical, showsIndicators: false) { toolStripButtons }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: .infinity)
            .background(Theme.rail)
    }

    /// Scrolls only where it must: a phone on its side is shorter than seven tools.
    private var toolStripButtons: some View {
        VStack(spacing: 2) {
            ForEach(Array(Tool.allCases.enumerated()), id: \.element) { index, t in
                if index > 0 && t.beginsStage {
                    Theme.hairline.frame(width: 36, height: 1).padding(.vertical, 6)
                }
                StripButton(tool: t, selected: tool == t) { toggle(t) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
    }

    // MARK: the picture

    private var canvasArea: some View {
        ZStack {
            Theme.ground
            if let renderer = model.renderer {
                CanvasView(model: model, renderer: renderer,
                           onTap: {
                               guard model.hasPhoto else { return }
                               withAnimation(.snappy(duration: 0.25)) { focus.toggle() }
                           },
                           onSwipe: { forward in
                               guard model.busy == nil else { return }
                               Task { if forward { await model.next() } else { await model.previous() } }
                           })
            }
            if !model.hasPhoto && model.busy == nil {
                EmptyLibraryView(fromFiles: { picking = true }, fromPhotos: { pickingPhotos = true })
            }
            // The file's EXIF over the picture (PhotoInfo.swift); it stays up
            // through next and previous, so a roll can be read through.
            if model.showingInfo && model.hasPhoto {
                PhotoInfoOverlay(model: model)
                    .transition(.opacity)
            }
            VStack(spacing: 10) {
                if let note = model.crashNote {
                    Banner(text: note, dismiss: model.dismissCrashNote)
                }
                if let error = model.error {
                    Banner(text: error, dismiss: { model.error = nil })
                }
                Spacer()
                if let busy = model.busy {
                    BusyCapsule(text: busy)
                } else if model.pickingNeutral {
                    HintCapsule(text: Text("Tap something white or grey"), symbol: "eyedropper")
                }
            }
            .padding(14)
            .allowsHitTesting(model.crashNote != nil || model.error != nil)
            if let zoom = model.canvasZoomPercent {
                Text(verbatim: "\(zoom) %")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Theme.rail.opacity(0.85), in: Capsule())
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .animation(.easeOut(duration: 0.15), value: model.showingInfo)
        .accessibilityAction(named: Text("Show the photo alone")) { focus.toggle() }
    }
}

// MARK: - The bar's buttons

/// An icon in the top bar, 44 pt square for a finger.
struct BarIcon: View {
    let symbol: String
    var active = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(active ? Theme.accent : Theme.text)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }
}

struct BarButton: View {
    let title: LocalizedStringKey
    let symbol: String
    var active = false
    let action: () -> Void

    init(_ title: LocalizedStringKey, symbol: String, active: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.active = active
        self.action = action
    }

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            BarIcon(symbol: symbol, active: active).opacity(isEnabled ? 1 : 0.3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .hoverEffect(.highlight)
    }
}

/// One tool in the strip (or in the iPhone's bottom bar): its icon and name.
struct StripButton: View {
    let tool: Tool
    let selected: Bool
    /// Share a row's width (the iPhone's bottom bar) rather than 62 pt each.
    var fills = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: tool.symbol)
                    .font(.system(size: 19, weight: selected ? .semibold : .regular))
                    .frame(height: 22)
                Text(tool.label)
                    .font(.system(size: 11, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(selected ? Theme.accent : Theme.secondaryText)
            .frame(width: fills ? nil : 62, height: 56)
            .frame(maxWidth: fills ? .infinity : nil)
            .background(selected ? Theme.well : .clear, in: RoundedRectangle(cornerRadius: Theme.corner))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Over the picture

/// An error or a note, across the top of the picture, until dismissed.
struct Banner: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.danger)
            Text(verbatim: text)
                .font(.callout)
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark").font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Dismiss"))
        }
        .padding(12)
        .frame(maxWidth: 560)
        .background(Theme.rail.opacity(0.94), in: RoundedRectangle(cornerRadius: Theme.corner))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner).stroke(Theme.danger.opacity(0.5), lineWidth: 1))
    }
}

/// What the app is doing that the controls wait for: opening, exporting.
struct BusyCapsule: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small).tint(Theme.accent)
            Text(verbatim: text).font(.callout).foregroundStyle(Theme.text)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.rail.opacity(0.92), in: Capsule())
        .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
    }
}

/// A hint about what a tap on the picture will do now (the eyedropper).
struct HintCapsule: View {
    let text: Text
    let symbol: String

    var body: some View {
        Label { text } icon: { Image(systemName: symbol) }
            .font(.callout)
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Theme.rail.opacity(0.92), in: Capsule())
            .overlay(Capsule().stroke(Theme.accent.opacity(0.6), lineWidth: 1))
    }
}

/// The first thing a new library shows: the name, and the two ways in.
struct EmptyLibraryView: View {
    let fromFiles: () -> Void
    let fromPhotos: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 10) {
                Image("RA4Logo")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 148, height: 148)
                    .clipShape(RoundedRectangle(cornerRadius: 33, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 33, style: .continuous)
                        .stroke(Theme.hairline, lineWidth: 1))
                    .accessibilityHidden(true)
                Text(verbatim: "RA-4")
                    .font(.system(size: 44, weight: .heavy))
                    .kerning(1.5)
                    .foregroundStyle(Theme.text)
                    .padding(.top, 6)
                Text("Spectral darkroom")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(Theme.secondaryText)
            }
            VStack(spacing: 10) {
                Button(action: fromPhotos) {
                    Label("Import from Photos", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(WideButtonStyle(prominent: true))
                Button(action: fromFiles) {
                    Label("Import from Files", systemImage: "folder")
                }
                .buttonStyle(WideButtonStyle())
            }
            .frame(width: 280)
            Text("Photos you put in Files › On My iPad › \(AppName.current) appear here too.")
                .font(.footnote)
                .foregroundStyle(Theme.tertiaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .padding(24)
    }
}
