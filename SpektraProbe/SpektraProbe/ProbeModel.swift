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
}

struct PreviewOutcome {
    /// The engine's live print, ROMM-encoded. The texture owns its pixels.
    var print: MTLTexture?
    var width = 0, height = 0
    var seconds = 0.0
    var engineMs = 0.0
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
    @Published var film = Stocks.defaultFilm
    @Published var paper = Stocks.defaultPaper
    @Published var adjustments = Adjustments()
    /// JPEG quality, 10…100. The Mac app's default is 0.95.
    @Published var exportQuality: Double = 95
    @Published var busy: String?
    @Published var error: String?
    @Published var crashNote: String?
    @Published var hasPhoto = false

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
    private func runSelfTestIfAsked() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard let i = arguments.firstIndex(of: "--selftest"), i + 1 < arguments.count else { return }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        await load(documents.appending(path: arguments[i + 1]))
        guard hasPhoto else { return }
        exportQuality = 95
        await exportJPEG()
        adjustments = Adjustments(temperature: 40, exposure: 0.7, contrast: 20, highlights: -40,
                                  shadows: 30, saturation: -10, vibrance: 60)
        exportQuality = 60
        await exportJPEG()
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
        let film = self.film, paper = self.paper, edge = previewEdge
        let device = self.device, box = self.box, progress = progressReporter()
        busy = "Copying \(url.lastPathComponent) into the app…"
        do {
            let outcome = try await onEngine {
                try ProbeModel.openAndPreview(url, film: film, paper: paper, edge: edge,
                                              device: device, box: box, progress: progress)
            }
            opened = outcome
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

    func stocksChanged() async {
        guard hasPhoto, busy == nil else { return }
        error = nil
        let film = self.film, paper = self.paper, box = self.box
        busy = "Re-rendering on \(Stocks.name(film)) / \(Stocks.name(paper))…"
        do {
            let outcome = try await onEngine {
                try ProbeModel.restock(film: film, paper: paper, box: box)
            }
            fullLines = []
            show(outcome)
        } catch {
            self.error = "Could not change stock: \(error)"
        }
        busy = nil
        saveResults()
    }

    func exportJPEG() async {
        guard hasPhoto, busy == nil, let opened, let renderer else { return }
        error = nil
        let film = self.film, paper = self.paper, quality = exportQuality / 100
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
        guard hasPhoto, busy == nil, let opened else { return }
        error = nil
        let film = self.film, paper = self.paper, box = self.box
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
            lines.append("Film / paper: \(Stocks.name(film)) / \(Stocks.name(paper))")
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
            "Film / paper: \(Stocks.name(film)) / \(Stocks.name(paper))",
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
                               ("Export", exportLines), ("Full-resolution render", fullLines)]
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

    nonisolated private static func openAndPreview(_ url: URL, film: String, paper: String, edge: Int,
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
        let delta: [String: Any] = ["film_stock": film, "print_stock": paper,
                                    "preview_long_edge": edge, "product_defaults": true]
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
        return outcome
    }

    nonisolated private static func restock(film: String, paper: String, box: EngineBox) throws -> PreviewOutcome {
        guard let engine = box.engine else { throw Engine.Failure(description: "the engine is not running") }
        try engine.setParams(["film_stock": film, "print_stock": paper])
        return try preview(engine: engine)
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
