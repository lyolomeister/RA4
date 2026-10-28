//  Engine.swift — the C ABI in `spk_engine.h`, wrapped for the probe.
//
//  The same calls the Mac app's `EngineClient` makes, in the same order:
//  `spk_engine_create` with the app's own `MTLDevice`, `spk_open_device` (or
//  `spk_open` when the frame is too large for one Metal buffer), then
//  `spk_reprint` per tier. Not thread-safe: every call goes through the
//  probe's one serial engine queue.

import Foundation
import Metal

final class Engine: @unchecked Sendable {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// One rendered tier. `texture` owns the pixels `rgba16` points into, so
    /// the struct must be kept alive while `rgba16` is read.
    struct Rendered {
        let texture: MTLTexture
        let rgba16: UnsafePointer<UInt16>
        let width: Int
        let height: Int
        let rowStridePx: Int
        let engineMs: Double
    }

    let device: MTLDevice
    let resources: URL
    private var engine: OpaquePointer?
    private var session: OpaquePointer?
    /// The `capabilities` reply, for the header line (GPU, math mode, core).
    let capabilities: [String: Any]

    init(device: MTLDevice) throws {
        self.device = device
        guard let resources = Bundle.main.url(forResource: "engine", withExtension: nil),
              FileManager.default.fileExists(atPath: resources.appending(path: "spektrafilm_constants.bin").path)
        else {
            throw Failure(description: "the engine's resources are missing from the app; run engine/build-ios.sh bundle")
        }
        self.resources = resources
        guard let handle = resources.path.withCString({ path in
            spk_engine_create(path, Unmanaged.passUnretained(device).toOpaque())
        }) else {
            throw Failure(description: String(cString: spk_last_error(nil)))
        }
        engine = handle
        capabilities = Engine.object(String(cString: spk_capabilities(handle)))
    }

    deinit {
        if let session { spk_session_release(session) }
        if let engine { spk_engine_destroy(engine) }
    }

    private func lastError() -> String {
        guard let engine else { return "the engine is not running" }
        let message = String(cString: spk_last_error(engine))
        return message.isEmpty ? "unknown engine error" : message
    }

    private static func object(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    private static func json(_ value: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Takes ownership of an engine-allocated reply and parses it.
    private func reply(_ pointer: UnsafeMutablePointer<CChar>?) -> [String: Any] {
        guard let pointer else { return [:] }
        defer { spk_string_free(pointer) }
        return Engine.object(String(cString: pointer))
    }

    private func replaceSession(_ handle: OpaquePointer?) {
        if let session { spk_session_release(session) }
        session = handle
    }

    /// Opens a frame whose float32 RGBA pixels are in `buffer` (on `device`).
    /// The engine borrows the buffer for this call only.
    @discardableResult
    func open(buffer: MTLBuffer, width: Int, height: Int, delta: [String: Any]) throws -> [String: Any] {
        replaceSession(nil)
        var image = spk_device_image(buffer: Unmanaged.passUnretained(buffer).toOpaque(),
                                     width: UInt32(width), height: UInt32(height), channels: 4)
        var out: UnsafeMutablePointer<CChar>?
        let handle: OpaquePointer? = Engine.json(delta).withCString { deltaPtr in
            withUnsafePointer(to: &image) { spk_open_device(engine, $0, deltaPtr, &out) }
        }
        guard let handle else { throw Failure(description: lastError()) }
        session = handle
        return reply(out)
    }

    /// The same, from host memory: the engine copies the pixels into its own
    /// buffer. Used when one Metal buffer cannot hold the whole frame.
    @discardableResult
    func open(host: UnsafePointer<Float>, width: Int, height: Int, delta: [String: Any]) throws -> [String: Any] {
        replaceSession(nil)
        var image = spk_image(data: host, width: UInt32(width), height: UInt32(height), channels: 4)
        var out: UnsafeMutablePointer<CChar>?
        let handle: OpaquePointer? = Engine.json(delta).withCString { deltaPtr in
            withUnsafePointer(to: &image) { spk_open(engine, $0, deltaPtr, &out) }
        }
        guard let handle else { throw Failure(description: lastError()) }
        session = handle
        return reply(out)
    }

    func setParams(_ delta: [String: Any]) throws {
        guard let session else { throw Failure(description: "no photo is open") }
        var out: UnsafeMutablePointer<CChar>?
        guard Engine.json(delta).withCString({ spk_set_params(session, $0, &out) }) == SPK_OK else {
            throw Failure(description: lastError())
        }
        _ = reply(out)
    }

    /// `spk_reprint`: the tier from the cached negative when it can, the whole
    /// film side when it must — what the Mac app calls for every render.
    func render(tier: String) throws -> Rendered {
        guard let session else { throw Failure(description: "no photo is open") }
        var result = spk_result()
        let status = tier.withCString { spk_reprint(session, $0, &result) }
        guard status == SPK_OK, let raw = result.texture, let pixels = result.rgba16 else {
            throw Failure(description: lastError())
        }
        // +1, per spk_engine.h: ARC owns the texture (and its pixels) from here.
        let texture = Unmanaged<MTLTexture>.fromOpaque(raw).takeRetainedValue()
        return Rendered(texture: texture, rgba16: pixels,
                        width: Int(result.width), height: Int(result.height),
                        rowStridePx: Int(result.row_stride_px), engineMs: result.elapsed_ms)
    }

    /// `spk_memory_report`, parsed: what the engine itself holds.
    func memoryReport() -> [String: Any] {
        guard let engine else { return [:] }
        return Engine.object(String(cString: spk_memory_report(engine)))
    }

    static var buildInfo: String { String(cString: spk_build_info()) }
}
