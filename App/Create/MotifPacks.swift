import Foundation

/// A themed set of motifs, one row in the gallery.
/// Assets are named `pack-<id>-NN` in the order of the titles.
struct MotifPack: Identifiable, Sendable {
    let id: String
    let title: String
    let motifs: [Motif]

    private init(_ id: String, _ title: String, _ titles: [String]) {
        self.id = id
        self.title = title
        motifs = titles.enumerated().map { index, title in
            Motif(id: "pack-\(id)-" + String(format: "%02d", index + 1), title: title)
        }
    }

    static let all = [
        MotifPack("wildlife", String(localized: "Wilde Tiere"), [
            String(localized: "Tiger im Dschungel"),
            String(localized: "Hirsch im Morgennebel"),
            String(localized: "Uhu vor dem Vollmond"),
            String(localized: "Wolf im Winterwald"),
            String(localized: "Flamingos in der Lagune"),
            String(localized: "Elefant im Abendrot"),
            String(localized: "Pfau im Garten"),
            String(localized: "Tukan im Regenwald"),
            String(localized: "Schneeleopard im Himalaya"),
            String(localized: "Eisvogel am Fluss"),
        ]),
        MotifPack("botanical", String(localized: "Botanik"), [
            String(localized: "Paradiesvogelblumen"),
            String(localized: "Pfingstrosen"),
            String(localized: "Wildblumenwiese"),
            String(localized: "Kakteen und Sukkulenten"),
            String(localized: "Gewächshaus"),
            String(localized: "Protea-Strauß"),
            String(localized: "Seerosenteich"),
            String(localized: "Sonnenblumenfeld"),
            String(localized: "Zimmerpflanzenregal"),
        ]),
        MotifPack("travel", String(localized: "Fernweh"), [
            String(localized: "Küstendorf im Abendlicht"),
            String(localized: "Hütte am Bergsee"),
            String(localized: "Kanal in der Lagunenstadt"),
            String(localized: "Wüstenhighway"),
            String(localized: "Tropischer Strand"),
            String(localized: "Fischerhütten am Fjord"),
            String(localized: "Lavendelfelder"),
            String(localized: "Weißes Inseldorf"),
            String(localized: "Herbstgarten mit Pagode"),
        ]),
        MotifPack("japan", String(localized: "Japan"), [
            String(localized: "Vulkan zur Kirschblüte"),
            String(localized: "Koi-Teich"),
            String(localized: "Kraniche im Flug"),
            String(localized: "Torii im Abendrot"),
            String(localized: "Pagode im Herbstlaub"),
            String(localized: "Große Welle"),
            String(localized: "Bambushain"),
            String(localized: "Teehaus im Garten"),
        ]),
        MotifPack("mystic", String(localized: "Mystik & Mond"), [
            String(localized: "Mondspinner und Kristalle"),
            String(localized: "Mondphasen über dem See"),
            String(localized: "Sonne und Mond"),
            String(localized: "Rabe im Vollmond"),
            String(localized: "Stern über dem Seerosenteich"),
            String(localized: "Kristalle im Mondlicht"),
        ]),
        MotifPack("tattoo", String(localized: "Old-School-Tattoo"), [
            String(localized: "Schwalbe mit Rosen"),
            String(localized: "Anker mit Tau"),
            String(localized: "Dreimaster auf hoher See"),
            String(localized: "Schwarzer Panther"),
            String(localized: "Schlange und Rose"),
        ]),
        MotifPack("ocean", String(localized: "Unterwasserwelt"), [
            String(localized: "Meeresschildkröte am Riff"),
            String(localized: "Quallenschwarm"),
            String(localized: "Buckelwal mit Kalb"),
            String(localized: "Oktopus am Meeresgrund"),
            String(localized: "Seepferdchen im Seegras"),
            String(localized: "Versunkenes Schiffswrack"),
        ]),
        MotifPack("space", String(localized: "Retro-Weltraum"), [
            String(localized: "Rakete vor dem Ringplaneten"),
            String(localized: "Raketenstart"),
            String(localized: "Astronaut auf dem Mond"),
            String(localized: "Raumstation im Orbit"),
        ]),
        MotifPack("planes", String(localized: "Flugzeuge"), [
            String(localized: "Propellerliner im Abendrot"),
            String(localized: "Wasserflugzeug in der Lagune"),
            String(localized: "Jet beim Abheben"),
        ]),
        MotifPack("dinos", String(localized: "Dinos & Drachen"), [
            String(localized: "Kleiner T-Rex im Dschungel"),
            String(localized: "Triceratops-Familie"),
            String(localized: "Langhals am See"),
            String(localized: "Flugsaurier über dem Vulkan"),
            String(localized: "Stegosaurus im Abendrot"),
            String(localized: "Dino-Baby schlüpft"),
            String(localized: "Drache auf dem Burgturm"),
            String(localized: "Einhorn unterm Regenbogen"),
        ]),
    ]
}
