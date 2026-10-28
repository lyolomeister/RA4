//  ProbeModel.swift — the app's steps, and the numbers each one reports.
//
//  Every engine call runs on one serial queue (the engine is not thread-safe)
//  and the main actor only shows results. The colour chain is the Mac app's:
//  the engine prints in ProPhoto RGB, Layer 2 (`Adjustments`) grades in
//  ProPhoto, and the picture leaves ProPhoto exactly once per destination —
//  Display P3 for the canvas, sRGB for a JPEG export — through the engine's
//  own output transform.

import Metal
import SwiftUI
import UIKit

/// The engine and its fetched colour transforms live here and are touched
/// only on `ProbeModel.queue`.
final class EngineBox: @unchecked Sendable {
    var engine: Engine?
    var transforms: [String: ColourTransform] = [:]
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
    var sourceEXIF: [CFString: Any]?
    var preview = PreviewOutcome()
    var display: ColourTransform?
    /// The settings the frame was opened with (the film format derived from
    /// its aspect), and exactly what was sent, so later edits go as deltas.
    var settings = FilmSettings()
    var sentWire: [String: ParamValue] = [:]
    var latitude: [String: Any] = [:]
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
    @Published var settings = FilmSettings()
    @Published var adjustments = Adjustments()
    /// JPEG quality, 10…100. The Mac app's default is 0.95.
    @Published var exportQuality: Double = 95
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

    /// What the canvas draws: the live print and the working space → P3 transform.
    @Published private(set) var print: MTLTexture?
    @Published private(set) var displayTransform: ColourTransform?
    @Published private(set) var lastExport: URL?

    @Published var deviceLines: [String] = []
    @Published var photoLines: [String] = []
    @Published var previewLines: [String] = []
    @Published var fullLines: [String] = []
    @Published var exportLines: [String] = []

    let renderer: Renderer?
    private let queue = DispatchQueue(label: "SpektraProbe.engine", qos: .userInitiated)
    private let device: MTLDevice = MTLCreateSystemDefaultDevice()!
    private let box = EngineBox()
    private var opened: OpenOutcome?
    private var previewEdge = 2560
    /// What the engine was last told, field by field.
    private var sentWire: [String: ParamValue] = [:]
    /// An edit arrived while a render was running.
    private var pendingPush = false

    /// long ÷ short of the open photograph, for the film format (the Mac's
    /// `physicalAspect`; a crop does not count, which is its default too).
    var aspect: Double {
        guard let opened, opened.width > 0, opened.height > 0 else { return 1.5 }
        return Double(max(opened.width, opened.height)) / Double(min(opened.width, opened.height))
    }

    init() {
        renderer = try? Renderer(device: device)
        crashNote = ProbeModel.describeLeftover(InFlight.takeLeftover())
        deviceLines = ProbeModel.describeDevice(device)
        if renderer == nil { error = "The canvas shaders did not load." }
        Task {
            await startEngine()
            await runSelfTestIfAsked()
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
    private func runSelfTestIfAsked() async {
        let arguments = ProcessInfo.processInfo.arguments
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if let i = arguments.firstIndex(of: "--open"), i + 1 < arguments.count {
            await load(documents.appending(path: arguments[i + 1]))
            return
        }
        if let i = arguments.firstIndex(of: "--selftest-film"), i + 1 < arguments.count {
            await load(documents.appending(path: arguments[i + 1]))
            if hasPhoto { await runFilmSelfTest() }
            return
        }
        guard let i = arguments.firstIndex(of: "--selftest"), i + 1 < arguments.count else { return }
        await load(documents.appending(path: arguments[i + 1]))
        guard hasPhoto else { return }
        exportQuality = 95
        await exportJPEG()
        adjustments = Adjustments(temperature: 40, exposure: 0.7, contrast: 20, highlights: -40,
                                  shadows: 30, saturation: -10, vibrance: 60)
        exportQuality = 60
        await exportJPEG()
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

    // MARK: running work on the engine's queue

    private func onEngine<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            queue.async { continuation.resume(with: Result(catching: work)) }
        }
    }

    private func progressReporter() -> (String) -> Void {
        { [weak self] text in Task { @MainActor in self?.busy = text } }
    }

    // MARK: steps

    func startEngine() async {
        busy = "Starting the engine…"
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
            self.error = "The engine did not start: \(error)"
        }
        busy = nil
        saveResults()
    }

    func load(_ url: URL) async {
        guard busy == nil else { return }
        error = nil
        previewEdge = ProbeModel.screenLongEdgePixels()
        let settings = self.settings, edge = previewEdge
        let device = self.device, box = self.box, progress = progressReporter()
        busy = "Copying \(url.lastPathComponent) into the app…"
        do {
            let outcome = try await onEngine {
                try ProbeModel.openAndPreview(url, settings: settings, edge: edge,
                                              device: device, box: box, progress: progress)
            }
            opened = outcome
            // What was sent first, then the settings, so the change this makes
            // is already on the engine and sends nothing.
            sentWire = outcome.sentWire
            self.settings = outcome.settings
            highlightDraft = outcome.settings.placement.highlightPullBack
            shadowDraft = outcome.settings.placement.shadowPullBack
            placementNote = nil
            readLatitude(outcome.latitude)
            hasPhoto = true
            // Each photo starts as the pure simulation; edits are not stored yet.
            adjustments = Adjustments()
            fullLines = []
            exportLines = []
            lastExport = nil
            displayTransform = outcome.display
            show(outcome.preview)
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
            ]
        } catch {
            self.error = "Could not open \(url.lastPathComponent): \(error)"
        }
        busy = nil
        saveResults()
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
                self.error = "Could not apply the change: \(error)"
                break
            }
        } while pendingPush
        rendering = false
        saveResults()
    }

    /// Sends any pending change and waits until the engine has rendered it.
    func settle() async {
        await settingsChanged()
        while rendering { try? await Task.sleep(for: .milliseconds(50)) }
    }

    func selectFilm(_ id: String) { settings.selectFilm(id) }
    func selectPaper(_ id: String) { settings.selectPaper(id) }
    /// "No print profile": scan the developed film.
    func selectNoPrint() { settings.scanFilm = true }
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
            placementNote = "Scene Placement failed: \(error)"
        }
        highlightDraft = settings.placement.highlightPullBack
        shadowDraft = settings.placement.shadowPullBack
    }

    /// The Mac's refusal sentences (`LatitudeModel.message`), in English.
    private static func placementMessage(code: String?, side: String?, fallback: String?) -> String {
        let top = side != "shadow"
        switch code {
        case "pull_back_below_minimum":
            return top ? "Pull back further: the scene's brightest part is still past the latitude's edge."
                       : "Pull back further: the scene's darkest part is still past the latitude's edge."
        case "room_below_minimum":
            return top ? "Pull back a little more: this close to the latitude's edge the highlights would turn too sharply."
                       : "Pull back a little more: this close to the latitude's edge the shadows would turn too sharply."
        case "out_of_range":
            return "Pull back less: this is further than the curve can reach."
        case "pull_back_exceeds_max_lift":
            return "Pull back less: this is past the most the shadows can be lifted."
        case "knees_cross":
            return "The highlight and shadow curves would cross: pull back less on one side."
        default:
            return fallback.map { "Not applied: \($0)" } ?? "Not applied."
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
        if let suggested = reply["suggested"] as? [String: Any], (suggested["valid"] as? Bool) == true {
            lines.append(String(format: "Suggested pull-back: highlights %.2f, shadows %.2f stops",
                                d(suggested["highlight_pull_back"]), d(suggested["shadow_pull_back"])))
        }
        latitudeLines = lines
    }

    func exportJPEG() async {
        await settle()      // the export renders what the controls say
        guard hasPhoto, busy == nil, let opened, let renderer else { return }
        error = nil
        let film = settings.filmStock, paper = settings.printStock, quality = exportQuality / 100
        let uniforms = adjustments.uniforms, box = self.box, device = self.device
        busy = String(format: "Exporting %.1f MP as an sRGB JPEG…", Double(opened.width * opened.height) / 1e6)
        do {
            let outcome = try await onEngine {
                try ProbeModel.exportFullJPEG(opened: opened, film: film, paper: paper, quality: quality,
                                              uniforms: uniforms, box: box, renderer: renderer, device: device)
            }
            lastExport = outcome.url
            exportLines = [
                String(format: "Exported %@: %d × %d, %.1f MB, quality %.0f",
                       outcome.url?.lastPathComponent ?? "?", outcome.width, outcome.height,
                       Double(outcome.bytes) / 1_000_000, quality * 100),
                String(format: "sRGB conversion: %.2f%% of pixels were outside sRGB and rolled into it; %.2f%% at the limits",
                       outcome.outsideFraction * 100, outcome.clippedFraction * 100),
                String(format: "Time: %.2f s (full render %.2f s, adjustments + sRGB %.2f s, JPEG %.2f s)",
                       outcome.totalSeconds, outcome.renderSeconds, outcome.gpuSeconds, outcome.writeSeconds),
                "Memory: available before \(Memory.mb(outcome.availableBefore)); peak \(Memory.mb(outcome.peak)); lowest available \(Memory.mb(outcome.minAvailable))",
                "Saved in Files › On My iPad › SpektraProbe › Exports",
            ]
        } catch {
            self.error = "Export failed: \(error)"
        }
        busy = nil
        saveResults()
    }

    func renderFull() async {
        await settle()
        guard hasPhoto, busy == nil, let opened else { return }
        error = nil
        let film = settings.filmStock, paper = settings.printStock, box = self.box
        busy = String(format: "Rendering %.1f MP at full resolution…", Double(opened.width * opened.height) / 1e6)
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
            self.error = "Full render could not start: \(error)"
        }
        busy = nil
        saveResults()
    }

    private func show(_ preview: PreviewOutcome) {
        print = preview.print
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
        var text = ["SpektraProbe results"]
        if let crashNote { text += ["", "PREVIOUS RUN:", crashNote] }
        if let error { text += ["", "ERROR: \(error)"] }
        for (title, lines) in [("Device", deviceLines), ("Photo", photoLines), ("Preview", previewLines),
                               ("Scene latitude", latitudeLines + (placementNote.map { ["Placement: " + $0] } ?? [])),
                               ("Export", exportLines),
                               ("Full-resolution render", fullLines)]
            where !lines.isEmpty {
            text += ["", title + ":"] + lines.map { "  " + $0 }
        }
        return text.joined(separator: "\n")
    }

    /// The same text, after every step, in Documents — visible in Files › On My
    /// iPad › SpektraProbe, and readable from the Mac with `devicectl`.
    private func saveResults() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? Data((resultsText() + "\n").utf8)
            .write(to: documents.appending(path: "SpektraProbe results.txt"), options: .atomic)
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

    nonisolated private static func openAndPreview(_ url: URL, settings: FilmSettings, edge: Int,
                                                   device: MTLDevice, box: EngineBox,
                                                   progress: @escaping (String) -> Void) throws -> OpenOutcome {
        guard let engine = box.engine else { throw Engine.Failure(description: "the engine is not running") }
        var outcome = OpenOutcome()
        outcome.file = url.lastPathComponent
        let local = try copyIn(url)
        outcome.sourceEXIF = JPEGExport.sourceEXIF(of: local)

        progress("Decoding the RAW and opening it in the engine…")
        InFlight.begin(stage: "decoding and opening", details: ["file": outcome.file])
        defer { InFlight.end() }
        let sampler = PeakSampler()
        sampler.start { peak, available in InFlight.update(peak: peak, minAvailable: available) }
        defer { _ = sampler.stop() }

        let decoded = try RAWDecode.decode(local)
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

        progress("Rendering the preview…")
        outcome.preview = try preview(engine: engine)
        outcome.latitude = (try? engine.sceneLatitude([:])) ?? [:]
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
    nonisolated private static func exportFullJPEG(opened: OpenOutcome, film: String, paper: String,
                                                   quality: Double, uniforms: Layer2Uniforms,
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
                outcome.width = full.width
                outcome.height = full.height
                (converted, stats) = try renderer.finish(print: full.texture, uniforms: uniforms, transform: srgb)
            }
            guard let made = Renderer.makeCGImage(converted, space: srgb.space) else {
                throw JPEGExport.Failure(description: "could not read the converted picture back")
            }
            image = made
            outcome.outsideFraction = stats.outsideFraction
            outcome.clippedFraction = stats.clippedFraction
        }
        let convertedAt = now()
        outcome.gpuSeconds = convertedAt - started - outcome.renderSeconds
        let url = try JPEGExport.freshURL(for: opened.file)
        try JPEGExport.write(image, to: url, quality: quality, sourceEXIF: opened.sourceEXIF)
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

    /// A private copy, so Core Image reads a local file and not a security-scoped
    /// one that may live in iCloud or on a USB drive.
    nonisolated private static func copyIn(_ url: URL) throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dir = FileManager.default.temporaryDirectory.appending(path: "picked", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let destination = dir.appending(path: url.lastPathComponent)
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinationError) { readable in
            do { try FileManager.default.copyItem(at: readable, to: destination) } catch { copyError = error }
        }
        if let failure = coordinationError ?? copyError { throw failure }
        return destination
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
