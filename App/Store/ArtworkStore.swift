import Foundation
import UIKit
import Observation
import PaintEngine

struct ArtworkMeta: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var title: String
    var created: Date
    var modified: Date
    var progress: Double
    var options: TemplateOptions

    var isComplete: Bool { progress >= 1 }
}

/// One folder per artwork: `<root>/<uuid>/{template.bin, paint.png, thumb.jpg, meta.json}`.
/// While some paint has a wrong colour (overpaint protection off), `paint.png` carries the paint
/// colours as a trailer, so both always change together.
/// `meta.json` is written last, so a folder without it (crash mid-create) is simply skipped.
@MainActor @Observable final class ArtworkStore {
    let directory: URL
    private(set) var artworks: [ArtworkMeta] = []
    @ObservationIgnored private let thumbCache = NSCache<NSString, UIImage>()

    init(directory: URL) {
        self.directory = directory
        reload()
    }

    static func applicationSupport() -> ArtworkStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ArtworkStore(directory: base.appending(path: "Artworks", directoryHint: .isDirectory))
    }

    func reload() {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let folders = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        artworks = folders.compactMap { folder -> ArtworkMeta? in
            guard fm.fileExists(atPath: folder.appending(path: "template.bin").path),
                  let data = try? Data(contentsOf: folder.appending(path: "meta.json")),
                  let meta = try? Self.decoder.decode(ArtworkMeta.self, from: data),
                  meta.id.uuidString == folder.lastPathComponent
            else { return nil }
            return meta
        }
        .sorted { $0.modified > $1.modified }
    }

    // MARK: Files

    func folder(_ id: UUID) -> URL { directory.appending(path: id.uuidString, directoryHint: .isDirectory) }

    @discardableResult
    func create(template: Template, title: String, options: TemplateOptions, thumbnail: Data?) throws -> ArtworkMeta {
        let now = Date()
        let meta = ArtworkMeta(id: UUID(), title: title, created: now, modified: now, progress: 0, options: options)
        let folder = folder(meta.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try template.encoded().write(to: folder.appending(path: "template.bin"), options: .atomic)
        if let thumbnail { try thumbnail.write(to: folder.appending(path: "thumb.jpg"), options: .atomic) }
        try writeMeta(meta)
        artworks.insert(meta, at: 0)
        return meta
    }

    /// Decodes off the main actor: the engine recomputes fields and spots while loading.
    func loadTemplate(_ id: UUID) async throws -> Template {
        let url = folder(id).appending(path: "template.bin")
        return try await Task.detached(priority: .userInitiated) {
            try Template(decoding: Data(contentsOf: url))
        }.value
    }

    func paintData(_ id: UUID) -> Data? {
        guard let data = try? Data(contentsOf: folder(id).appending(path: "paint.png")), !data.isEmpty else { return nil }
        return Self.split(data).paint
    }

    func paintColorData(_ id: UUID) -> Data? {
        guard let data = try? Data(contentsOf: folder(id).appending(path: "paint.png")) else { return nil }
        return Self.split(data).colors
    }

    /// Empty paint data or a nil thumbnail keep what is on disk — never overwrite good data with nothing.
    /// `colors` belongs to `paint`: nil means all paint has its own colour.
    func save(_ id: UUID, paint: Data, colors: Data? = nil, thumbnail: Data?, progress: Double) {
        guard var meta = artworks.first(where: { $0.id == id }) else { return }
        let folder = folder(id)
        do {
            if !paint.isEmpty {
                try Self.join(paint, colors).write(to: folder.appending(path: "paint.png"), options: .atomic)
            }
            if let thumbnail, !thumbnail.isEmpty {
                try thumbnail.write(to: folder.appending(path: "thumb.jpg"), options: .atomic)
            }
            meta.progress = progress
            meta.modified = Date()
            try writeMeta(meta)
            replace(meta)
        } catch {
            assertionFailure("Saving artwork failed: \(error)")
        }
    }

    func rename(_ id: UUID, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, var meta = artworks.first(where: { $0.id == id }) else { return }
        meta.title = title
        try? writeMeta(meta)
        replace(meta)
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: folder(id))
        artworks.removeAll { $0.id == id }
    }

    /// Wipes the paint layer; the caller passes a fresh blank-template thumbnail.
    func restart(_ id: UUID, thumbnail: Data?) {
        guard var meta = artworks.first(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: folder(id).appending(path: "paint.png"))
        if let thumbnail { try? thumbnail.write(to: folder(id).appending(path: "thumb.jpg"), options: .atomic) }
        meta.progress = 0
        meta.modified = Date()
        try? writeMeta(meta)
        replace(meta)
    }

    func thumbnail(for meta: ArtworkMeta) -> UIImage? {
        let key = "\(meta.id)-\(meta.modified.timeIntervalSince1970)" as NSString
        if let hit = thumbCache.object(forKey: key) { return hit }
        guard let image = UIImage(contentsOfFile: folder(meta.id).appending(path: "thumb.jpg").path) else { return nil }
        thumbCache.setObject(image, forKey: key)
        return image
    }

    // MARK: Helpers

    /// Paint colours ride at the end of `paint.png` (`colors`, length as UInt64 LE, magic), so paint
    /// and colours are always written together in one atomic write. Image decoders ignore bytes
    /// after the PNG end chunk, and files without the trailer simply have no colours.
    private static let colorsMagic = Data("MNZCOLv1".utf8)

    private static func join(_ paint: Data, _ colors: Data?) -> Data {
        guard let colors else { return paint }
        var out = paint
        out.append(colors)
        withUnsafeBytes(of: UInt64(colors.count).littleEndian) { out.append(contentsOf: $0) }
        out.append(colorsMagic)
        return out
    }

    private static func split(_ blob: Data) -> (paint: Data, colors: Data?) {
        let tail = colorsMagic.count + 8
        guard blob.count > tail, blob.suffix(colorsMagic.count) == colorsMagic else { return (blob, nil) }
        let lengthBytes = blob.dropLast(colorsMagic.count).suffix(8)
        let length = lengthBytes.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) }
        guard length <= UInt64(blob.count - tail) else { return (blob, nil) }
        let paintEnd = blob.count - tail - Int(length)
        let start = blob.startIndex
        return (Data(blob[start..<(start + paintEnd)]), Data(blob[(start + paintEnd)..<(start + paintEnd + Int(length))]))
    }

    private func writeMeta(_ meta: ArtworkMeta) throws {
        try Self.encoder.encode(meta).write(to: folder(meta.id).appending(path: "meta.json"), options: .atomic)
    }

    private func replace(_ meta: ArtworkMeta) {
        artworks.removeAll { $0.id == meta.id }
        artworks.append(meta)
        artworks.sort { $0.modified > $1.modified }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
