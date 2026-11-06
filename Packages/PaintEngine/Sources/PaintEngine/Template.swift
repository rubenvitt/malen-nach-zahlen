// Public API of the engine, fixed by docs/superpowers/specs/2026-11-06-malen-design.md §4.1.

public struct PaletteColor: Codable, Hashable, Sendable {
    public var r: UInt8, g: UInt8, b: UInt8
    public init(r: UInt8, g: UInt8, b: UInt8) { self.r = r; self.g = g; self.b = b }
}

public struct NumberSpot: Codable, Hashable, Sendable {
    public var x: Int, y: Int
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

public struct Template: Codable, Sendable {
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
}

public enum TemplateBuilder {
    // Stub until the engine port lands: two vertical halves, enough for UI work.
    public static func build(rgba: [UInt8], width: Int, height: Int, options: TemplateOptions) throws -> Template {
        try Task.checkCancellation()
        let w = min(width, options.maxSide), h = max(1, height * w / max(width, 1))
        var color = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in w / 2..<w { color[y * w + x] = 1 } }
        let field = color.map { Int32($0) }
        let half = Int32(w / 2 * h)
        return Template(width: w, height: h,
                        palette: [PaletteColor(r: 240, g: 120, b: 80), PaletteColor(r: 70, g: 130, b: 220)],
                        colorOfPixel: color, fieldOfPixel: field, colorOfField: [0, 1],
                        sizeOfField: [half, Int32(w * h) - half],
                        spots: [NumberSpot(x: w / 4, y: h / 2, radius: Float(w / 4), field: 0),
                                NumberSpot(x: 3 * w / 4, y: h / 2, radius: Float(w / 4), field: 1)])
    }
}
