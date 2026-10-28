//  Library.swift — the photos, each one's saved edits, and the filmstrip's thumbnails.
//
//  The library is the app's Documents folder: what Files shows as On My iPad ›
//  SpektraProbe, and what Finder shows under the iPad's Files tab. Importing
//  (from Files or from Photos) copies a photo in; Exports is a folder of its
//  own and is not part of the library.
//
//  Edits live in a store of the app's own, never in the photo (the Mac app's
//  `Model/Sidecar.swift` rule): Application Support/Sidecars, one small JSON
//  per photo, keyed by its name in the library and rewritten whole on every
//  save. A renamed photo is recognised the Mac's way — same volume, inode and
//  size — and **content is deliberately not a way of recognising a photo**:
//  a byte-identical copy is a different photograph and starts with no edits.

import CoreTransferable
import CryptoKit
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

struct LibraryPhoto: Identifiable, Hashable {
    /// The file's name in the library, which is also its identity.
    let name: String
    var id: String { name }
    var url: URL { Library.folder.appending(path: name) }
}

enum Library {
    static var folder: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    /// Every photo at the top of the library, in name order (camera numbering).
    static func photos() -> [LibraryPhoto] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentTypeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles])) ?? []
        return urls.filter { url in
            let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let type = values?.contentType else { return false }
            return type.conforms(to: .image)
        }
        .map { LibraryPhoto(name: $0.lastPathComponent) }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// `name`, or `name 2`, `name 3`… so an import never replaces a photo.
    static func freshURL(for name: String) -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var url = folder.appending(path: name)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appending(path: ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }

    /// Copies a file chosen in Files into the library.
    static func importCopy(of source: URL) throws -> LibraryPhoto {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let destination = freshURL(for: source.lastPathComponent)
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [.withoutChanges],
                                       error: &coordinationError) { readable in
            do { try FileManager.default.copyItem(at: readable, to: destination) } catch { copyError = error }
        }
        if let failure = coordinationError ?? copyError { throw failure }
        let photo = LibraryPhoto(name: destination.lastPathComponent)
        SidecarStore.dropIfStale(for: photo)
        return photo
    }

    /// Takes a file Photos handed over (valid only while it is being handed).
    static func adopt(_ received: URL) throws -> LibraryPhoto {
        let destination = freshURL(for: received.lastPathComponent)
        try FileManager.default.copyItem(at: received, to: destination)
        let photo = LibraryPhoto(name: destination.lastPathComponent)
        SidecarStore.dropIfStale(for: photo)
        return photo
    }

    /// Removes a photo, its saved edits and its thumbnail.
    static func remove(_ photo: LibraryPhoto) throws {
        try FileManager.default.removeItem(at: photo.url)
        SidecarStore.forget(photo)
    }
}

/// A photo from the Photos app, as its original file: the RAW when the asset
/// has one, otherwise the image.
struct PickedPhoto: Transferable {
    let photo: LibraryPhoto
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .rawImage) { PickedPhoto(photo: try Library.adopt($0.file)) }
        FileRepresentation(importedContentType: .image) { PickedPhoto(photo: try Library.adopt($0.file)) }
    }
}

/// One photo's edits: the engine's settings (Layer 1), the adjustments
/// (Layer 2), the crop and the camera decode. Not the Mac's sidecar format —
/// this build has a subset of it. Version 2 added `geometry` and `camera`; a
/// version 1 file reads with no crop and the camera's own white balance.
struct Sidecar: Codable {
    var version = 2
    var file: String
    var source: Source
    var settings: FilmSettings
    var adjustments: Adjustments
    var geometry = Geometry()
    var camera = CameraDecode()
    var savedAt: Date

    /// The Mac's `Sidecar.Source`: the photo as the file system knows it. The
    /// digest is recorded, so the store is diagnosable; nothing matches on it.
    struct Source: Codable, Equatable {
        var volumeID: Int?
        var inode: Int?
        var size: Int?
        var headDigest: String?

        func matches(_ other: Source) -> Bool {
            guard let a = inode, let b = other.inode, a == b,
                  let va = volumeID, let vb = other.volumeID, va == vb,
                  let sa = size, let sb = other.size, sa == sb else { return false }
            return true
        }

        /// Whether two records can be the same photograph's: a size or a
        /// first 64 KB that differ say they are not. Not the inode, which a
        /// backup restored to a new iPad changes for every file. A record
        /// that lacks a field (an older build's) cannot rule anything out.
        func couldBeSamePhoto(as other: Source) -> Bool {
            if let a = size, let b = other.size, a != b { return false }
            if let a = headDigest, let b = other.headDigest, a != b { return false }
            return true
        }

        static func of(_ url: URL) -> Source {
            var source = Source()
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
                source.inode = (attrs[.systemFileNumber] as? NSNumber)?.intValue
                source.volumeID = (attrs[.systemNumber] as? NSNumber)?.intValue
                source.size = (attrs[.size] as? NSNumber)?.intValue
            }
            if let handle = try? FileHandle(forReadingFrom: url) {
                defer { try? handle.close() }
                if let head = try? handle.read(upToCount: 64 * 1024) {
                    source.headDigest = SHA256.hash(data: head).map { String(format: "%02x", $0) }.joined()
                }
            }
            return source
        }
    }
}

enum SidecarStore {
    static var folder: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Sidecars", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The store's key for a name: the first 16 hex digits of its SHA-256.
    static func key(_ name: String) -> String {
        SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    static func url(for photo: LibraryPhoto) -> URL { folder.appending(path: key(photo.name) + ".json") }

    /// The photo's saved edits: by its name, else — for a renamed photo — the
    /// edits of a photo that no longer exists and is the same file.
    static func load(for photo: LibraryPhoto) -> Sidecar? {
        let here = Sidecar.Source.of(photo.url)
        if let saved = read(url(for: photo)) {
            if saved.source.couldBeSamePhoto(as: here) { return saved }
            forget(photo)
        }
        guard here.inode != nil, let files = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil) else { return nil }
        for file in files where file.pathExtension == "json" {
            guard var orphan = read(file), orphan.source.matches(here),
                  !FileManager.default.fileExists(atPath: Library.folder.appending(path: orphan.file).path)
            else { continue }
            // Adopt it under the new name, so the next lookup is the cheap one.
            orphan.file = photo.name
            try? FileManager.default.removeItem(at: file)
            write(orphan, to: url(for: photo))
            Thumbnails.move(from: (file.lastPathComponent as NSString).deletingPathExtension, to: key(photo.name))
            return orphan
        }
        return nil
    }

    static func save(settings: FilmSettings, adjustments: Adjustments, geometry: Geometry,
                     camera: CameraDecode, for photo: LibraryPhoto) {
        let sidecar = Sidecar(file: photo.name, source: .of(photo.url), settings: settings,
                              adjustments: adjustments, geometry: geometry, camera: camera, savedAt: Date())
        write(sidecar, to: url(for: photo))
    }

    static func forget(_ photo: LibraryPhoto) {
        try? FileManager.default.removeItem(at: url(for: photo))
        Thumbnails.forget(photo)
    }

    /// A name is the store's key, so a photo that arrives under a name an
    /// earlier one had — deleted in Files rather than here, with the camera's
    /// numbering since come round again — would open with that photo's crop
    /// and film. Its edits and thumbnail are dropped when the file under the
    /// name is plainly another photograph.
    static func dropIfStale(for photo: LibraryPhoto) {
        guard let saved = read(url(for: photo)),
              !saved.source.couldBeSamePhoto(as: .of(photo.url)) else { return }
        forget(photo)
    }

    /// Whether the photo has edits of its own — the filmstrip's dot.
    static func isEdited(_ photo: LibraryPhoto) -> Bool {
        guard let saved = read(url(for: photo)) else { return false }
        // The film format's length follows the photo's own shape (36.3 mm for
        // a 3:2.02 M10-R frame), so it is not an edit; the frame, side and
        // side length that set it are compared.
        var settings = saved.settings
        settings.filmFormatMM = FilmSettings().filmFormatMM
        return settings != FilmSettings() || !saved.adjustments.isNeutral
            || !saved.geometry.isIdentity || !saved.camera.isNeutral
    }

    private static func write(_ sidecar: Sidecar, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(sidecar) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Read leniently: a field this build does not know is ignored, and one a
    /// newer field list expects but the file lacks takes its default, so a
    /// sidecar written by an older build still opens.
    private static func read(_ url: URL) -> Sidecar? {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let file = stored["file"] as? String else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let source = (try? decoder.decode(Sidecar.Source.self,
                                          from: JSONSerialization.data(withJSONObject: stored["source"] ?? [:])))
            ?? Sidecar.Source()
        // Geometry and camera decode their own missing fields (their
        // `init(from:)`), so they are read directly rather than merged —
        // `merged` would drop `intendedSize`, which a default lacks.
        func direct<T: Decodable>(_ key: String, _ fallback: T) -> T {
            guard let value = stored[key], let data = try? JSONSerialization.data(withJSONObject: value)
            else { return fallback }
            return (try? decoder.decode(T.self, from: data)) ?? fallback
        }
        return Sidecar(file: file, source: source,
                       settings: merged(FilmSettings(), with: stored["settings"]),
                       adjustments: merged(Adjustments(), with: stored["adjustments"]),
                       geometry: direct("geometry", Geometry()),
                       camera: direct("camera", CameraDecode()),
                       savedAt: (stored["savedAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? .distantPast)
    }

    /// `value` with every key `stored` has laid over it, nested objects included.
    private static func merged<T: Codable>(_ value: T, with stored: Any?) -> T {
        guard let stored = stored as? [String: Any],
              let base = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(value))) as? [String: Any]
        else { return value }
        func merge(_ a: [String: Any], _ b: [String: Any]) -> [String: Any] {
            var out = a
            for (key, new) in b {
                if let old = a[key] as? [String: Any], let newer = new as? [String: Any] {
                    out[key] = merge(old, newer)
                } else if a[key] != nil {
                    out[key] = new
                }
            }
            return out
        }
        guard let data = try? JSONSerialization.data(withJSONObject: merge(base, stored)),
              let decoded = try? JSONDecoder().decode(T.self, from: data) else { return value }
        return decoded
    }
}

/// The filmstrip's pictures: the developed print once a photo has been
/// edited (Caches/Thumbnails), and the camera's own embedded preview before.
enum Thumbnails {
    static let longEdge = 360

    static var folder: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "Thumbnails", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func url(for photo: LibraryPhoto) -> URL { folder.appending(path: SidecarStore.key(photo.name) + ".jpg") }

    static func load(for photo: LibraryPhoto) -> UIImage? {
        if let cached = UIImage(contentsOfFile: url(for: photo).path) { return cached }
        guard let source = CGImageSourceCreateWithURL(photo.url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: longEdge,
              ] as CFDictionary)
        else { return nil }
        return UIImage(cgImage: image)
    }

    /// Stores a print thumbnail (already small, in its own colour space).
    static func store(_ image: CGImage, for photo: LibraryPhoto) {
        guard let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.85) else { return }
        try? data.write(to: url(for: photo), options: .atomic)
    }

    static func forget(_ photo: LibraryPhoto) { try? FileManager.default.removeItem(at: url(for: photo)) }

    fileprivate static func move(from oldKey: String, to newKey: String) {
        let from = folder.appending(path: oldKey + ".jpg"), to = folder.appending(path: newKey + ".jpg")
        try? FileManager.default.removeItem(at: to)
        try? FileManager.default.moveItem(at: from, to: to)
    }

    /// `image` scaled so its long edge is `longEdge`, keeping its colour space.
    static func downscaled(_ image: CGImage) -> CGImage? {
        let scale = Double(longEdge) / Double(max(image.width, image.height))
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        guard let space = image.colorSpace,
              let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }
}

// MARK: - favourites, order and sorting

/// How the library is ordered. `custom` is the order a person dragged.
enum LibrarySort: String, Codable, CaseIterable, Identifiable, Sendable {
    case name, date, favorites, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: String(localized: "Name")
        case .date: String(localized: "Date taken")
        case .favorites: String(localized: "Favourites first")
        case .custom: String(localized: "Custom order")
        }
    }
}

/// The library's own facts, beside the photos: the favourites, the order a
/// person dragged, how it is sorted, and each photo's capture date (read once
/// from the file and kept). Keyed by the photo's name in the library, as the
/// sidecars are. Application Support/Library.json, read leniently.
struct LibraryIndex: Codable, Equatable, Sendable {
    var sort = LibrarySort.name
    var favorites: Set<String> = []
    var order: [String] = []
    var dates: [String: Date] = [:]

    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "Library.json")
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sort = (try? c.decodeIfPresent(LibrarySort.self, forKey: .sort)) ?? .name
        favorites = (try? c.decodeIfPresent(Set<String>.self, forKey: .favorites)) ?? []
        order = (try? c.decodeIfPresent([String].self, forKey: .order)) ?? []
        dates = (try? c.decodeIfPresent([String: Date].self, forKey: .dates)) ?? [:]
    }

    static func load() -> LibraryIndex {
        guard let data = try? Data(contentsOf: url) else { return LibraryIndex() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(LibraryIndex.self, from: data)) ?? LibraryIndex()
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }

    /// Forgets the photos that are no longer in the library.
    mutating func prune(keeping names: Set<String>) {
        favorites.formIntersection(names)
        order.removeAll { !names.contains($0) }
        dates = dates.filter { names.contains($0.key) }
    }

    /// The photos in this index's order:
    /// - name: as Files sorts them (camera numbering);
    /// - date taken: oldest first, as a roll was shot; a photo without a date last;
    /// - favourites first: the favourites, then the rest, each by name;
    /// - custom: the dragged order, with photos added since at the end by name.
    func arranged(_ photos: [LibraryPhoto]) -> [LibraryPhoto] {
        let byName = photos.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        switch sort {
        case .name:
            return byName
        case .date:
            return byName.enumerated().sorted { a, b in
                switch (dates[a.element.name], dates[b.element.name]) {
                case let (x?, y?) where x != y: return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.offset < b.offset
                }
            }.map(\.element)
        case .favorites:
            return byName.filter { favorites.contains($0.name) } + byName.filter { !favorites.contains($0.name) }
        case .custom:
            let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            return byName.enumerated().sorted { a, b in
                switch (rank[a.element.name], rank[b.element.name]) {
                case let (x?, y?): return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.offset < b.offset
                }
            }.map(\.element)
        }
    }
}

extension Library {
    /// When the photo was taken: the camera's own clock (EXIF
    /// DateTimeOriginal, read as written, no time zone), else the file's date.
    static func captureDate(of url: URL) -> Date? {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let raw = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let parse = DateFormatter()
            parse.locale = Locale(identifier: "en_US_POSIX")
            parse.timeZone = TimeZone(secondsFromGMT: 0)
            parse.dateFormat = "yyyy:MM:dd HH:mm:ss"
            if let date = parse.date(from: raw) { return date }
        }
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate
    }
}
