import Foundation
import Testing

/// Keep in step with the String Catalogs, fastlane/metadata and the Screenshots workflow.
private let languages = ["de", "en", "fr", "es", "it", "ja", "ko", "nl", "pt-BR"]

struct LocalizationTests {
    @Test func everyLanguageShips() {
        let shipped = Set(Bundle.main.localizations)
        for language in languages { #expect(shipped.contains(language), "\(language) missing") }
    }

    @Test(arguments: languages.filter { $0 != "de" })
    func keyTextsAreTranslated(_ language: String) throws {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        for key in ["Los geht's", "Zum Ausprobieren", "Neues Bild", "Deine Bilder"] {
            #expect(bundle.localizedString(forKey: key, value: nil, table: nil) != key, "\(language): \(key)")
        }
    }
}
