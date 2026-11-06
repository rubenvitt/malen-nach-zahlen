// Public API of the engine, fixed by docs/superpowers/specs/2026-11-06-malen-design.md §4.1.
import Foundation

public struct PaletteColor: Codable, Hashable, Sendable {
    public var r: UInt8, g: UInt8, b: UInt8
    public init(r: UInt8, g: UInt8, b: UInt8) { self.r = r; self.g = g; self.b = b }
}

public struct NumberSpot: Codable, Hashable, Sendable {
    public var x: Int, y: Int
    /// Distance in grid pixels from the centre of pixel (x, y) to the field border.
    public var radius: Float
    public var field: Int32
    public init(x: Int, y: Int, radius: Float, field: Int32) {
        self.x = x; self.y = y; self.radius = radius; self.field = field
    }
}

public struct TemplateOptions: Codable, Hashable, Sendable {
    public var colors: Int
    public var detail: Double
    public var maxSide: Int
    public init(colors: Int = 12, detail: Double = 0.5, maxSide: Int = 1000) {
        self.colors = colors; self.detail = detail; self.maxSide = maxSide
    }
}

public struct Template: Codable, Sendable, Equatable {
    public let width: Int, height: Int
    public let palette: [PaletteColor]
    public let colorOfPixel: [UInt8]
    public let fieldOfPixel: [Int32]
    public let colorOfField: [UInt8]
    public let sizeOfField: [Int32]
    public let spots: [NumberSpot]

    public init(width: Int, height: Int, palette: [PaletteColor], colorOfPixel: [UInt8],
                fieldOfPixel: [Int32], colorOfField: [UInt8], sizeOfField: [Int32], spots: [NumberSpot]) {
        self.width = width; self.height = height; self.palette = palette
        self.colorOfPixel = colorOfPixel; self.fieldOfPixel = fieldOfPixel
        self.colorOfField = colorOfField; self.sizeOfField = sizeOfField; self.spots = spots
    }

    /// Derives fields (4-connected, ids in scan order), their sizes and number spots from the colours.
    public init(width: Int, height: Int, palette: [PaletteColor], colorOfPixel: [UInt8]) {
        precondition(width > 0 && height > 0 && colorOfPixel.count == width * height)
        let f = Fields(colorOfPixel, width, height)
        self.init(width: width, height: height, palette: palette, colorOfPixel: colorOfPixel,
                  fieldOfPixel: f.fieldOfPixel, colorOfField: f.colorOfField,
                  sizeOfField: f.sizeOfField, spots: f.spots)
    }

    // MARK: Compact coding: only size, palette and colours are stored, the rest is derived on decode.

    private enum CodingKeys: String, CodingKey { case version, width, height, palette, colorOfPixel }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(1, forKey: .version)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(Data(palette.flatMap { [$0.r, $0.g, $0.b] }), forKey: .palette)
        try c.encode(Data(colorOfPixel), forKey: .colorOfPixel)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func corrupt(_ key: CodingKeys, _ why: String) -> DecodingError {
            .dataCorruptedError(forKey: key, in: c, debugDescription: why)
        }
        guard try c.decode(Int.self, forKey: .version) == 1 else { throw corrupt(.version, "unsupported version") }
        let w = try c.decode(Int.self, forKey: .width), h = try c.decode(Int.self, forKey: .height)
        guard (1...1 << 15).contains(w), (1...1 << 15).contains(h) else { throw corrupt(.width, "bad size") }
        let rgb = [UInt8](try c.decode(Data.self, forKey: .palette))
        guard !rgb.isEmpty, rgb.count % 3 == 0, rgb.count <= 256 * 3 else { throw corrupt(.palette, "bad palette") }
        let pixels = [UInt8](try c.decode(Data.self, forKey: .colorOfPixel))
        guard pixels.count == w * h, Int(pixels.max() ?? 0) < rgb.count / 3 else {
            throw corrupt(.colorOfPixel, "pixels do not match size or palette")
        }
        let palette = stride(from: 0, to: rgb.count, by: 3).map { PaletteColor(r: rgb[$0], g: rgb[$0 + 1], b: rgb[$0 + 2]) }
        self.init(width: w, height: h, palette: palette, colorOfPixel: pixels)
    }

    /// Binary property list, about width*height bytes.
    public func encoded() throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(self)
    }

    /// Inverse of `encoded()`; throws on corrupt data instead of crashing.
    public init(decoding data: Data) throws {
        self = try PropertyListDecoder().decode(Template.self, from: data)
    }
}

public enum TemplateBuilderError: Error, Equatable {
    /// width/height not positive or rgba shorter than width*height*4.
    case invalidImage
}

public enum TemplateBuilder {
    /// rgba: width*height*4, premultiplied irrelevant (opaque, alpha ignored).
    /// Downscales internally to options.maxSide. Checks Task cancellation regularly
    /// and throws CancellationError, so a live preview can drop stale work.
    public static func build(rgba: [UInt8], width: Int, height: Int, options: TemplateOptions) throws -> Template {
        try build(rgba: rgba, width: width, height: height, options: options, minArea: nil)
    }
}
