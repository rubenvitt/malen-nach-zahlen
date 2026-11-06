import Testing
@testable import PaintEngine

@Test func stubBuildsATemplate() throws {
    let t = try TemplateBuilder.build(rgba: [UInt8](repeating: 255, count: 40 * 20 * 4), width: 40, height: 20,
                                      options: TemplateOptions())
    #expect(t.colorOfPixel.count == t.width * t.height)
}
