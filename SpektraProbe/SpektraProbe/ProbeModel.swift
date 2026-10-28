//  ProbeModel.swift — the app's steps, and the numbers each one reports.
//
//  Every engine call runs on one serial queue (the engine is not thread-safe)
//  and the main actor only shows results. The colour chain is the Mac app's:
//  the engine prints in ProPhoto RGB, Layer 2 (`Adjustments`) grades in
//  ProPhoto, and the picture leaves ProPhoto exactly once per destination —
//  Display P3 for the canvas, sRGB for a JPEG export — through the engine's
//  own output transform.

import ImageIO
import Metal
import PhotosUI
import SwiftUI
import UIKit

/// The engine and its fetched colour transforms live here and are touched
/// only on `ProbeModel.queue`.
final class EngineBox: @unchecked Sendable {
    var engine: Engine?
    var transforms: [String: ColourTransform] = [:]
    /// The photo the engine's session holds, and the camera decode it was
    /// read with — set when an open has finished, cleared the moment one
    /// starts to replace the session. A failed open compares these with what
    /// the screen shows, because an open that fails after the engine took the
    /// new frame leaves the engine on a photo the screen is not showing.
    var sessionFile: URL?
    var sessionCamera: CameraDecode?
}

/// A marker on disk while a memory-heavy step runs. iOS ends an app that
/// exceeds its limit without warning, so the only way to report that is to
/// leave a note before the step and find it at the next launch. The sampler
/// writes the running peak into it every 0.2 s.
enum InFlight {
    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "in-flight.plist")
    }
    private static let lock = NSLock()

    static func begin(stage: String, details: [String: Any]) {
        var note = details
        note["stage"] = stage
        note["started"] = Date().timeIntervalSince1970
        note["availableBefore"] = Double(Memory.available())
        note["peak"] = Double(Memory.footprint())
        write(note)
    }

    static func update(peak: UInt64, minAvailable: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard var note = read() else { return }
        note["peak"] = Double(peak)
        note["minAvailable"] = Double(minAvailable)
        writeLocked(note)
    }

    static func end() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }

    /// The note a previous launch left behind, removed as it is read.
    static func takeLeftover() -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        let note = read()
        try? FileManager.default.removeItem(at: url)
        return note
    }

    private static func read() -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    private static func write(_ note: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        writeLocked(note)
    }

    private static func writeLocked(_ note: [String: Any]) {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: note, format: .binary, options: 0)
        else { return }
        try? data.write(to: url, options: .atomic)
    }
}

struct OpenOutcome {
    var file = ""
    var width = 0, height = 0
    var isRAW = true
    var frameBytes = 0
    var viaMetalBuffer = true
    var decodeSeconds = 0.0
    var openSeconds = 0.0
    var peakFootprint: UInt64 = 0
    /// The working space, as the engine's open reply names it.
    var workingSpace = ColourTransform.defaultWorkingSpace
    /// What the export carries from the photo (`ImageExport.sourceMetadata`).
    var sourceMetadata: [CFString: Any]?
    var preview = PreviewOutcome()
    var display: ColourTransform?
    /// The settings the frame was opened with (the film format derived from
    /// its aspect), and exactly what was sent, so later edits go as deltas.
    var settings = FilmSettings()
    var sentWire: [String: ParamValue] = [:]
    var latitude: [String: Any] = [:]
    /// The camera decode the frame was read with, and what the RAW said.
    var camera = CameraDecode()
    var asShot: AsShot?
    var lensCorrectionSupported = false
}

/// Before/after on the canvas: off, or the photograph without the film left
/// of a divider. Holding a finger on the picture shows it whole, either way.
enum CompareMode: Equatable { case off, split }

/// Scene Latitude's measurement (`spk_scene_latitude`): the film and paper's
/// latitude, and the scene's extremes, in EV around mid-grey.
struct LatitudeReading: Equatable {
    var stops: Double
    var filmShadowEV: Double
    var filmHighlightEV: Double
    var sceneDarkestEV: Double
    var sceneBrightestEV: Double
    var suggestedHighlight: Double?
    var suggestedShadow: Double?
}

struct PreviewOutcome {
    /// The engine's live print, ROMM-encoded. The texture owns its pixels.
    var print: MTLTexture?
    var width = 0, height = 0
    var seconds = 0.0
    var engineMs = 0.0
    /// The Scene Latitude measurement taken after it (`spk_scene_latitude`).
    var latitude: [String: Any] = [:]
}

struct FullOutcome {
    var succeeded = false
    var error = ""
    var width = 0, height = 0
    var availableBefore: UInt64 = 0
    var footprintBefore: UInt64 = 0
    var peak: UInt64 = 0
    var minAvailable: UInt64 = 0
    var footprintAfter: UInt64 = 0
    var lifetimePeak: UInt64 = 0
    var seconds = 0.0
    var engineMs = 0.0
    var enginePoolHighWater = 0.0
    var engineTotal = 0.0
}

struct ExportOutcome {
    var url: URL?
    var bytes = 0
    var width = 0, height = 0
    var availableBefore: UInt64 = 0
    var peak: UInt64 = 0
    var minAvailable: UInt64 = 0
    var renderSeconds = 0.0
    var gpuSeconds = 0.0
    var writeSeconds = 0.0
    var totalSeconds = 0.0
    var outsideFraction = 0.0
    var clippedFraction = 0.0
}

@MainActor
final class ProbeModel: ObservableObject {
    /// The engine's settings for the open frame (Layer 1): film and paper,
    /// camera, format, the film's effects, Scene Placement, print. Sent as deltas.
    @Published var settings = FilmSettings() { didSet { settingsDidChange() } }
    @Published var adjustments = Adjustments() { didSet { editHappened() } }
    /// JPEG quality, 10…100. The Mac app's default is 0.95.
    /// Format, JPEG quality and TIFF depth (`ImageExport.swift`), remembered
    /// between launches.
    @Published var exportOptions = ExportOptions.load() {
        didSet { if exportOptions != oldValue { exportOptions.save(); scheduleEstimate() } }
    }
    /// JPEG quality, 10…100: `exportOptions.quality` under its old name.
    var exportQuality: Double {
        get { exportOptions.quality }
        set { exportOptions.quality = newValue }
    }
    /// The export's size, estimated from the preview ("≈ 20 MB"); nil until one is.
    @Published private(set) var exportEstimate: String?
    private(set) var exportEstimateBytes: Int?
    /// The Export panel is up, so the estimate is worth keeping current.
    @Published var exportPanelShown = false { didSet { if exportPanelShown { scheduleEstimate() } } }
    private var estimateTask: Task<Void, Never>?
    @Published var busy: String?
    @Published var error: String?
    @Published var crashNote: String?
    @Published var hasPhoto = false
    /// A settings change is rendering. Unlike `busy`, the controls stay live,
    /// so a slider keeps tracking and its latest value is what renders next.
    @Published private(set) var rendering = false
    /// Scene Placement's sliders while dragged; the committed pull-backs are
    /// `settings.placement`'s, and a refused fit puts these back on them.
    @Published var highlightDraft = 0.0
    @Published var shadowDraft = 0.0
    /// Why the last placement was refused, in words, or nil.
    @Published private(set) var placementNote: String?
    @Published private(set) var latitudeLines: [String] = []
    /// The same measurement as numbers, for the Exposure panel's drawing.
    @Published private(set) var latitude: LatitudeReading?

    /// What the canvas draws: the live print and the working space → P3 transform.
    @Published private(set) var print: MTLTexture?
    @Published private(set) var displayTransform: ColourTransform?
    @Published private(set) var lastExport: URL?
    /// The last export in words: its size, megabytes and quality.
    @Published private(set) var lastExportSummary: String?

    @Published var deviceLines: [String] = []
    @Published var photoLines: [String] = []
    @Published var previewLines: [String] = []
    @Published var fullLines: [String] = []
    @Published var exportLines: [String] = []
    /// The zoomed canvas's full-resolution renders, and the camera rereads.
    @Published var viewerLines: [String] = []

    /// The library (`Library.swift`) and the photo that is open.
    @Published private(set) var photos: [LibraryPhoto] = []
    @Published private(set) var current: LibraryPhoto?
    @Published private(set) var thumbnails: [String: UIImage] = [:]
    /// Photos with edits of their own — the filmstrip's dot.
    @Published private(set) var edited: Set<String> = []
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    /// How the library is ordered, and its favourites (`LibraryIndex`).
    @Published private(set) var librarySort = LibrarySort.name
    @Published private(set) var favorites: Set<String> = []
    private var libraryIndex = LibraryIndex.load()

    // MARK: geometry, viewer and camera decode

    /// Crop, straighten, quarter turns and flips (the Mac's `Geometry`). The
    /// canvas, the thumbnail and every export go through it; the engine never
    /// sees it, so changing it costs a redraw and no render.
    @Published var geometry = Geometry() { didSet { if geometry != oldValue { editHappened() } } }
    /// The camera's white balance and lens correction, applied when the RAW is
    /// read; a change reads it again (`reopenForCamera`).
    @Published var camera = CameraDecode() { didSet { if camera != oldValue { cameraDidChange() } } }
    /// The RAW's own white balance, and whether it carries a lens correction.
    @Published private(set) var asShot: AsShot?
    @Published private(set) var lensCorrectionSupported = false
    @Published private(set) var photoIsRAW = false
    /// The crop tool is up: the canvas shows the whole frame and the handles.
    @Published var cropping = false
    @Published var compare: CompareMode = .off { didSet { if compare != .off { ensureBefore() } } }
    /// The white balance eyedropper is armed: the next tap on the picture measures.
    @Published var pickingNeutral = false
    /// The canvas's zoom for a label, set when a gesture ends; nil at fit.
    @Published var canvasZoomPercent: Int?
    /// The photo's information card is over the picture (`PhotoInfoOverlay`).
    /// Stays up while moving between photos, so it can be read along a roll.
    @Published var showingInfo = false
    /// The photograph without the film, at preview size, in Display P3.
    @Published private(set) var before: MTLTexture?
    /// The full-resolution print for a zoomed-in canvas, while it is the
    /// print of what the controls say (cleared by every new preview).
    @Published private(set) var fullPrint: MTLTexture?

    let renderer: Renderer?
    /// The negative-and-light transition on a change of film or paper.
    let enlarger = EnlargerTransition()
    private let queue = DispatchQueue(label: "SpektraProbe.engine", qos: .userInitiated)
    private let device: MTLDevice = MTLCreateSystemDefaultDevice()!
    private let box = EngineBox()
    private var opened: OpenOutcome?
    private var previewEdge = 2560
    /// What the engine was last told, field by field.
    private var sentWire: [String: ParamValue] = [:]
    /// An edit arrived while a render was running.
    private var pendingPush = false
    /// What the open frame was read with.
    private var appliedCamera = CameraDecode()
    private var reopening = false
    private var pendingReopen = false
    /// A photo is being opened: its engine work is queued or running.
    private var opening = false
    private var fullInFlight = false
    /// Bumped by every new preview, so a full render that lands after an edit
    /// is not shown as the edit's.
    private var previewGeneration = 0
    private var beforeTask: Task<Void, Never>?
    /// Engine calls running now, and how many times the app has gone to the
    /// background. iOS lets no app use the GPU there, so engine work that was
    /// running when the app left the screen cannot be trusted, and an export
    /// that spans a trip to the background is not kept.
    private var engineJobs = 0
    private var backgroundEntries = 0
    private var engineWorkInterrupted = false

    /// Undo keeps whole states, one per burst of edits: a slider drag, or a
    /// run of taps less than 0.7 s apart, is one step.
    private struct Snapshot: Equatable {
        var settings: FilmSettings
        var adjustments: Adjustments
        var geometry = Geometry()
        var camera = CameraDecode()
    }
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    /// The state the last burst ended in (or the photo opened in).
    private var committed: Snapshot?
    /// The state a burst in progress started from.
    private var burstBase: Snapshot?
    private var burstTimer: Task<Void, Never>?
    private var saveTimer: Task<Void, Never>?
    private var thumbnailTimer: Task<Void, Never>?
    /// True while the model itself writes the edits (opening a photo, undo),
    /// which is not an edit and must not be recorded as one.
    private var applyingState = false
    private static let lastPhotoKey = "SpektraProbe.lastPhoto"
    private var snapshot: Snapshot {
        Snapshot(settings: settings, adjustments: adjustments, geometry: geometry, camera: camera)
    }

    /// The open frame's full-resolution size, which the crop is measured in.
    var sourceSize: CGSize { opened.map { CGSize(width: $0.width, height: $0.height) } ?? .zero }

    /// long ÷ short of the open photograph, for the film format (the Mac's
    /// `physicalAspect`; a crop does not count, which is its default too).
    var aspect: Double {
        guard let opened, opened.width > 0, opened.height > 0 else { return 1.5 }
        return Double(max(opened.width, opened.height)) / Double(min(opened.width, opened.height))
    }

    init() {
        renderer = try? Renderer(device: device)
        crashNote = ProbeModel.describeLeftover(InFlight.takeLeftover())
        librarySort = libraryIndex.sort
        favorites = libraryIndex.favorites
        deviceLines = ProbeModel.describeDevice(device)
        if renderer == nil { error = String(localized: "The canvas shaders did not load.") }
        Task {
            await startEngine()
            refreshLibrary()
            if await !runSelfTestIfAsked() { await reopenLast() }
        }
    }

    /// `--selftest <file in Documents>`, passed only when launched from the Mac
    /// (`devicectl … process launch … -- --selftest NAME`): open the file,
    /// export it untouched at quality 95, then with a few adjustments at quality
    /// 60, so the whole chain can be checked without anyone tapping. A launch
    /// from the Home Screen never has the argument.
    ///
    /// `--open <file in Documents>` only opens the file — for showing the app
    /// launched from the Mac (a demo, a screenshot) without anyone tapping.
    ///
    /// `--selftest-library <file>` checks saving, undo and the library;
    /// `--forget <file>` drops a photo's saved edits and thumbnail.
    ///
    /// Returns whether a launch argument decided what opens.
    private func runSelfTestIfAsked() async -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        // `--export-format jpeg|png|tiff8|tiff16`: the Export panel's choice,
        // for screenshots from the Mac (it is saved, like a tap would be).
        if let format = value("--export-format") {
            var o = exportOptions
            switch format {
            case "png": o.format = .png
            case "tiff8": o.format = .tiff; o.tiffBits = 8
            case "tiff16": o.format = .tiff; o.tiffBits = 16
            default: o.format = .jpeg
            }
            exportOptions = o
        }
        if let name = value("--open") {
            await open(LibraryPhoto(name: name))
            showingInfo = arguments.contains("--show-info")
            if arguments.contains("--selftest-names") { runNamesSelfTest(keep: arguments.contains("--keep-names")) }
            if arguments.contains("--clear-test-names") { clearTestNames() }
            return true
        }
        if let name = value("--selftest-info") {
            await open(LibraryPhoto(name: name))
            if let photo = current {
                let asShot = self.asShot, pixels = sourceSize
                let info = await Task.detached { PhotoInfo.read(url: photo.url, asShot: asShot, pixels: pixels) }.value
                exportLines = info.sections.flatMap { section in
                    ["\(section.title):"] + section.rows.map { "  \($0.label): \($0.value)" }
                }
                saveResults()
            }
            return true
        }
        if let name = value("--forget") {
            SidecarStore.forget(LibraryPhoto(name: name))
            UserDefaults.standard.removeObject(forKey: Self.lastPhotoKey)
            refreshLibrary()
            exportLines = ["forgot the saved edits and thumbnail of \(name)"]
            saveResults()
            return true
        }
        if let name = value("--selftest-library") {
            await runLibrarySelfTest(name)
            return true
        }
        if let name = value("--selftest-geometry") {
            await open(LibraryPhoto(name: name))
            if hasPhoto { await runGeometrySelfTest() }
            return true
        }
        if let name = value("--selftest-stocks") {
            await open(LibraryPhoto(name: name))
            if hasPhoto { await runStocksSelfTest() }
            return true
        }
        if let name = value("--selftest-organize") {
            await runOrganizeSelfTest(LibraryPhoto(name: name))
            return true
        }
        if let name = value("--selftest-stale") {
            runStaleEditsSelfTest(LibraryPhoto(name: name))
            return true
        }
        if arguments.contains("--selftest-raws") {
            await runRAWsSelfTest()
            return true
        }
        if let name = value("--selftest-export") {
            await open(LibraryPhoto(name: name))
            if hasPhoto { await runExportSelfTest() }
            return true
        }
        if let name = value("--selftest-bw") {
            await open(LibraryPhoto(name: name))
            if hasPhoto { await runBlackAndWhiteSelfTest() }
            return true
        }
        if let name = value("--selftest-film") {
            await open(LibraryPhoto(name: name))
            if hasPhoto { await runFilmSelfTest() }
            return true
        }
        guard let name = value("--selftest") else { return false }
        await open(LibraryPhoto(name: name))
        guard hasPhoto else { return true }
        exportQuality = 95
        await exportJPEG()
        adjustments = Adjustments(temperature: 40, exposure: 0.7, contrast: 20, highlights: -40,
                                  shadows: 30, saturation: -10, vibrance: 60)
        exportQuality = 60
        await exportJPEG()
        return true
    }

    /// `--selftest-library`: edits in two bursts, undo and redo, a save, a
    /// byte-identical copy that must start clean, navigation back with the
    /// saved edits restored, the copy removed, and a print thumbnail.
    private func runLibrarySelfTest(_ name: String) async {
        let original = LibraryPhoto(name: name)
        var lines = ["library: \(photos.map(\.name))"]
        await open(original)
        guard hasPhoto else { return }
        selectFilm("kodak_ektar_100")
        settings.exposureCompensationEV = 1
        adjustments.temperature = 30
        try? await Task.sleep(for: .seconds(1))
        adjustments.vibrance = 50
        try? await Task.sleep(for: .seconds(1))
        await settle()
        lines.append("edited: \(settings.filmStock), EV \(settings.exposureCompensationEV), temperature \(adjustments.temperature), vibrance \(adjustments.vibrance); undo steps \(undoStack.count)")
        undo()
        await settle()
        lines.append("after undo: vibrance \(adjustments.vibrance), film \(settings.filmStock)")
        redo()
        await settle()
        lines.append("after redo: vibrance \(adjustments.vibrance)")
        saveNow()
        lines.append("sidecar written: \(FileManager.default.fileExists(atPath: SidecarStore.url(for: original).path))")
        if let copy = try? Library.importCopy(of: original.url) {
            refreshLibrary()
            await open(copy)
            lines.append("copy \(copy.name): film \(settings.filmStock), vibrance \(adjustments.vibrance) (a copy starts clean)")
            let toOriginal = (photos.firstIndex(of: copy) ?? 0) < (photos.firstIndex(of: original) ?? 0)
            if toOriginal { await next() } else { await previous() }
            lines.append("\(toOriginal ? "next()" : "previous()") → \(current?.name ?? "?"): film \(settings.filmStock), EV \(settings.exposureCompensationEV), temperature \(adjustments.temperature), vibrance \(adjustments.vibrance)")
            try? Library.remove(copy)
            refreshLibrary()
            lines.append("copy removed; library: \(photos.map(\.name))")
        }
        try? await Task.sleep(for: .seconds(3))
        lines.append("print thumbnail cached: \(FileManager.default.fileExists(atPath: Thumbnails.url(for: original).path))")
        exportLines = lines
        saveResults()
    }

    /// `--selftest-film`: one export each of a black-and-white film on its
    /// paper, a slide film scanned, and a colour negative on 120 with EDR,
    /// doubled grain and the engine's suggested Scene Placement.
    private func runFilmSelfTest() async {
        var lines: [String] = []
        func record(_ what: String) {
            lines.append(what + ": " + (exportLines.first ?? error ?? "no export"))
        }
        exportQuality = 90
        selectFilm("kodak_tri_x_400")
        await settle()
        await exportJPEG()
        record("Tri-X 400 / \(StockCatalog.shared.name(settings.printStock))")
        selectFilm("fujifilm_velvia_100")
        await settle()
        await exportJPEG()
        record("Velvia 100 / scanned: \(settings.scanFilm)")
        selectFilm("kodak_portra_400")
        selectPaper("kodak_portra_endura")
        setFrame("120")
        settings.extendedDynamicRange = true
        settings.effects.grain = 2
        await settle()
        await suggestPlacement()
        lines.append("suggest: " + (placementNote ?? "applied"))
        if !settings.placement.active {
            await place(highlight: 3.5, shadow: 0)
            lines.append("highlights 3.5: " + (placementNote ?? "applied"))
        }
        await settle()
        await exportJPEG()
        record(String(format: "Portra 400 / Portra Endura, 120 (%.1f mm), EDR, grain 2, placement %.2f/%.2f",
                      settings.filmFormatMM, settings.placement.highlightPullBack,
                      settings.placement.shadowPullBack))
        exportLines = lines + latitudeLines.map { "latitude: " + $0 }
        saveResults()
    }

    /// `--selftest-geometry`: a 4:3 crop straightened 4°, turned right and
    /// flipped, then undone and redone, and exported; the camera set to
    /// Tungsten, the eyedropper's reading at the centre, the lens correction
    /// switched, a Tungsten export; the edits read back after reopening the
    /// photo; the full-resolution canvas print and what one adjustment costs
    /// at that size; then everything put back as it was.
    private func runGeometrySelfTest() async {
        guard let photo = current else { return }
        var lines: [String] = []
        let original = (geometry, camera)
        func waitForCamera() async {
            for _ in 0..<400 where reopening || camera != appliedCamera {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        lines.append(String(format: "source %.0f × %.0f; RAW %@; as shot %@; lens correction in the file: %@",
                            sourceSize.width, sourceSize.height, photoIsRAW ? "yes" : "no",
                            asShot.map { String(format: "%.0f K, tint %+.1f", $0.temperature, $0.tint) } ?? "none",
                            lensCorrectionSupported ? "yes" : "no"))
        geometry = Geometry()
        setAspect(.r4x3)
        straighten(to: 4)
        rotate(clockwise: true)
        flip(horizontal: true)
        let cut = geometry
        undo()
        lines.append("undo → identity: \(geometry.isIdentity)")
        redo()
        lines.append("redo → the crop again: \(geometry == cut)")
        exportQuality = 90
        await exportJPEG()
        let expected = geometry.outputSize(for: sourceSize)
        lines.append(String(format: "4:3, 4°, turned right, flipped (expect %.0f × %.0f): ", expected.width, expected.height)
                     + (exportLines.first ?? error ?? "no export"))
        if photoIsRAW {
            let started = CFAbsoluteTimeGetCurrent()
            setWhiteBalance(.tungsten)
            await waitForCamera()
            lines.append(String(format: "Tungsten: RAW read again and the engine reopened in %.2f s (%@)",
                                CFAbsoluteTimeGetCurrent() - started, error ?? "OK"))
            await exportJPEG()
            lines.append("Tungsten export: " + (exportLines.first ?? error ?? "no export"))
            let url = photo.url, decode = camera
            let neutral = await Task.detached { RAWDecode.neutral(at: CGPoint(x: 0.5, y: 0.5), in: url, camera: decode) }.value
            lines.append(neutral.map { String(format: "eyedropper at the centre: %.0f K, tint %+.1f", $0.temperature, $0.tint) }
                         ?? "eyedropper: no reading")
            let wasOn = camera.lensCorrection
            let size = sourceSize
            setLensCorrection(!wasOn)
            await waitForCamera()
            lines.append(String(format: "lens correction %@ → %@: frame %.0f × %.0f → %.0f × %.0f",
                                wasOn ? "on" : "off", wasOn ? "off" : "on",
                                size.width, size.height, sourceSize.width, sourceSize.height))
        }
        saveNow()
        let saved = SidecarStore.load(for: photo)
        lines.append("saved: geometry \(saved?.geometry == geometry), camera \(saved?.camera == camera)")
        let (g, c) = (geometry, camera)
        await open(photo)
        lines.append("reopened: geometry restored \(geometry == g), camera restored \(camera == c)")
        geometry = Geometry()
        let started = CFAbsoluteTimeGetCurrent()
        requestFullResolution()
        for _ in 0..<200 where fullPrint == nil { try? await Task.sleep(for: .milliseconds(50)) }
        if let full = fullPrint, let renderer, let transform = displayTransform {
            lines.append(String(format: "full-resolution canvas print %d × %d in %.2f s",
                                full.width, full.height, CFAbsoluteTimeGetCurrent() - started))
            let t0 = CFAbsoluteTimeGetCurrent()
            _ = try? renderer.finish(print: full, uniforms: adjustments.uniforms, transform: transform)
            lines.append(String(format: "one adjustment at that size (Layer 2 + Display P3, read back): %.0f ms",
                                (CFAbsoluteTimeGetCurrent() - t0) * 1000))
        } else {
            lines.append("full-resolution canvas print: none (\(error ?? "timed out"))")
        }
        (geometry, camera) = original
        await waitForCamera()
        saveNow()
        lines.append("put back: geometry \(geometry == original.0), camera \(camera == original.1)")
        exportLines = lines
        saveResults()
    }

    /// `--selftest-bw`: Tri-X on Multigrade with no filter, then each kind of
    /// lens filter and the paper's two extreme grades. Records the print's
    /// tones each time and exports three of them, then puts the photo's
    /// settings back. A filter should move the mean little (the factor is
    /// given) and the grades should spread the tones apart or together.
    private func runBlackAndWhiteSelfTest() async {
        var lines: [String] = []
        let original = settings
        func step(_ what: String) async {
            await settle()
            lines.append(what + ": " + (error ?? printTones()))
        }
        selectFilm("kodak_tri_x_400")
        lines.append("paper \(settings.printStock); grades table for \(PaperGrades.shared?.paper ?? "none") with \(PaperGrades.shared?.grades.count ?? 0) grades")
        await step("Tri-X, no filter, grade 2")
        exportQuality = 90
        await exportJPEG()
        lines.append("  export: " + (exportLines.first ?? error ?? "none"))
        for filter in [LensFilter.w8, .w21, .w25, .w58, .w47] {
            settings.lensFilter = filter
            await step("filter \(filter.rawValue)")
        }
        settings.lensFilter = .w25
        await settle()
        await exportJPEG()
        lines.append("  red 25 export: " + (exportLines.first ?? error ?? "none"))
        settings.lensFilter = .none
        for grade in ["00", "5"] {
            settings.paperGrade = grade
            await step("grade \(grade)")
        }
        await exportJPEG()
        lines.append("  grade 5 export: " + (exportLines.first ?? error ?? "none"))
        settings.paperGrade = PaperGrades.normal
        selectFilm("kodak_portra_400")
        await settle()
        lines.append("back to Portra 400, camera_filter sent as \(settings.wire["camera_filter"].map { "\($0)" } ?? "?")")
        settings = original
        await settle()
        saveNow()
        lines.append("put back: \(settings == original)")
        exportLines = lines
        saveResults()
    }

    /// The live print's tones through the display transform, untouched by
    /// Adjust: mean, spread (standard deviation) and the 5th and 95th
    /// percentiles, 0…1, on every fourth pixel.
    private func printTones() -> String {
        guard let print, let renderer, let transform = displayTransform,
              let finished = try? renderer.finish(print: print, uniforms: Layer2Uniforms(), transform: transform)
        else { return "no print" }
        let t = finished.texture
        var px = [UInt16](repeating: 0, count: t.width * t.height * 4)
        px.withUnsafeMutableBytes { raw in
            t.getBytes(raw.baseAddress!, bytesPerRow: t.width * 8,
                       from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
        }
        var values: [Double] = []
        for y in stride(from: 0, to: t.height, by: 4) {
            for x in stride(from: 0, to: t.width, by: 4) {
                let i = (y * t.width + x) * 4
                values.append((0.2126 * Double(px[i]) + 0.7152 * Double(px[i + 1]) + 0.0722 * Double(px[i + 2])) / 65535)
            }
        }
        guard !values.isEmpty else { return "empty print" }
        let mean = values.reduce(0, +) / Double(values.count)
        let spread = (values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)).squareRoot()
        values.sort()
        return String(format: "mean %.3f, spread %.3f, 5%% %.3f, 95%% %.3f", mean, spread,
                      values[values.count / 20], values[values.count * 19 / 20])
    }

    /// `--selftest-export`: JPEG at 95 and 60, PNG, TIFF at 8 and 16 bits —
    /// each one's estimate, then a real export, its size beside the estimate,
    /// and what the written file says it is, read back from it. Each test file
    /// is deleted afterwards; the panel's own settings are put back.
    private func runExportSelfTest() async {
        var lines: [String] = []
        let original = exportOptions, originalSettings = settings, originalGeometry = geometry
        let cases = [ExportOptions(format: .jpeg, quality: 95), ExportOptions(format: .jpeg, quality: 60),
                     ExportOptions(format: .png), ExportOptions(format: .tiff, tiffBits: 8),
                     ExportOptions(format: .tiff, tiffBits: 16)]
        // Two different pictures from one frame: the factors were measured on
        // the first, so the second says how far they carry.
        for pass in 0..<2 {
        if pass == 1 {
            selectFilm("kodak_ektar_100")
            setAspect(.square)
            await settle()
            lines.append("Ektar 100, cropped 1:1:")
        } else {
            lines.append("\(StockCatalog.shared.name(settings.filmStock)), full frame:")
        }
        for options in cases {
            exportOptions = options
            let started = CFAbsoluteTimeGetCurrent()
            await estimateExportSize()
            let estimateSeconds = CFAbsoluteTimeGetCurrent() - started
            let estimate = exportEstimateBytes ?? 0
            await export()
            guard let url = lastExport, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                lines.append("\(options.summary): export failed: \(error ?? "?")")
                continue
            }
            lines.append(String(format: "%@: estimate %.1f MB (in %.2f s), file %.1f MB, file / estimate %.3f",
                                options.summary, Double(estimate) / 1e6, estimateSeconds, Double(size) / 1e6,
                                Double(size) / Double(max(estimate, 1))))
            lines.append("  " + Self.describeFile(url) + "; " + (exportLines.dropFirst(2).first ?? ""))
            try? FileManager.default.removeItem(at: url)
        }
        }
        settings = originalSettings
        geometry = originalGeometry
        await settle()
        saveNow()
        exportOptions = original
        lastExport = nil
        lastExportSummary = nil
        exportLines = lines
        saveResults()
    }

    /// `--selftest-stale <file>`: a photo deleted outside RA4 (in Files) leaves
    /// its edits behind under its name. The same photo imported again under
    /// that name keeps them; a different photo under it must not get them.
    /// On copies named `stale-test.<ext>`, removed afterwards.
    private func runStaleEditsSelfTest(_ source: LibraryPhoto) {
        var lines: [String] = []
        let fm = FileManager.default
        let ext = source.url.pathExtension
        let staging = fm.temporaryDirectory.appending(path: "stale-test", directoryHint: .isDirectory)
        try? fm.removeItem(at: staging)
        try? fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let named = staging.appending(path: "stale-test.\(ext)")
        func size(_ url: URL) -> Int { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1 }
        guard let other = photos.first(where: { size($0.url) != size(source.url) }) else {
            exportLines = ["stale: no second photo of another size in the library"]
            saveResults()
            return
        }
        do {
            try fm.copyItem(at: source.url, to: named)
            let first = try Library.importCopy(of: named)
            var edited = FilmSettings()
            edited.selectFilm("kodak_ektar_100")
            SidecarStore.save(settings: edited, adjustments: Adjustments(), geometry: Geometry(),
                              camera: CameraDecode(), for: first)
            lines.append("\(first.name): edits saved (film \(SidecarStore.load(for: first)?.settings.filmStock ?? "none"))")
            try fm.removeItem(at: first.url)       // deleted in Files: the edits stay behind
            let again = try Library.importCopy(of: named)
            let kept = SidecarStore.load(for: again)?.settings.filmStock
            lines.append("the same photo imported again as \(again.name): film \(kept ?? "none") \(kept == "kodak_ektar_100" ? "✓ kept" : "✗")")
            try fm.removeItem(at: again.url)
            try fm.removeItem(at: named)
            try fm.copyItem(at: other.url, to: named)
            let different = try Library.importCopy(of: named)
            let inherited = SidecarStore.load(for: different)
            lines.append("\(other.name) imported as \(different.name): edits \(inherited == nil ? "none ✓" : "film \(inherited!.settings.filmStock) ✗ inherited"), sidecar file \(fm.fileExists(atPath: SidecarStore.url(for: different).path) ? "still there ✗" : "gone ✓")")
            try Library.remove(different)
        } catch {
            lines.append("stale: failed: \(error.localizedDescription)")
        }
        try? fm.removeItem(at: staging)
        refreshLibrary()
        lines.append("library afterwards: \(photos.map(\.name).joined(separator: ", "))")
        exportLines = lines
        saveResults()
    }

    /// `--selftest-organize <file>`: favourites, the four sorts, a drag and two
    /// deletes, on two copies of `file` made for the test — never on the
    /// person's own photos. The library's sort and favourites are put back.
    private func runOrganizeSelfTest(_ source: LibraryPhoto) async {
        var lines: [String] = []
        let originalSort = libraryIndex.sort, originalFavorites = libraryIndex.favorites
        guard let a = try? Library.importCopy(of: source.url), let b = try? Library.importCopy(of: source.url) else {
            exportLines = ["could not copy \(source.name)"]
            saveResults()
            return
        }
        refreshLibrary()
        func names() -> String { photos.map(\.name).joined(separator: ", ") }
        lines.append("copies \(a.name), \(b.name); library: \(names())")
        toggleFavorite(b)
        setLibrarySort(.favorites)
        lines.append("favourite \(b.name), favourites first → first is \(photos.first?.name ?? "?") \(photos.first == b ? "✓" : "✗")")
        setLibrarySort(.name)
        lines.append("by name: \(names())")
        for _ in 0..<40 where libraryIndex.dates.count < photos.count { try? await Task.sleep(for: .milliseconds(50)) }
        setLibrarySort(.date)
        lines.append("by date taken: " + photos.map { photo in
            let date = libraryIndex.dates[photo.name].map { $0.formatted(.iso8601.year().month().day()) } ?? "no date"
            return "\(photo.name) (\(date))"
        }.joined(separator: ", "))
        if let first = photos.first, first != a {
            movePhoto(a.name, to: first.name)
            let stored = LibraryIndex.load()
            lines.append("dragged \(a.name) to the top → sort \(librarySort.rawValue), first \(photos.first?.name ?? "?") \(photos.first == a ? "✓" : "✗"); saved order starts \(stored.order.first ?? "?"), saved sort \(stored.sort.rawValue)")
        }
        await open(a)
        let afterA = photos.firstIndex(of: a).flatMap { $0 + 1 < photos.count ? photos[$0 + 1] : nil }
        await delete(a)
        lines.append("deleted the open \(a.name): file \(FileManager.default.fileExists(atPath: a.url.path) ? "still there ✗" : "gone ✓"), edits \(FileManager.default.fileExists(atPath: SidecarStore.url(for: a).path) ? "still there ✗" : "gone ✓"), in the order \(libraryIndex.order.contains(a.name) ? "still ✗" : "no ✓"); now open: \(current?.name ?? "nothing") (expected \(afterA?.name ?? "nothing"))")
        await delete(b)
        lines.append("deleted \(b.name) (not open): file \(FileManager.default.fileExists(atPath: b.url.path) ? "still there ✗" : "gone ✓"), favourite \(favorites.contains(b.name) ? "still ✗" : "no ✓")")
        libraryIndex.favorites = originalFavorites.intersection(Set(photos.map(\.name)))
        favorites = libraryIndex.favorites
        setLibrarySort(originalSort)
        lines.append("put back: sort \(librarySort.rawValue), favourites \(favorites.sorted()); library: \(names())")
        exportLines = lines
        saveResults()
    }

    /// `--open <file> --selftest-names [--keep-names]`: renames Portra 400 and
    /// Supra Endura, checks that the ISO and the wire id stay the catalogue's,
    /// that an empty name keeps the original and that the original name
    /// undoes a rename, and that it is all stored. The first line lists the
    /// names already there at launch, which is how a relaunch shows they were
    /// kept. Without `--keep-names` the three stocks it touched get back
    /// exactly what they had; no other name is ever touched, so a person's
    /// own renames survive the test.
    private func runNamesSelfTest(keep: Bool) {
        let names = StockNames.shared, catalog = StockCatalog.shared
        var lines = ["renamed at launch: " + Self.describe(names.renamed)]
        guard let portra = catalog.stock("kodak_portra_400"), let supra = catalog.stock("kodak_supra_endura"),
              let ektar = catalog.stock("kodak_ektar_100") else { return }
        let before = [portra.id, supra.id, ektar.id].map { ($0, names.renamed[$0]) }
        names.rename(portra, brand: "Brand K", name: "Daylight 400")
        names.rename(supra, brand: "", name: "Gloss Paper")
        lines.append("Portra 400 shows \"\(names.label(portra).full)\"; ISO \(StockNames.speed(of: portra) ?? "?"); wire id \(portra.id); settings send \(settings.filmStock)")
        lines.append("Supra Endura shows \"\(names.label(supra).full)\"")
        names.rename(ektar, brand: "X", name: "  ")
        lines.append("Ektar given an empty name shows \"\(names.label(ektar).full)\"")
        names.rename(ektar, brand: "Kodak", name: "Ektar 100")
        lines.append("Ektar given its own name back: still renamed \(names.isRenamed(ektar.id))")
        lines.append("stored in UserDefaults: \(UserDefaults.standard.data(forKey: "RA4.stockNames") != nil)")
        if !keep {
            for (id, label) in before { names.put(id, label) }
            lines.append("put back as they were: \(before.allSatisfy { names.renamed[$0.0] == $0.1 }); "
                         + "now renamed: " + Self.describe(names.renamed))
        }
        exportLines = lines
        saveResults()
    }

    /// `--clear-test-names`: takes off the names a `--keep-names` run left —
    /// only where a stock still carries exactly the test's name, so a name a
    /// person gave is never touched.
    private func clearTestNames() {
        let names = StockNames.shared
        let test = ["kodak_portra_400": StockLabel(brand: "Brand K", name: "Daylight 400"),
                    "kodak_supra_endura": StockLabel(brand: "", name: "Gloss Paper")]
        var lines = ["renamed at launch: " + Self.describe(names.renamed)]
        var cleared: [String] = []
        for (id, label) in test.sorted(by: { $0.key < $1.key }) where names.renamed[id] == label {
            names.restore(id)
            cleared.append(id)
        }
        lines.append("test names taken off: \(cleared)")
        lines.append("still renamed: " + Self.describe(names.renamed))
        exportLines = lines
        saveResults()
    }

    private static func describe(_ renamed: [String: StockLabel]) -> String {
        renamed.isEmpty ? "none" : renamed.map { "\($0.key) → \"\($0.value.full)\"" }.sorted().joined(separator: "; ")
    }

    /// `--selftest-stocks`: what choosing a film does to the print. A slide
    /// then a negative must print again, on the negative's own paper; a
    /// negative scanned by choice stays scanned on the next negative; a slide
    /// then a black-and-white negative prints on the silver paper. Each step
    /// is rendered, and the photo's settings are put back.
    private func runStocksSelfTest() async {
        var lines: [String] = []
        let original = settings
        func state(_ step: String, expect: String? = nil) async {
            await settle()
            let s = settings
            let now = s.scanFilm ? "scanned, no print" : "printed on \(StockCatalog.shared.name(s.printStock))"
            var line = "\(step): \(StockCatalog.shared.name(s.filmStock)) \(now)"
            if let expect { line += now.contains(expect) ? "  ✓" : "  ✗ expected \(expect)" }
            lines.append(line + (error.map { " — ERROR \($0)" } ?? ""))
        }
        await state("start")
        selectFilm("fujifilm_velvia_100")
        await state("slide", expect: "scanned")
        selectFilm("kodak_portra_400")
        await state("slide → negative", expect: "printed on \(StockCatalog.shared.name(StockCatalog.shared.stock("kodak_portra_400")?.targetPrint ?? ""))")
        selectNoPrint()
        await state("No print, by choice", expect: "scanned")
        selectFilm("kodak_ektar_100")
        await state("chosen scan → another negative", expect: "scanned")
        selectFilm("fujifilm_velvia_100")
        selectFilm("kodak_tri_x_400")
        await state("slide → black-and-white negative", expect: "printed on \(StockCatalog.shared.name("ilford_multigrade_iv_rc"))")
        settings = original
        await settle()
        saveNow()
        lines.append("put back: \(settings == original)")
        exportLines = lines
        saveResults()
    }

    /// `--selftest-raws`: every photo in the library, at the Mac app's
    /// defaults for a new frame — and its lens correction off, as the Mac
    /// starts it — so the result can be set beside SpektraLab's: what the
    /// decode says, how long each step takes, and a full-resolution sRGB JPEG
    /// at quality 95 (kept in Exports). A photo with edits of its own is
    /// skipped and left as it is; the others end as they began.
    private func runRAWsSelfTest() async {
        var lines: [String] = []
        let originalOptions = exportOptions
        exportOptions = ExportOptions(format: .jpeg, quality: 95)
        for photo in photos {
            if SidecarStore.isEdited(photo) {
                lines.append("\(photo.name): skipped, it has edits of its own")
                continue
            }
            let started = CFAbsoluteTimeGetCurrent()
            await open(photo)
            guard hasPhoto, current == photo else {
                lines.append("\(photo.name): DID NOT OPEN — \(error ?? "no error given")")
                error = nil
                continue
            }
            let openSeconds = CFAbsoluteTimeGetCurrent() - started
            if lensCorrectionSupported { camera.lensCorrection = false }
            await settle()
            for _ in 0..<400 where reopening || camera != appliedCamera { try? await Task.sleep(for: .milliseconds(50)) }
            let info = await Task.detached { [asShot, sourceSize] in
                PhotoInfo.read(url: photo.url, asShot: asShot, pixels: sourceSize)
            }.value
            func row(_ label: String) -> String {
                info.sections.flatMap(\.rows).first { $0.label == String(localized: String.LocalizationValue(label)) }?.value ?? "?"
            }
            lines.append("\(photo.name): \(row("Camera")), \(row("Lens")), \(row("Format"))")
            lines.append(String(format: "  frame %.0f × %.0f; opened in %.2f s; %@; %@; as shot %@; lens correction in the file: %@",
                                sourceSize.width, sourceSize.height, openSeconds,
                                photoLines.first { $0.hasPrefix("RAW decode") } ?? "",
                                previewLines.first ?? "", row("As shot"),
                                lensCorrectionSupported ? "yes (turned off, as the Mac starts)" : "no"))
            await export()
            lines.append("  export: " + (exportLines.first ?? error ?? "none")
                         + (exportLines.dropFirst(2).first.map { "; " + $0 } ?? ""))
            // The file must be this photo's frame and not another's.
            let expected = geometry.outputSize(for: sourceSize)
            let own = "\(Int(expected.width)) × \(Int(expected.height))"
            lines.append("  frame check: the export is \(exportLines.first?.contains(own) == true ? "this photo's own \(own)" : "NOT this photo's \(own)")")
            error = nil
            camera = CameraDecode()
            for _ in 0..<400 where reopening || camera != appliedCamera { try? await Task.sleep(for: .milliseconds(50)) }
            saveNow()
        }
        // The race this test once found: a camera change on one photo, the
        // next photo opened at once, without waiting. The engine must end on
        // the second photo's frame.
        let readable = photos.filter { !SidecarStore.isEdited($0) }
        if readable.count >= 2 {
            let (a, b) = (readable[0], readable[1])
            await open(a)
            camera.lensCorrection.toggle()
            await open(b)
            await renderFull()
            let own = "\(Int(sourceSize.width)) × \(Int(sourceSize.height))"
            let result = fullLines.first { $0.hasPrefix("Result") } ?? "no render"
            lines.append("race check (\(a.name) changed, \(b.name) opened at once): engine holds \(result); "
                         + (result.contains(own) ? "this photo's own frame, as it should" : "NOT \(b.name)'s \(own)"))
            await open(a)
            camera = CameraDecode()
            for _ in 0..<400 where reopening || camera != appliedCamera { try? await Task.sleep(for: .milliseconds(50)) }
            saveNow()
        }
        exportOptions = originalOptions
        exportLines = lines
        saveResults()
    }

    /// What a written image file says about itself.
    nonisolated private static func describeFile(_ url: URL) -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return "unreadable" }
        let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any]
        func v(_ x: Any?) -> String { x.map { "\($0)" } ?? "-" }
        let serial = exif?[kCGImagePropertyExifBodySerialNumber] ?? exif?[kCGImagePropertyExifLensSerialNumber]
        return "read back: \(CGImageSourceGetType(source).map { $0 as String } ?? "?") "
            + "\(v(p[kCGImagePropertyPixelWidth]))×\(v(p[kCGImagePropertyPixelHeight])), "
            + "\(v(p[kCGImagePropertyDepth])) bits, compression \(v(tiff?[kCGImagePropertyTIFFCompression])), "
            + "profile \(v(p[kCGImagePropertyProfileName])), EXIF \(exif == nil ? "no" : "yes"), "
            + "camera \(v(tiff?[kCGImagePropertyTIFFMake])) \(v(tiff?[kCGImagePropertyTIFFModel])), "
            + "lens \(v(exif?[kCGImagePropertyExifLensModel])), "
            + "serial \(serial == nil ? "none ✓" : "\(serial!) ✗")"
    }

    // MARK: running work on the engine's queue

    private func onEngine<T>(_ work: @escaping () throws -> T) async throws -> T {
        engineJobs += 1
        defer { engineJobs -= 1 }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            queue.async { continuation.resume(with: Result(catching: work)) }
        }
    }

    private func progressReporter() -> (String) -> Void {
        { [weak self] text in Task { @MainActor in self?.busy = text } }
    }

    // MARK: steps

    func startEngine() async {
        busy = String(localized: "Starting the engine…")
        let device = self.device, box = self.box
        do {
            let caps = try await onEngine { () -> [String: Any] in
                let engine = try Engine(device: device)
                box.engine = engine
                return engine.capabilities
            }
            let backend = caps["backend"] as? [String: Any] ?? [:]
            let core = backend["render_core"] as? String ?? "?"
            let gpu = backend["gpu"] as? String ?? device.name
            deviceLines.append("Engine: \(Engine.buildInfo)")
            deviceLines.append("Engine core: \(core) on \(gpu) — started OK")
        } catch {
            self.error = String(localized: "The engine did not start: \(String(describing: error))")
        }
        busy = nil
        saveResults()
    }

    /// Opens a library photo with its saved edits, or the Mac's defaults for a
    /// new frame. The photo that was open is saved and thumbnailed first.
    func open(_ photo: LibraryPhoto) async {
        guard busy == nil else { return }
        leaveCurrentPhoto()
        // A camera reread asked for on the photo being left would otherwise
        // queue its engine work behind this open and leave the engine on the
        // old frame under the new photo's name (`reopenForCamera`).
        opening = true
        pendingReopen = false
        defer { opening = false }
        error = nil
        previewEdge = ProbeModel.screenLongEdgePixels()
        let saved = SidecarStore.load(for: photo)
        let settings = saved?.settings ?? FilmSettings(), edge = previewEdge
        let camera = saved?.camera ?? CameraDecode()
        let device = self.device, box = self.box, progress = progressReporter()
        busy = String(localized: "Opening \(photo.name)…")
        do {
            let outcome = try await onEngine {
                try ProbeModel.openAndPreview(photo.url, settings: settings, camera: camera, edge: edge,
                                              device: device, box: box, progress: progress)
            }
            opened = outcome
            current = photo
            UserDefaults.standard.set(photo.name, forKey: Self.lastPhotoKey)
            // What was sent first, then the edits, so the change this makes is
            // already on the engine, and is not an edit.
            sentWire = outcome.sentWire
            applyingState = true
            self.settings = outcome.settings
            adjustments = saved?.adjustments ?? Adjustments()
            geometry = saved?.geometry ?? Geometry()
            self.camera = camera
            applyingState = false
            appliedCamera = camera
            asShot = outcome.asShot
            lensCorrectionSupported = outcome.lensCorrectionSupported
            photoIsRAW = outcome.isRAW
            pickingNeutral = false
            before = nil
            beforeTask?.cancel()
            beforeTask = nil
            committed = snapshot
            undoStack = []
            redoStack = []
            burstBase = nil
            updateUndoFlags()
            highlightDraft = outcome.settings.placement.highlightPullBack
            shadowDraft = outcome.settings.placement.shadowPullBack
            placementNote = nil
            readLatitude(outcome.latitude)
            hasPhoto = true
            fullLines = []
            exportLines = []
            lastExport = nil
            lastExportSummary = nil
            displayTransform = outcome.display
            show(outcome.preview)
            ensureBefore()
            photoLines = [
                "File: \(outcome.file)\(outcome.isRAW ? "" : " (not a RAW)")",
                String(format: "Size: %d × %d = %.1f MP", outcome.width, outcome.height,
                       Double(outcome.width * outcome.height) / 1e6),
                "Working space: \(outcome.workingSpace); screen: Display P3; export: sRGB",
                String(format: "RAW decode into engine frame: %.2f s (%@ float frame, %@)",
                       outcome.decodeSeconds, Memory.mb(UInt64(outcome.frameBytes)),
                       outcome.viaMetalBuffer ? "one Metal buffer" : "host memory — too big for one Metal buffer"),
                String(format: "Engine open: %.2f s", outcome.openSeconds),
                "Peak footprint while decoding + opening: \(Memory.mb(outcome.peakFootprint))",
                saved.map { "Saved edits: restored (saved \($0.savedAt.formatted(date: .abbreviated, time: .shortened)))" }
                    ?? "Saved edits: none — the Mac's defaults for a new frame",
            ]
        } catch {
            self.error = String(localized: "Could not open \(photo.name): \(String(describing: error))")
            await closeIfEngineLeft()
        }
        busy = nil
        saveResults()
    }

    /// After a failed open or reread: the photo on screen stays only while the
    /// engine still holds it as it was read. A decode that fails leaves the
    /// engine alone; an open that fails once the engine has let go of the old
    /// frame (or taken the new one) would otherwise send every later edit and
    /// export to a picture the screen does not show.
    private func closeIfEngineLeft() async {
        guard hasPhoto, let current else { return }
        let box = self.box
        let held = try? await onEngine { (box.sessionFile, box.sessionCamera) }
        if held?.0 != current.url || held?.1 != appliedCamera { closePhoto() }
    }

    // MARK: edits — undo, saving, thumbnails

    private func settingsDidChange() {
        guard !applyingState else { return }
        editHappened()
        Task { await settingsChanged() }
    }

    /// Every edit: start or extend the burst it belongs to, and schedule a save.
    private func editHappened() {
        scheduleEstimate()
        guard hasPhoto, !applyingState, let committed else { return }
        if burstBase == nil { burstBase = committed }
        burstTimer?.cancel()
        burstTimer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.closeBurst()
        }
        updateUndoFlags()
        scheduleSave()
    }

    private func closeBurst() {
        burstTimer?.cancel()
        burstTimer = nil
        guard let base = burstBase else { return }
        burstBase = nil
        let now = snapshot
        if now != base {
            undoStack.append(base)
            redoStack.removeAll()
        }
        committed = now
        updateUndoFlags()
    }

    func undo() {
        closeBurst()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(snapshot)
        apply(previous)
    }

    func redo() {
        closeBurst()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(snapshot)
        apply(next)
    }

    private func apply(_ state: Snapshot) {
        applyingState = true
        settings = state.settings
        adjustments = state.adjustments
        geometry = state.geometry
        camera = state.camera
        applyingState = false
        committed = state
        if state.camera != appliedCamera { Task { await reopenForCamera() } }
        highlightDraft = state.settings.placement.highlightPullBack
        shadowDraft = state.settings.placement.shadowPullBack
        updateUndoFlags()
        scheduleSave()
        Task { await settingsChanged() }
    }

    private func updateUndoFlags() {
        canUndo = !undoStack.isEmpty || (burstBase != nil && burstBase != snapshot)
        canRedo = !redoStack.isEmpty
    }

    private func scheduleSave() {
        saveTimer?.cancel()
        saveTimer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Writes the open photo's edits now (Application Support/Sidecars).
    func saveNow() {
        saveTimer?.cancel()
        saveTimer = nil
        guard let current, hasPhoto else { return }
        SidecarStore.save(settings: settings, adjustments: adjustments, geometry: geometry, camera: camera,
                          for: current)
        if SidecarStore.isEdited(current) { edited.insert(current.name) } else { edited.remove(current.name) }
        thumbnailTimer?.cancel()
        thumbnailTimer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            self?.captureThumbnail()
        }
    }

    /// The filmstrip's picture of the open photo: the live print through its
    /// adjustments and the display transform, small, cached on disk.
    func captureThumbnail() {
        guard hasPhoto, let current, let print, let renderer, let transform = displayTransform else { return }
        let uniforms = adjustments.uniforms, geometry = self.geometry
        Task.detached(priority: .utility) { [weak self] in
            guard let finished = try? renderer.finish(print: print, uniforms: uniforms, transform: transform,
                                                      geometry: geometry),
                  let image = Renderer.makeCGImage(finished.texture, space: transform.space),
                  let small = Thumbnails.downscaled(image) else { return }
            Thumbnails.store(small, for: current)
            await self?.setThumbnail(UIImage(cgImage: small), for: current.name)
        }
    }

    private func setThumbnail(_ image: UIImage, for name: String) { thumbnails[name] = image }

    /// Before another photo opens, or the app leaves the screen: nothing
    /// pending is lost and the filmstrip shows the photo as it was left.
    private func leaveCurrentPhoto() {
        guard hasPhoto, current != nil else { return }
        closeBurst()
        saveNow()
        thumbnailTimer?.cancel()
        captureThumbnail()
    }

    /// The window's scene phase, from the interface:
    /// - **inactive** (Control Center, the app switcher, a call): the edits
    ///   and the thumbnail are saved, while the GPU may still be used — an app
    ///   can be ended from the switcher without ever reaching the background;
    /// - **background**: the zoomed canvas's full-resolution print goes — about
    ///   1 GB with its canvas copies, and a background app that holds it is the
    ///   first to be ended — and any engine work still running is marked as
    ///   untrustworthy;
    /// - **active** again: photos added in Files are picked up, and a photo
    ///   whose engine work was cut off is developed again, edits kept.
    func sceneChanged(to phase: ScenePhase) {
        switch phase {
        case .active:
            refreshLibrary()
            if engineWorkInterrupted {
                engineWorkInterrupted = false
                Task { await reopenForCamera(again: true) }
            }
        case .inactive:
            leaveCurrentPhoto()
        case .background:
            backgroundEntries += 1
            fullPrint = nil
            if engineJobs > 0 { engineWorkInterrupted = true }
        @unknown default:
            break
        }
    }

    // MARK: the library

    func refreshLibrary() {
        let all = Library.photos()
        let before = libraryIndex
        libraryIndex.prune(keeping: Set(all.map(\.name)))
        if libraryIndex != before { libraryIndex.save() }
        photos = libraryIndex.arranged(all)
        favorites = libraryIndex.favorites
        librarySort = libraryIndex.sort
        // Capture dates are read once per photo, in the background.
        let undated = all.filter { libraryIndex.dates[$0.name] == nil }
        if !undated.isEmpty {
            Task.detached(priority: .utility) { [weak self] in
                var found: [String: Date] = [:]
                for photo in undated { if let date = Library.captureDate(of: photo.url) { found[photo.name] = date } }
                await self?.addCaptureDates(found)
            }
        }
        edited = Set(photos.filter(SidecarStore.isEdited).map(\.name))
        let missing = photos.filter { thumbnails[$0.name] == nil }
        Task.detached(priority: .utility) { [weak self] in
            for photo in missing {
                guard let image = Thumbnails.load(for: photo) else { continue }
                await self?.setThumbnail(image, for: photo.name)
            }
        }
    }

    // MARK: the library's order, favourites and deleting

    private func addCaptureDates(_ found: [String: Date]) {
        guard !found.isEmpty else { return }
        libraryIndex.dates.merge(found) { old, _ in old }
        libraryIndex.save()
        if librarySort == .date { photos = libraryIndex.arranged(photos) }
    }

    func setLibrarySort(_ sort: LibrarySort) {
        libraryIndex.sort = sort
        librarySort = sort
        photos = libraryIndex.arranged(photos)
        libraryIndex.save()
    }

    func isFavorite(_ photo: LibraryPhoto) -> Bool { favorites.contains(photo.name) }

    func toggleFavorite(_ photo: LibraryPhoto) {
        if libraryIndex.favorites.contains(photo.name) {
            libraryIndex.favorites.remove(photo.name)
        } else {
            libraryIndex.favorites.insert(photo.name)
        }
        favorites = libraryIndex.favorites
        if librarySort == .favorites { photos = libraryIndex.arranged(photos) }
        libraryIndex.save()
    }

    /// A drag in a list (`onMove`): the list as it now stands becomes the
    /// custom order, and the library is sorted by it.
    func movePhotos(from source: IndexSet, to destination: Int) {
        var list = photos
        list.move(fromOffsets: source, toOffset: destination)
        applyCustomOrder(list)
    }

    /// A drag in a grid: `name` takes `target`'s place, the photos between
    /// moving up or down one.
    func movePhoto(_ name: String, to target: String) {
        guard let from = photos.firstIndex(where: { $0.name == name }),
              let to = photos.firstIndex(where: { $0.name == target }), from != to else { return }
        var list = photos
        list.insert(list.remove(at: from), at: to)
        applyCustomOrder(list)
    }

    private func applyCustomOrder(_ list: [LibraryPhoto]) {
        libraryIndex.order = list.map(\.name)
        libraryIndex.sort = .custom
        librarySort = .custom
        photos = list
        libraryIndex.save()
    }

    /// Takes a photo out of the library: its file in RA4's folder, its edits
    /// and its thumbnail. Exports stay, and so does anything in Photos or
    /// elsewhere in Files it was imported from. The interface asks first. An
    /// open photo hands the canvas to its neighbour, or to nothing.
    func delete(_ photo: LibraryPhoto) async {
        guard busy == nil, photos.contains(photo) else { return }
        var neighbour: LibraryPhoto?
        if current == photo, let i = photos.firstIndex(of: photo) {
            neighbour = i + 1 < photos.count ? photos[i + 1] : (i > 0 ? photos[i - 1] : nil)
            closePhoto()
        }
        do {
            try Library.remove(photo)
        } catch {
            self.error = String(localized: "Could not delete \(photo.name): \(error.localizedDescription)")
            refreshLibrary()
            return
        }
        thumbnails[photo.name] = nil
        edited.remove(photo.name)
        libraryIndex.favorites.remove(photo.name)
        libraryIndex.order.removeAll { $0 == photo.name }
        libraryIndex.dates[photo.name] = nil
        libraryIndex.save()
        if UserDefaults.standard.string(forKey: Self.lastPhotoKey) == photo.name {
            UserDefaults.standard.removeObject(forKey: Self.lastPhotoKey)
        }
        refreshLibrary()
        if let neighbour { await open(neighbour) }
    }

    /// Nothing open: the canvas empty, the photo's pending work dropped
    /// rather than saved (it is on its way out, or already saved), and the
    /// engine's frame let go.
    private func closePhoto() {
        burstTimer?.cancel()
        saveTimer?.cancel()
        thumbnailTimer?.cancel()
        current = nil
        hasPhoto = false
        print = nil
        fullPrint = nil
        before = nil
        opened = nil
        showingInfo = false
        undoStack = []
        redoStack = []
        burstBase = nil
        committed = nil
        updateUndoFlags()
        // The engine's copy of the frame goes too; the next open makes its own.
        let box = self.box
        queue.async {
            box.engine?.close()
            box.sessionFile = nil
            box.sessionCamera = nil
        }
    }

    private var currentIndex: Int? { current.flatMap { photos.firstIndex(of: $0) } }
    var hasPrevious: Bool { (currentIndex ?? 0) > 0 }
    var hasNext: Bool { currentIndex.map { $0 + 1 < photos.count } ?? false }

    func previous() async {
        guard let i = currentIndex, i > 0 else { return }
        await open(photos[i - 1])
    }

    func next() async {
        guard let i = currentIndex, i + 1 < photos.count else { return }
        await open(photos[i + 1])
    }

    /// Files chosen in Files: copied into the library, the first one opened.
    /// The copying runs off the main thread — a RAW in iCloud Drive is
    /// downloaded first, which can take a while — with the busy line saying
    /// so. While something else runs (an export), the import waits for it
    /// rather than being dropped.
    func importFiles(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        await waitUntilIdle()
        busy = urls.count == 1 ? String(localized: "Importing 1 photo from Files…")
                               : String(localized: "Importing \(urls.count) photos from Files…")
        let results = await Task.detached(priority: .userInitiated) {
            urls.map { url in (url, Result { try Library.importCopy(of: url) }) }
        }.value
        busy = nil
        var imported: [LibraryPhoto] = []
        for (url, result) in results {
            switch result {
            case .success(let photo): imported.append(photo)
            case .failure(let failure):
                error = String(localized: "Could not import \(url.lastPathComponent): \(failure.localizedDescription)")
            }
        }
        await finishImport(imported)
    }

    /// Photos chosen in Photos: their original files (the RAW when there is
    /// one) copied into the library, the first one opened. Waits, like an
    /// import from Files, while something else runs.
    func importFromPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        await waitUntilIdle()
        busy = items.count == 1 ? String(localized: "Importing 1 photo from Photos…")
                                : String(localized: "Importing \(items.count) photos from Photos…")
        var imported: [LibraryPhoto] = []
        var failed = 0
        for item in items {
            if let picked = try? await item.loadTransferable(type: PickedPhoto.self) {
                imported.append(picked.photo)
            } else {
                failed += 1
            }
        }
        busy = nil
        if failed > 0 {
            error = failed == 1 ? String(localized: "1 photo could not be imported from Photos.")
                                : String(localized: "\(failed) photos could not be imported from Photos.")
        }
        await finishImport(imported)
    }

    /// The imported photos join the library — with no thumbnail left over from
    /// an earlier photo of the same name — and the first one opens.
    private func finishImport(_ imported: [LibraryPhoto]) async {
        for photo in imported { thumbnails[photo.name] = nil }
        refreshLibrary()
        if let first = imported.first { await open(first) }
    }

    /// Until nothing else is running: an open, an export, a camera reread.
    private func waitUntilIdle() async {
        while busy != nil { try? await Task.sleep(for: .milliseconds(100)) }
    }

    /// At launch: the photo that was open last, else the library's first.
    private func reopenLast() async {
        let last = UserDefaults.standard.string(forKey: Self.lastPhotoKey)
        guard let photo = photos.first(where: { $0.name == last }) ?? photos.first else { return }
        await open(photo)
    }

    /// A settings edit: send what changed, render the preview, and measure the
    /// scene again. One render at a time; edits made meanwhile go together when
    /// it lands, so a slider drag renders its latest value, never a backlog.
    func settingsChanged() async {
        guard hasPhoto, busy == nil else { return }
        if rendering { pendingPush = true; return }
        rendering = true
        let box = self.box
        repeat {
            pendingPush = false
            let wire = settings.wire
            let delta = settings.delta(from: sentWire)
            if delta.isEmpty { break }
            do {
                let outcome = try await onEngine { try ProbeModel.push(delta, box: box) }
                sentWire = wire
                fullLines = []
                show(outcome)
                readLatitude(outcome.latitude)
            } catch {
                self.error = String(localized: "Could not apply the change: \(String(describing: error))")
                break
            }
        } while pendingPush
        rendering = false
        // Everything the controls ask for is on the canvas, so the enlarger's
        // light may run. A render that began before the change does not count:
        // the change is still unsent then.
        if settings.delta(from: sentWire).isEmpty { enlarger.settled() }
        saveResults()
    }

    /// Sends any pending change and waits until the engine has rendered it.
    func settle() async {
        await settingsChanged()
        while rendering { try? await Task.sleep(for: .milliseconds(50)) }
    }

    func selectFilm(_ id: String) { changeStock { $0.selectFilm(id) } }
    func selectPaper(_ id: String) { changeStock { $0.selectPaper(id) } }
    /// "No print profile": scan the developed film.
    func selectNoPrint() { changeStock { $0.scanFilm = true } }

    /// A change of film or paper. When it changes anything, the canvas shows
    /// it as an enlarger would (`EnlargerTransition`): the new film's negative
    /// of the picture, then the print developing in behind a light.
    private func changeStock(_ change: (inout FilmSettings) -> Void) {
        var next = settings
        change(&next)
        if next != settings && hasPhoto && busy == nil {
            enlarger.begin(kind: next.filmIsPositive ? .slide : next.filmIsMonochrome ? .monochrome : .colour)
        }
        settings = next
    }
    func setFrame(_ id: String) { settings.setFrame(id, aspect: aspect) }
    func setSide(_ side: FilmSide) { settings.setSide(side, aspect: aspect) }
    func setSideLength(_ mm: Double) { settings.setSideLength(mm, aspect: aspect) }
    /// The Mac's "As shot": the meter off and no compensation, so Film
    /// Exposure is the linear frame as the camera recorded it.
    func filmExposureAsShot() {
        settings.metering = .custom
        settings.exposureCompensationEV = 0
    }
    func resetEffects() { settings.effects = EffectStrengths() }

    // MARK: Scene Placement

    /// Through the engine's Fit (RFC-023): only a fit the engine accepts is
    /// committed. A refusal puts the sliders back and says why in words.
    func place(highlight: Double, shadow: Double) async {
        await placeWith(["highlight_pull_back": highlight, "shadow_pull_back": shadow])
    }

    /// The engine's own suggestion for this frame: a request naming neither
    /// side is solved at the suggested pull-backs.
    func suggestPlacement() async {
        await placeWith([:])
    }

    func resetPlacement() {
        settings.placement = ScenePlacement()
        highlightDraft = 0
        shadowDraft = 0
        placementNote = nil
    }

    private func placeWith(_ request: [String: Any]) async {
        guard hasPhoto else { return }
        await settle()      // the Fit reads the session as it is now
        let box = self.box
        do {
            let reply = try await onEngine { try ProbeModel.sceneLatitude(request, box: box) }
            readLatitude(reply)
            let fit = reply["fit"] as? [String: Any] ?? [:]
            func pullBack(_ side: String) -> Double {
                ((fit[side] as? [String: Any])?["pull_back"] as? NSNumber)?.doubleValue ?? 0
            }
            if (fit["valid"] as? Bool) == true, let delta = fit["params_delta"] as? [String: Any] {
                placementNote = nil
                settings.placement.apply(highlight: pullBack("highlight"), shadow: pullBack("shadow"),
                                         delta: delta)
            } else {
                let issue = (fit["issues"] as? [[String: Any]])?.first ?? [:]
                placementNote = ProbeModel.placementMessage(code: issue["code"] as? String,
                                                            side: issue["side"] as? String,
                                                            fallback: issue["message"] as? String)
            }
        } catch {
            placementNote = String(localized: "Scene Placement failed: \(String(describing: error))")
        }
        highlightDraft = settings.placement.highlightPullBack
        shadowDraft = settings.placement.shadowPullBack
    }

    /// The Mac's refusal sentences (`LatitudeModel.message`), in the interface's language.
    private static func placementMessage(code: String?, side: String?, fallback: String?) -> String {
        let top = side != "shadow"
        switch code {
        case "pull_back_below_minimum":
            return top ? String(localized: "Pull back further: the scene's brightest part is still past the latitude's edge.")
                       : String(localized: "Pull back further: the scene's darkest part is still past the latitude's edge.")
        case "room_below_minimum":
            return top ? String(localized: "Pull back a little more: this close to the latitude's edge the highlights would turn too sharply.")
                       : String(localized: "Pull back a little more: this close to the latitude's edge the shadows would turn too sharply.")
        case "out_of_range":
            return String(localized: "Pull back less: this is further than the curve can reach.")
        case "pull_back_exceeds_max_lift":
            return String(localized: "Pull back less: this is past the most the shadows can be lifted.")
        case "knees_cross":
            return String(localized: "The highlight and shadow curves would cross: pull back less on one side.")
        default:
            return fallback.map { String(localized: "Not applied: \($0)") } ?? String(localized: "Not applied.")
        }
    }

    /// The measurement, in the numbers a person can act on.
    private func readLatitude(_ reply: [String: Any]) {
        guard let medium = reply["medium"] as? [String: Any],
              let fit = reply["fit"] as? [String: Any] else { return }
        func d(_ o: Any?) -> Double { (o as? NSNumber)?.doubleValue ?? .nan }
        let high = fit["highlight"] as? [String: Any] ?? [:], low = fit["shadow"] as? [String: Any] ?? [:]
        var lines = [
            String(format: "Film + paper latitude: %.1f stops (%+.1f … %+.1f EV around mid-grey)",
                   d(medium["latitude_stops"]), d(medium["shadow_ev"]), d(medium["highlight_ev"])),
            String(format: "This scene: darkest %+.1f EV, brightest %+.1f EV",
                   d(low["scene_extreme_ev"]), d(high["scene_extreme_ev"])),
        ]
        var reading = LatitudeReading(stops: d(medium["latitude_stops"]),
                                      filmShadowEV: d(medium["shadow_ev"]), filmHighlightEV: d(medium["highlight_ev"]),
                                      sceneDarkestEV: d(low["scene_extreme_ev"]),
                                      sceneBrightestEV: d(high["scene_extreme_ev"]))
        if let suggested = reply["suggested"] as? [String: Any], (suggested["valid"] as? Bool) == true {
            lines.append(String(format: "Suggested pull-back: highlights %.2f, shadows %.2f stops",
                                d(suggested["highlight_pull_back"]), d(suggested["shadow_pull_back"])))
            reading.suggestedHighlight = d(suggested["highlight_pull_back"])
            reading.suggestedShadow = d(suggested["shadow_pull_back"])
        }
        latitudeLines = lines
        latitude = reading
    }

    /// The old name, from when JPEG was the only format.
    func exportJPEG() async { await export() }

    /// The picture at full resolution in the Export panel's format.
    func export() async {
        await settle()      // the export renders what the controls say
        guard hasPhoto, busy == nil, let opened, let renderer else { return }
        error = nil
        let film = settings.filmStock, paper = settings.printStock, options = exportOptions
        let uniforms = adjustments.uniforms, box = self.box, device = self.device, geometry = self.geometry
        let out = geometry.outputSize(for: sourceSize)
        busy = String(format: String(localized: "Exporting %.1f MP as sRGB %@…"),
                      Double(out.width * out.height) / 1e6, options.summary)
        let entries = backgroundEntries
        do {
            let outcome = try await onEngine {
                try ProbeModel.exportFull(opened: opened, film: film, paper: paper, options: options,
                                          uniforms: uniforms, geometry: geometry, box: box,
                                          renderer: renderer, device: device)
            }
            // Part of it may have run where the GPU is refused: not kept.
            guard backgroundEntries == entries else {
                if let url = outcome.url { try? FileManager.default.removeItem(at: url) }
                throw Engine.Failure(description: "the app left the screen")
            }
            lastExport = outcome.url
            lastExportSummary = String(format: String(localized: "%d × %d · %.1f MB · %@"),
                                       outcome.width, outcome.height,
                                       Double(outcome.bytes) / 1_000_000, options.summary)
            exportLines = [
                String(format: "Exported %@: %d × %d, %.1f MB, %@",
                       outcome.url?.lastPathComponent ?? "?", outcome.width, outcome.height,
                       Double(outcome.bytes) / 1_000_000, options.summary),
                String(format: "sRGB conversion: %.2f%% of pixels were outside sRGB and rolled into it; %.2f%% at the limits",
                       outcome.outsideFraction * 100, outcome.clippedFraction * 100),
                String(format: "Time: %.2f s (full render %.2f s, adjustments + sRGB %.2f s, writing the file %.2f s)",
                       outcome.totalSeconds, outcome.renderSeconds, outcome.gpuSeconds, outcome.writeSeconds),
                "Memory: available before \(Memory.mb(outcome.availableBefore)); peak \(Memory.mb(outcome.peak)); lowest available \(Memory.mb(outcome.minAvailable))",
                "Saved in Files › On My iPad › \(AppName.current) › Exports",
            ]
        } catch {
            self.error = backgroundEntries != entries
                ? String(localized: "The export stopped when RA4 left the screen, where apps may not use the graphics processor. Export it again.")
                : String(localized: "Export failed: \(String(describing: error))")
        }
        busy = nil
        saveResults()
    }

    func renderFull() async {
        await settle()
        guard hasPhoto, busy == nil, let opened else { return }
        error = nil
        let film = settings.filmStock, paper = settings.printStock, box = self.box
        busy = String(format: String(localized: "Rendering %.1f MP at full resolution…"), Double(opened.width * opened.height) / 1e6)
        do {
            let outcome = try await onEngine {
                try ProbeModel.renderFullTier(file: opened.file, width: opened.width, height: opened.height,
                                              film: film, paper: paper, box: box)
            }
            var lines = [
                "Available before render (os_proc_available_memory): \(Memory.mb(outcome.availableBefore))",
                "Footprint before render: \(Memory.mb(outcome.footprintBefore))",
                "Peak footprint during render: \(Memory.mb(outcome.peak)) (+\(Memory.mb(outcome.peak &- outcome.footprintBefore)))",
                "Lowest available during render: \(Memory.mb(outcome.minAvailable))",
                String(format: "Render time: %.2f s (engine's own timer: %.2f s)", outcome.seconds, outcome.engineMs / 1000),
            ]
            lines.append(outcome.succeeded
                         ? "Result: SUCCEEDED — \(outcome.width) × \(outcome.height)"
                         : "Result: FAILED — \(outcome.error)")
            lines.append("Engine pool high-water: \(Memory.mb(outcome.enginePoolHighWater)); engine holding now: \(Memory.mb(outcome.engineTotal))")
            lines.append("Footprint after render: \(Memory.mb(outcome.footprintAfter)); peak since launch: \(Memory.mb(outcome.lifetimePeak))")
            lines.append("Film / paper: \(StockCatalog.shared.name(film)) / \(StockCatalog.shared.name(paper))")
            fullLines = lines
        } catch {
            self.error = String(localized: "Full render could not start: \(String(describing: error))")
        }
        busy = nil
        saveResults()
    }

    private func show(_ preview: PreviewOutcome) {
        print = preview.print
        fullPrint = nil
        previewGeneration += 1
        scheduleEstimate()
        previewLines = [
            String(format: "Preview (live tier): %d × %d in %.0f ms (engine %.0f ms)",
                   preview.width, preview.height, preview.seconds * 1000, preview.engineMs),
            "Film / paper: \(StockCatalog.shared.name(settings.filmStock)) / "
                + (settings.scanFilm ? "no print (film scan)" : StockCatalog.shared.name(settings.printStock)),
            String(format: "Format: %@ %@ %.1f mm → long edge %.1f mm; meter %@, film exposure %+.2f EV",
                   settings.filmFrame, settings.filmSide.title, settings.sideLengthMM, settings.filmFormatMM,
                   settings.metering.title, settings.exposureCompensationEV),
        ]
    }

    func resetAdjustments() { adjustments = Adjustments() }

    func dismissCrashNote() { crashNote = nil }

    func copyResults() {
        UIPasteboard.general.string = resultsText()
    }

    private func resultsText() -> String {
        var text = ["RA-4 results"]
        if let crashNote { text += ["", "PREVIOUS RUN:", crashNote] }
        if let error { text += ["", "ERROR: \(error)"] }
        let a = adjustments
        let library = ["\(photos.count) photo(s): " + photos.map { $0.name + (edited.contains($0.name) ? " (edited)" : "") }
                           .joined(separator: ", "),
                       "Open: \(current?.name ?? "none"); undo steps \(undoStack.count), redo \(redoStack.count)",
                       String(format: "Adjustments: temperature %+.0f, tint %+.0f, exposure %+.2f, contrast %+.0f, highlights %+.0f, shadows %+.0f, black %.0f, white %.0f, saturation %+.0f, vibrance %+.0f",
                              a.temperature, a.tint, a.exposure, a.contrast, a.highlights, a.shadows,
                              a.blackPoint, a.whitePoint, a.saturation, a.vibrance)]
        let g = geometry, wb = camera.applied(asShot: asShot)
        let out = g.outputSize(for: sourceSize)
        let frame = [String(format: "Crop: %@, %.0f × %.0f, aspect %@, straighten %.1f°, %d quarter turn(s)%@%@",
                            g.isIdentity ? "none" : "yes", out.width, out.height, g.aspect.rawValue, g.angle,
                            g.quarterTurns, g.flipH ? ", flipped across" : "", g.flipV ? ", flipped upright" : ""),
                     String(format: "Camera: %@ %.0f K, tint %+.0f%@; lens correction %@",
                            camera.whiteBalance.rawValue, wb.temperature, wb.tint,
                            asShot.map { String(format: " (as shot %.0f K, %+.0f)", $0.temperature, $0.tint) } ?? "",
                            !lensCorrectionSupported ? "not in this file" : (camera.lensCorrection ? "on" : "off"))]
        for (title, lines) in [("Device", deviceLines), ("Library", library), ("Photo", photoLines), ("Preview", previewLines),
                               ("Frame and camera", hasPhoto ? frame + viewerLines : []),
                               ("Scene latitude", latitudeLines + (placementNote.map { ["Placement: " + $0] } ?? [])),
                               ("Export", exportLines),
                               ("Full-resolution render", fullLines)]
            where !lines.isEmpty {
            text += ["", title + ":"] + lines.map { "  " + $0 }
        }
        return text.joined(separator: "\n")
    }

    /// The same text, after every step, in Documents — visible in Files › On My
    /// iPad › RA4 Light Lab, and readable from the Mac with `devicectl`. (The
    /// file keeps the name it had when the app was RA-4.)
    private func saveResults() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? Data((resultsText() + "\n").utf8)
            .write(to: documents.appending(path: "RA-4 results.txt"), options: .atomic)
        // The file's name before the app was named RA-4.
        try? FileManager.default.removeItem(at: documents.appending(path: "SpektraProbe results.txt"))
    }

    // MARK: geometry, viewer and camera decode — the actions

    func rotate(clockwise: Bool) { geometry = geometry.turned(by: clockwise ? 1 : -1) }
    func flip(horizontal: Bool) {
        var g = geometry
        if horizontal { g.flipH.toggle() } else { g.flipV.toggle() }
        geometry = g
    }
    func straighten(to degrees: Double) { geometry = geometry.straightened(to: degrees, in: sourceSize) }
    /// The Mac's `CropSection.setAspect`: reshaped about its centre, its area
    /// kept, refitted.
    func setAspect(_ aspect: CropAspect) {
        var g = geometry
        g.aspect = aspect
        geometry = g.constrained(in: sourceSize)
    }
    func resetGeometry() { geometry = Geometry() }

    /// The pair the decode is using now: the camera's own under As Shot.
    var appliedWhiteBalance: AsShot { camera.applied(asShot: asShot) }

    /// The Mac's `setWhiteBalance`: a preset is its kelvin with no tint.
    func setWhiteBalance(_ mode: CameraDecode.WhiteBalance) {
        var c = camera
        c.whiteBalance = mode
        if let k = mode.kelvin { c.temperature = k; c.tint = 0 }
        else if mode == .asShot, let shot = asShot { c.temperature = shot.temperature; c.tint = shot.tint }
        camera = c
    }

    /// A slider let go: Custom at that value, the other axis where it was.
    func setCameraTemperature(_ kelvin: Double) {
        var c = camera
        c.tint = appliedWhiteBalance.tint
        c.temperature = kelvin
        c.whiteBalance = .custom
        camera = c
    }

    func setCameraTint(_ tint: Double) {
        var c = camera
        c.temperature = appliedWhiteBalance.temperature
        c.tint = tint
        c.whiteBalance = .custom
        camera = c
    }

    func setLensCorrection(_ on: Bool) { camera.lensCorrection = on }

    /// The eyedropper: the RAW filter's estimate of the white balance that
    /// makes the tapped point (0…1 across the canvas's picture) neutral.
    func pickNeutral(atOutput u: CGPoint) {
        pickingNeutral = false
        guard hasPhoto, photoIsRAW, let photo = current else { return }
        let point = geometry.sourcePoint(forOutput: u, imageSize: sourceSize)
        let decode = camera
        Task {
            let measured = await Task.detached(priority: .userInitiated) {
                RAWDecode.neutral(at: point, in: photo.url, camera: decode)
            }.value
            guard let measured, current == photo else { return }
            var c = camera
            c.whiteBalance = .custom
            c.temperature = measured.temperature.clamped(to: CameraDecode.temperatureRange)
            c.tint = measured.tint.clamped(to: CameraDecode.tintRange)
            camera = c
        }
    }

    private func cameraDidChange() {
        guard !applyingState else { return }
        editHappened()
        Task { await reopenForCamera() }
    }

    /// Reads the RAW again with the camera decode the controls say and opens
    /// the engine on it, keeping every other edit — the Mac's redecode. One at
    /// a time; a change made meanwhile is read when this one lands. Engine
    /// pushes wait meanwhile (`rendering`), and go together after.
    ///
    /// `again`: read it even though the decode has not changed — the engine's
    /// work on it was cut off when the app left the screen (`sceneChanged`).
    func reopenForCamera(again: Bool = false) async {
        // The photo is the one open once the cut-off work has finished, which
        // may be the very open that was cut off.
        if again { while reopening || busy != nil || opening { try? await Task.sleep(for: .milliseconds(50)) } }
        guard hasPhoto, let photo = current else { return }
        if reopening { pendingReopen = true; return }
        reopening = true
        while rendering { try? await Task.sleep(for: .milliseconds(30)) }
        rendering = true
        let device = self.device, box = self.box, edge = previewEdge
        var force = again
        repeat {
            pendingReopen = false
            let camera = self.camera, settings = self.settings
            // Checked in the same main-actor turn as the engine call below, so
            // an open cannot slip in between: while another photo is opening,
            // this one's reread is dropped (its edit is already saved with it).
            if (camera == appliedCamera && !force) || current != photo || opening || !hasPhoto { break }
            busy = force ? String(localized: "Developing the photo again…")
                         : String(localized: "Developing with the new white balance…")
            force = false
            let started = CFAbsoluteTimeGetCurrent()
            do {
                let outcome = try await onEngine {
                    try ProbeModel.openAndPreview(photo.url, settings: settings, camera: camera, edge: edge,
                                                  device: device, box: box, progress: { _ in })
                }
                guard current == photo, !opening else { break }
                opened = outcome
                appliedCamera = camera
                sentWire = outcome.sentWire
                // Only the film format, which follows the frame's shape; any
                // other setting edited meanwhile is newer than the reopen's.
                applyingState = true
                self.settings.filmFormatMM = outcome.settings.filmFormatMM
                applyingState = false
                asShot = outcome.asShot
                lensCorrectionSupported = outcome.lensCorrectionSupported
                displayTransform = outcome.display
                readLatitude(outcome.latitude)
                before = nil
                beforeTask?.cancel()
                beforeTask = nil
                show(outcome.preview)
                ensureBefore()
                viewerLines.append(String(format: "Camera %@ %.0f K, tint %+.0f, lens %@: RAW read again and the engine reopened in %.2f s",
                                          camera.whiteBalance.rawValue, camera.applied(asShot: asShot).temperature,
                                          camera.applied(asShot: asShot).tint, camera.lensCorrection ? "on" : "off",
                                          CFAbsoluteTimeGetCurrent() - started))
            } catch {
                self.error = String(localized: "Could not apply the white balance: \(String(describing: error))")
                await closeIfEngineLeft()
                break
            }
        } while pendingReopen
        rendering = false
        reopening = false
        // An open that started meanwhile owns `busy` and sends its own settings.
        guard !opening else { return }
        busy = nil
        await settingsChanged()
        saveResults()
    }

    /// Makes the before picture in the background if it is missing: Apple's
    /// own development of the RAW, read with the same white balance and lens
    /// correction as the engine's frame.
    func ensureBefore() {
        guard hasPhoto, before == nil, beforeTask == nil, let photo = current else { return }
        let decode = appliedCamera, edge = previewEdge, device = self.device
        beforeTask = Task { [weak self] in
            let made = await Task.detached(priority: .utility) {
                RAWDecode.beforeTexture(photo.url, camera: decode, longEdge: edge, device: device)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.beforeTask = nil
            if self.current == photo, self.appliedCamera == decode { self.before = made } else { self.ensureBefore() }
        }
    }

    /// The canvas has been zoomed past what the preview holds: render the
    /// full tier once and keep it while the print stays what it is.
    func requestFullResolution() {
        guard hasPhoto, fullPrint == nil, !fullInFlight, busy == nil, !rendering else { return }
        fullInFlight = true
        let generation = previewGeneration, box = self.box, entries = backgroundEntries
        let started = CFAbsoluteTimeGetCurrent()
        Task {
            let rendered = try? await onEngine { () -> Engine.Rendered in
                guard let engine = box.engine else { throw Engine.Failure(description: "the engine is not running") }
                return try engine.render(tier: "full")
            }
            fullInFlight = false
            guard let rendered, generation == previewGeneration, backgroundEntries == entries else { return }
            fullPrint = rendered.texture
            viewerLines.append(String(format: "Zoomed canvas: full-resolution print %d × %d in %.2f s",
                                      rendered.width, rendered.height, CFAbsoluteTimeGetCurrent() - started))
            if viewerLines.count > 8 { viewerLines.removeFirst(viewerLines.count - 8) }
        }
    }

    // MARK: the export's estimated size

    /// After a moment's quiet, while the Export panel is up.
    private func scheduleEstimate() {
        guard exportPanelShown, hasPhoto else { return }
        estimateTask?.cancel()
        estimateTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.estimateExportSize()
        }
    }

    /// The live print through the export's own chain — Layer 2, sRGB, the
    /// crop — encoded in the chosen format in memory; its bytes per pixel, times
    /// the full-resolution output's pixels and the format's measured
    /// full-resolution factor. Measured (`--selftest-export`): within 3.5 % of
    /// the written file for every format, on the frame the factors came from
    /// and on another film with a 1:1 crop.
    func estimateExportSize() async {
        guard hasPhoto, let print, let renderer, let opened else { return }
        let options = exportOptions, uniforms = adjustments.uniforms, geometry = self.geometry
        let box = self.box, device = self.device, full = geometry.outputSize(for: sourceSize)
        guard let srgb = try? await onEngine({
            try ProbeModel.transform(box: box, source: opened.workingSpace, targetName: "sRGB",
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!, device: device)
        }) else { return }
        let bytes = await Task.detached(priority: .utility) { () -> Int? in
            guard let finished = try? renderer.finish(print: print, uniforms: uniforms, transform: srgb,
                                                      geometry: geometry),
                  let image = Renderer.makeCGImage(finished.texture, space: srgb.space),
                  let encoded = ImageExport.encodedSize(image, options: options) else { return nil }
            let perPixel = Double(encoded) / Double(image.width * image.height)
            return Int(perPixel * full.width * full.height * options.format.fullResolutionFactor(bits: options.bits))
        }.value
        guard !Task.isCancelled, options == exportOptions else { return }
        exportEstimateBytes = bytes
        exportEstimate = bytes.map {
            let mb = Double($0) / 1_000_000
            return mb >= 10 ? String(format: "≈ %.0f MB", mb) : String(format: "≈ %.1f MB", mb)
        }
    }

    // MARK: the engine-queue halves (no main-actor state in here)

    nonisolated private static func now() -> Double { CFAbsoluteTimeGetCurrent() }

    /// The engine's numbers for `source` → `targetName`, fetched once per pair.
    nonisolated private static func transform(box: EngineBox, source: String, targetName: String,
                                              space: CGColorSpace, device: MTLDevice) throws -> ColourTransform {
        let key = "\(source)→\(targetName)"
        if let hit = box.transforms[key] { return hit }
        guard let engine = box.engine else { throw Engine.Failure(description: "the engine is not running") }
        let made = try ColourTransform.make(engine: engine, source: source, targetName: targetName,
                                            space: space, device: device)
        box.transforms[key] = made
        return made
    }

    nonisolated private static func openAndPreview(_ url: URL, settings: FilmSettings, camera: CameraDecode,
                                                   edge: Int, device: MTLDevice, box: EngineBox,
                                                   progress: @escaping (String) -> Void) throws -> OpenOutcome {
        guard let engine = box.engine else { throw Engine.Failure(description: "the engine is not running") }
        var outcome = OpenOutcome()
        outcome.file = url.lastPathComponent
        let local = url
        outcome.sourceMetadata = ImageExport.sourceMetadata(of: local)

        progress(String(localized: "Decoding the RAW and opening it in the engine…"))
        InFlight.begin(stage: "decoding and opening", details: ["file": outcome.file])
        defer { InFlight.end() }
        let sampler = PeakSampler()
        sampler.start { peak, available in InFlight.update(peak: peak, minAvailable: available) }
        defer { _ = sampler.stop() }

        let decoded = try RAWDecode.decode(local, camera: camera)
        outcome.camera = camera
        outcome.asShot = decoded.asShot
        outcome.lensCorrectionSupported = decoded.lensCorrectionSupported
        outcome.width = decoded.width
        outcome.height = decoded.height
        outcome.isRAW = decoded.isRAW
        let bytes = decoded.width * decoded.height * 16
        outcome.frameBytes = bytes
        // The film format follows the photograph's own shape (the Mac's
        // `recomputeFilmFormat(beforeOpen:)`), so it goes in with the open.
        var settings = settings
        let aspect = Double(max(decoded.width, decoded.height)) / Double(max(1, min(decoded.width, decoded.height)))
        settings.filmFormatMM = FilmSettings.filmFormatMM(side: settings.filmSide,
                                                          sideLengthMM: settings.sideLengthMM, aspect: aspect)
        outcome.settings = settings
        outcome.sentWire = settings.wire
        var delta = settings.delta(from: [:])
        delta["preview_long_edge"] = edge
        delta["product_defaults"] = true
        let started = now()
        var reply: [String: Any] = [:]
        box.sessionFile = nil
        box.sessionCamera = nil
        try autoreleasepool {
            // The Mac app's path: one shared Metal buffer the engine borrows.
            if bytes <= device.maxBufferLength,
               let buffer = device.makeBuffer(length: bytes, options: .storageModeShared) {
                outcome.viaMetalBuffer = true
                RAWDecode.renderFrame(decoded, into: buffer.contents())
                let rendered = now()
                outcome.decodeSeconds = rendered - started
                reply = try engine.open(buffer: buffer, width: decoded.width, height: decoded.height, delta: delta)
                outcome.openSeconds = now() - rendered
            } else {
                outcome.viaMetalBuffer = false
                let host = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 64)
                defer { host.deallocate() }
                RAWDecode.renderFrame(decoded, into: host)
                let rendered = now()
                outcome.decodeSeconds = rendered - started
                reply = try engine.open(host: host.assumingMemoryBound(to: Float.self),
                                        width: decoded.width, height: decoded.height, delta: delta)
                outcome.openSeconds = now() - rendered
            }
        }
        outcome.peakFootprint = sampler.stop().peak
        // The space the pixels come out in is the engine's to say (RFC-018 §5.1).
        if let params = reply["params"] as? [String: Any], let space = params["output_color_space"] as? String {
            outcome.workingSpace = space
        }
        outcome.display = try transform(box: box, source: outcome.workingSpace, targetName: "Display P3",
                                        space: CGColorSpace(name: CGColorSpace.displayP3)!, device: device)

        progress(String(localized: "Rendering the preview…"))
        outcome.preview = try preview(engine: engine)
        outcome.latitude = (try? engine.sceneLatitude([:])) ?? [:]
        box.sessionFile = url
        box.sessionCamera = camera
        return outcome
    }

    /// A settings delta, then the preview, then the scene measured again.
    nonisolated private static func push(_ delta: [String: Any], box: EngineBox) throws -> PreviewOutcome {
        guard let engine = box.engine else { throw Engine.Failure(description: "the engine is not running") }
        try engine.setParams(delta)
        var outcome = try preview(engine: engine)
        outcome.latitude = (try? engine.sceneLatitude([:])) ?? [:]
        return outcome
    }

    nonisolated private static func sceneLatitude(_ request: [String: Any], box: EngineBox) throws -> [String: Any] {
        guard let engine = box.engine else { throw Engine.Failure(description: "the engine is not running") }
        return try engine.sceneLatitude(request)
    }

    nonisolated private static func preview(engine: Engine) throws -> PreviewOutcome {
        var outcome = PreviewOutcome()
        let started = now()
        let rendered = try engine.render(tier: "live")
        outcome.seconds = now() - started
        outcome.engineMs = rendered.engineMs
        outcome.width = rendered.width
        outcome.height = rendered.height
        outcome.print = rendered.texture
        return outcome
    }

    /// The Mac app's export chain at the frame's own size: the engine's full
    /// tier → Layer 2 → the output transform into sRGB → 8 bits → JPEG.
    nonisolated private static func exportFull(opened: OpenOutcome, film: String, paper: String,
                                               options: ExportOptions, uniforms: Layer2Uniforms, geometry: Geometry,
                                                   box: EngineBox, renderer: Renderer,
                                                   device: MTLDevice) throws -> ExportOutcome {
        guard let engine = box.engine else { throw Engine.Failure(description: "the engine is not running") }
        let srgb = try transform(box: box, source: opened.workingSpace, targetName: "sRGB",
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!, device: device)
        var outcome = ExportOutcome()
        outcome.availableBefore = Memory.available()
        InFlight.begin(stage: "JPEG export",
                       details: ["file": opened.file, "width": opened.width, "height": opened.height,
                                 "film": film, "paper": paper])
        defer { InFlight.end() }
        let sampler = PeakSampler()
        sampler.start { peak, available in InFlight.update(peak: peak, minAvailable: available) }
        defer { _ = sampler.stop() }

        let started = now()
        let image: CGImage
        do {
            // Scoped so the full print and the converted texture are released
            // as soon as their pixels have been copied out.
            let converted: MTLTexture
            let stats: TransformStats
            do {
                let full = try engine.render(tier: "full")
                outcome.renderSeconds = now() - started
                (converted, stats) = try renderer.finish(print: full.texture, uniforms: uniforms, transform: srgb,
                                                         geometry: geometry)
                outcome.width = converted.width
                outcome.height = converted.height
            }
            guard let made = Renderer.makeCGImage(converted, space: srgb.space) else {
                throw ImageExport.Failure(description: "could not read the converted picture back")
            }
            image = made
            outcome.outsideFraction = stats.outsideFraction
            outcome.clippedFraction = stats.clippedFraction
        }
        let convertedAt = now()
        outcome.gpuSeconds = convertedAt - started - outcome.renderSeconds
        let url = try ImageExport.freshURL(for: opened.file, format: options.format)
        try ImageExport.write(image, to: url, options: options, source: opened.sourceMetadata)
        outcome.writeSeconds = now() - convertedAt
        outcome.totalSeconds = now() - started
        (outcome.peak, outcome.minAvailable) = sampler.stop()
        outcome.url = url
        outcome.bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return outcome
    }

    nonisolated private static func renderFullTier(file: String, width: Int, height: Int,
                                                   film: String, paper: String,
                                                   box: EngineBox) throws -> FullOutcome {
        guard let engine = box.engine else { throw Engine.Failure(description: "the engine is not running") }
        var outcome = FullOutcome()
        outcome.availableBefore = Memory.available()
        outcome.footprintBefore = Memory.footprint()
        InFlight.begin(stage: "full-resolution render",
                       details: ["file": file, "width": width, "height": height, "film": film, "paper": paper])
        defer { InFlight.end() }
        let sampler = PeakSampler()
        sampler.start { peak, available in InFlight.update(peak: peak, minAvailable: available) }
        let started = now()
        do {
            let rendered = try engine.render(tier: "full")
            outcome.seconds = now() - started
            (outcome.peak, outcome.minAvailable) = sampler.stop()
            outcome.succeeded = true
            outcome.width = rendered.width
            outcome.height = rendered.height
            outcome.engineMs = rendered.engineMs
        } catch {
            outcome.seconds = now() - started
            (outcome.peak, outcome.minAvailable) = sampler.stop()
            outcome.error = "\(error)"
        }
        let report = engine.memoryReport()
        outcome.engineTotal = report["total_bytes"] as? Double ?? 0
        outcome.enginePoolHighWater = (report["pool"] as? [String: Any])?["frame_high_water_bytes"] as? Double ?? 0
        outcome.footprintAfter = Memory.footprint()
        outcome.lifetimePeak = Memory.lifetimePeak()
        return outcome
    }

    // MARK: describing the device

    private static func screenLongEdgePixels() -> Int {
        let screen = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
        let pixels = screen.map { max($0.nativeBounds.width, $0.nativeBounds.height) } ?? 2560
        return min(8192, max(800, Int(pixels)))
    }

    private static func modelIdentifier() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// Whether the provisioning profile this build was signed with grants the
    /// entitlement. A free team's profile only carries what Apple allowed.
    private static func profileGrantsIncreasedMemoryLimit() -> String {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1),
              let start = text.range(of: "<?xml"), let end = text.range(of: "</plist>"),
              let plist = try? PropertyListSerialization.propertyList(
                  from: Data(text[start.lowerBound..<end.upperBound].utf8), format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any]
        else { return "unknown (no provisioning profile found)" }
        return (entitlements["com.apple.developer.kernel.increased-memory-limit"] as? Bool) == true
            ? "YES" : "NO"
    }

    private static func describeDevice(_ device: MTLDevice) -> [String] {
        let footprint = Memory.footprint(), available = Memory.available()
        return [
            "Device: \(modelIdentifier()), iPadOS/iOS \(UIDevice.current.systemVersion), RAM \(Memory.mb(ProcessInfo.processInfo.physicalMemory))",
            "GPU: \(device.name); max buffer \(Memory.mb(UInt64(device.maxBufferLength))); recommended working set \(Memory.mb(device.recommendedMaxWorkingSetSize))",
            "increased-memory-limit in provisioning profile: \(profileGrantsIncreasedMemoryLimit())",
            "App memory limit at launch ≈ \(Memory.mb(footprint + available)) (footprint \(Memory.mb(footprint)) + available \(Memory.mb(available)))",
        ]
    }

    private static func describeLeftover(_ note: [String: Any]?) -> String? {
        guard let note else { return nil }
        let stage = note["stage"] as? String ?? "a step"
        let file = note["file"] as? String ?? "?"
        var text = "The previous run never finished \(stage) of \(file): iOS ended the app, almost certainly for exceeding its memory limit."
        if let w = note["width"] as? Int, let h = note["height"] as? Int {
            text += String(format: " Frame: %d × %d (%.1f MP).", w, h, Double(w * h) / 1e6)
        }
        if let available = note["availableBefore"] as? Double {
            text += " Available before: \(Memory.mb(available))."
        }
        if let peak = note["peak"] as? Double {
            text += " Highest footprint recorded before the end: \(Memory.mb(peak))"
            if let low = note["minAvailable"] as? Double { text += ", with \(Memory.mb(low)) still available" }
            text += " (sampled every 5 ms, saved every 0.2 s)."
        }
        return text
    }
}
