import Foundation
import Testing
import PaintEngine
@testable import Malen

@MainActor struct ArtworkStoreTests {
    let dir = FileManager.default.temporaryDirectory.appending(path: "ui-store-\(UUID().uuidString)")

    static let template = Template(
        width: 4, height: 2, palette: [PaletteColor(r: 255, g: 0, b: 0), PaletteColor(r: 0, g: 0, b: 255)],
        colorOfPixel: [0, 0, 1, 1, 0, 0, 1, 1], fieldOfPixel: [0, 0, 1, 1, 0, 0, 1, 1],
        colorOfField: [0, 1], sizeOfField: [4, 4],
        spots: [NumberSpot(x: 0, y: 0, radius: 1, field: 0), NumberSpot(x: 2, y: 0, radius: 1, field: 1)])

    @Test func saveAndReloadRoundTrip() async throws {
        let store = ArtworkStore(directory: dir)
        let meta = try store.create(template: Self.template, title: "Fuchs", options: TemplateOptions(colors: 8), thumbnail: Data([1, 2]))
        store.save(meta.id, paint: Data([9, 9, 9]), thumbnail: Data([3]), progress: 0.4)

        let reopened = ArtworkStore(directory: dir)
        let loaded = try #require(reopened.artworks.first)
        #expect(reopened.artworks.count == 1)
        #expect(loaded.title == "Fuchs")
        #expect(loaded.progress == 0.4)
        #expect(loaded.options.colors == 8)
        #expect(reopened.paintData(meta.id) == Data([9, 9, 9]))
        let template = try await reopened.loadTemplate(meta.id)
        #expect(template.colorOfPixel == Self.template.colorOfPixel)
        #expect(template.palette == Self.template.palette)
    }

    @Test func emptyPaintDataNeverOverwritesSavedPaint() throws {
        let store = ArtworkStore(directory: dir)
        let meta = try store.create(template: Self.template, title: "A", options: TemplateOptions(), thumbnail: nil)
        store.save(meta.id, paint: Data([7]), thumbnail: nil, progress: 0.1)
        store.save(meta.id, paint: Data(), thumbnail: nil, progress: 0.1)
        #expect(store.paintData(meta.id) == Data([7]))
    }

    @Test func paintColorsFollowThePaint() throws {
        let store = ArtworkStore(directory: dir)
        let meta = try store.create(template: Self.template, title: "A", options: TemplateOptions(), thumbnail: nil)
        store.save(meta.id, paint: Data([7]), colors: Data([5, 5]), thumbnail: nil, progress: 0.1)
        #expect(store.paintColorData(meta.id) == Data([5, 5]))
        store.save(meta.id, paint: Data(), colors: nil, thumbnail: nil, progress: 0.1)   // failed export keeps both
        #expect(store.paintColorData(meta.id) == Data([5, 5]))
        store.save(meta.id, paint: Data([8]), colors: nil, thumbnail: nil, progress: 0.2)
        #expect(store.paintColorData(meta.id) == nil)
        store.save(meta.id, paint: Data([9]), colors: Data([6]), thumbnail: nil, progress: 0.3)
        store.restart(meta.id, thumbnail: nil)
        #expect(store.paintColorData(meta.id) == nil)
    }

    @Test func brokenFoldersAreSkipped() throws {
        let store = ArtworkStore(directory: dir)
        let good = try store.create(template: Self.template, title: "Gut", options: TemplateOptions(), thumbnail: nil)
        let fm = FileManager.default
        // Garbage meta.json
        let garbage = dir.appending(path: UUID().uuidString)
        try fm.createDirectory(at: garbage, withIntermediateDirectories: true)
        try Data("kaputt".utf8).write(to: garbage.appending(path: "meta.json"))
        try Data([0]).write(to: garbage.appending(path: "template.bin"))
        // Valid meta, but template.bin missing
        let orphan = try store.create(template: Self.template, title: "Ohne Vorlage", options: TemplateOptions(), thumbnail: nil)
        try fm.removeItem(at: store.folder(orphan.id).appending(path: "template.bin"))
        // Stray file in the root
        try Data("x".utf8).write(to: dir.appending(path: ".DS_Store"))

        let reopened = ArtworkStore(directory: dir)
        #expect(reopened.artworks.map(\.id) == [good.id])
    }

    @Test func renameRestartDelete() throws {
        let store = ArtworkStore(directory: dir)
        let meta = try store.create(template: Self.template, title: "Alt", options: TemplateOptions(), thumbnail: nil)
        store.save(meta.id, paint: Data([1]), thumbnail: nil, progress: 1)
        store.rename(meta.id, to: "  Neu ")
        store.restart(meta.id, thumbnail: nil)
        let reopened = ArtworkStore(directory: dir)
        #expect(reopened.artworks.first?.title == "Neu")
        #expect(reopened.artworks.first?.progress == 0)
        #expect(reopened.paintData(meta.id) == nil)
        reopened.delete(meta.id)
        #expect(ArtworkStore(directory: dir).artworks.isEmpty)
    }
}
