# Malen nach Zahlen – Design

**Stand:** 6. November 2026

Eine iPad-App, die aus einem Foto eine Malvorlage macht und sie mit dem Stift
ausmalen lässt – richtig malen, nicht antippen und füllen. Die Farbe bleibt in
den Feldern, die Felder haben einen dünnen schwarzen Rand. Es muss Spaß machen.

Markierung: **(Ruben)** = von Ruben vorgegeben, **(Claude)** =
Entscheidung von Claude (Ruben hat Entscheidungen ausdrücklich freigegeben).

Vorläufer: Web-Prototyp in `prototype/web/` (`seg.js` = Referenzalgorithmus,
`app.js` = Malen mit Maske). Die native App ersetzt ihn; der Prototyp bleibt als
Referenz, bis der Swift-Port gleichwertig ist.

## 1. Ziele

- **Aktiv ausmalen (Ruben).** Mit dem Stift (Apple Pencil, auch Logitech Crayon –
  also ohne Druckstufen) wird gemalt wie mit einem Pinsel. Kein Tippen-und-Füllen.
- **Nicht übermalen (Ruben).** Farbe landet nur in Feldern mit der gewählten
  Nummer. Über den Rand und in fremde Felder malen geht nicht **(Claude: strenge
  Auslegung, wie im Prototyp)**. *Nachtrag 2026-11-07 (Ruben):* Der Übermalschutz
  ist im Spiel umschaltbar (Schild-Knopf oben, Standard an, gilt für alle Bilder).
  An heißt: Ein Strich bleibt in dem einen Feld der gewählten Nummer, in dem er
  ansetzt. Aus heißt: keine Felder, man malt frei über alles (nur fertige Felder
  bleiben gesperrt); falsche Farbe zählt nicht und muss richtig übermalt werden.
  *Nachtrag 2026-11-13 (Ruben: „Das ist für Erwachsene!“):* Übermalschutz und
  Sperre fertiger Felder sind entfallen; man malt immer frei, auch mit anderer
  Farbe über fertige Felder (die dann wieder offen sind). Nichts füllt sich von
  selbst: Ein Feld zählt als fertig, wenn höchstens ein Zehntel (bei kleinen
  Feldern ein Pixel) fehlt, bleibt aber so, wie es gemalt wurde.
- **Dünner schwarzer Rand (Ruben)** um jedes Feld, immer über der Farbe.
  *Nachtrag 2026-11-13 (Ruben):* als glatte, geschwungene Linie, nicht als
  Pixeltreppe.
- **Farbanzahl beim Erstellen einstellbar, mit Live-Vorschau (Ruben).** Schieber
  bewegen → Vorschau der Vorlage aktualisiert sich währenddessen.
- **Schöne UI, muss Spaß machen (Ruben).** Siehe §5.
- **iPad-App, über CI gebaut, öffentliche TestFlight, App-Store-fähig (Ruben).**

## 2. Nicht-Ziele (v1) **(Claude)**

- iPhone, Mac, Vision Pro. Nur iPad (`TARGETED_DEVICE_FAMILY: 2`).
- iCloud-Sync, Konto, Teilen von Vorlagen zwischen Geräten, Werbung, Abos.
  *(Nachtrag 2026-11-07: Käufe gab es kurz doch, als einmalige Vollversion; seit 2026-11-11 wieder gestrichen, siehe §9.)*
- Druckstärke, Pinsel-Texturen, Mischfarben, freie Farbwahl. Farben kommen nur
  aus der Palette der Vorlage.
- Kategorie „Kinder" im App Store (bringt zusätzliche Review-Regeln).

## 3. Anti-Ziele

Was es zum Fehlschlag macht, auch wenn es technisch läuft:

- Farbe, die über den Rand oder in ein falsches Feld läuft.
- Malen, das hinter dem Stift herhinkt oder Striche verschluckt.
- Vorschau, die beim Schieben einfriert oder nach dem Loslassen sekundenlang
  rechnet.
- Verlorenes Ausgemaltes (App beendet, Absturz, Update).
- Felder, die so winzig sind, dass man sie nicht trifft und die Nummer nicht
  lesen kann.
- Handballen auf dem Display malt oder zoomt ungewollt.
- Einstellungsseiten, Onboarding-Karussell, Popups.

## 4. Aufbau **(Claude, wie Sudoku/Rudel)**

- Repo `rubenvitt/malen-nach-zahlen`, lokal `~/dev/personal/apps/malen-nach-zahlen`.
  **Öffentlich (Claude)** wie Sudoku: Datenschutzerklärung braucht eine
  öffentliche URL für TestFlight/App Store, und macOS-Runner sind für öffentliche
  Repos kostenlos.
- `Packages/PaintEngine` – reines Swift-Package (kein UIKit/SwiftUI): Foto-Pixel →
  Vorlage. Läuft mit `swift test`.
- `App/` – SwiftUI-App, iPadOS **18.0**, Swift 6, strict concurrency complete.
  Malfläche in UIKit (`UIView`), eingebettet per `UIViewRepresentable`.
- Xcode-Projekt per **xcodegen** aus `project.yml`, nicht eingecheckt.
- Bundle-ID **`dev.rubeen.malen`**, Homescreen-Name **„Malen"**,
  App-Store-Name **„Griffel Malen nach Zahlen"** (Marke „Griffel" wie Griffel Sudoku).
- **Muss mit Xcode 26.6 bauen** (CI-Pin), lokal läuft Xcode 27 Beta – keine
  iOS-26/27-only APIs ohne `if #available`, Deployment-Target 18.0.
- Keine Fremdabhängigkeiten.

### 4.1 Engine: `PaintEngine`

Port von `prototype/web/seg.js`, verbessert:

1. **Quantisieren:** k-Means in **CIELAB** (wahrnehmungsgleich, besser als RGB),
   k-means++-Init mit festem Seed, auf ~20 000 Stichproben fitten, dann alle
   Pixel zuordnen. Gleiches Foto + gleiche Optionen = gleiche Vorlage.
2. **Glätten:** 3×3-Mehrheitsfilter, zwei Durchgänge.
3. **Kleine Felder verschmelzen** mit dem dominanten Nachbarn (große Nachbarn
   gewinnen), bis keine Felder < `minArea` mehr oder Pass-Limit.
4. **Kompaktieren:** ungenutzte Palettenfarben entfernen; Palette sortieren
   (nach Helligkeit/Farbton, damit die Farbleiste schön aussieht).
5. **Nummernplätze:** pro Feld der Pixel mit größtem Abstand zum Rand
   (Chamfer-Distanz), Radius = Platz für die Ziffer.

**API (verbindlich, damit Engine/Malfläche/UI parallel entstehen können):**

```swift
public struct PaletteColor: Codable, Hashable, Sendable { public var r, g, b: UInt8 }

public struct NumberSpot: Codable, Hashable, Sendable {
    public var x: Int, y: Int          // grid pixel
    public var radius: Float           // grid pixels of free room around (x, y)
    public var field: Int32
}

public struct TemplateOptions: Codable, Hashable, Sendable {
    public var colors: Int             // 4...30, default 12
    public var detail: Double          // 0 (grob, große Felder) ... 1 (fein), default 0.5
    public var maxSide: Int            // grid size of the longest side, default 1000
}

public struct Template: Codable, Sendable {
    public let width: Int, height: Int // grid size
    public let palette: [PaletteColor] // index = number - 1
    public let colorOfPixel: [UInt8]   // width*height, palette index per grid pixel
    public let fieldOfPixel: [Int32]   // width*height, field id per grid pixel
    public let colorOfField: [UInt8]   // per field
    public let sizeOfField: [Int32]    // per field, grid pixels
    public let spots: [NumberSpot]     // one per field
}

public enum TemplateBuilder {
    /// rgba: width*height*4, premultiplied irrelevant (opaque, alpha ignored).
    /// Downscales internally to options.maxSide. Checks Task cancellation regularly
    /// and throws CancellationError, so a live preview can drop stale work.
    public static func build(rgba: [UInt8], width: Int, height: Int,
                             options: TemplateOptions) throws -> Template
}
```

- `Template` muss **kompakt** kodieren (große Arrays als `Data`, nicht als
  JSON-Zahlenlisten): 1000×750 → < 3 MB, Laden < 150 ms. Abgeleitete Arrays
  (`fieldOfPixel`, `sizeOfField`, `spots`) dürfen beim Dekodieren neu berechnet
  werden.
- **Tempo (Release, iPad M-Klasse grob = Mac /2):** Vorschau mit `maxSide` 320 in
  < 150 ms, volle Vorlage 1000 in < 2 s.
- `detail` → `minArea` (in Gitterpixeln, relativ zur Bildfläche). Ziel: kleinste
  Felder bleiben bei voller Ansicht auf dem iPad mit dem Stift treffbar
  (≈ 12×12 Gitterpixel bei `detail` 0.5).
- Tests: Fixture aus `prototype/web/seg.test.js` (zwei Hälften + Fleck), Determinismus,
  keine Lücken in der Palette, jeder Spot liegt in seinem Feld, Kodieren/Dekodieren
  rund, Abbruch wirft `CancellationError`, Mindestfeldgröße eingehalten.

### 4.2 Malfläche: `App/Canvas/`

```swift
enum BrushSize: CaseIterable, Codable { case small, medium, large }

@MainActor @Observable final class PaintingSession {
    init(template: Template, paintLayerPNG: Data?)
    var selectedColor: Int                  // palette index
    var brush: BrushSize
    private(set) var progressByColor: [Double]   // 0...1 per palette index
    private(set) var progress: Double            // overall 0...1
    private(set) var completedColors: Set<Int>
    var isComplete: Bool { get }
    var canUndo: Bool { get }
    func undo()
    func paintLayerPNG() -> Data
    func renderFinished(showLines: Bool, maxSide: Int) -> UIImage   // Galerie-Bild, Teilen
    var onStrokeEnded: (() -> Void)?             // Autosave-Hook
    var onFieldCompleted: ((Int32) -> Void)?     // für Funkeln
    var onColorCompleted: ((Int) -> Void)?
}

struct PaintCanvas: UIViewRepresentable { let session: PaintingSession }
```

- **Ebenen:** Weiß + Nummern (grau) → Farbebene → Ränder (schwarz, 1 Bildschirm-
  pixel dünn wirkend, auch gezoomt scharf genug). Farbe deckt die Nummer.
- **Clipping:** Jeder Strich-Abschnitt wird mit der Maske der gewählten Farbe
  geclippt (`CGContext.clip(to:mask:)` o. ä.), Masken pro Farbe gecacht.
  Auflösung der Farbebene: Gitter × 2 (wie Prototyp), Ränder vektor- oder
  höher aufgelöst, damit sie beim Zoomen nicht verpixeln.
- **Eingabe:** Stift (`touch.type == .pencil`) malt. Finger malen **nicht**:
  ein Finger verschiebt, zwei zoomen und drehen (Scroll-/Zoom-Verhalten wie `UIScrollView`,
  0.5×–12×). Damit ist Handballen-Malen ausgeschlossen. **Fallback:** Solange
  noch nie ein Stift erkannt wurde, malt ein Finger (für Geräte ohne Stift und
  für App Review); sobald ein Stift malt, gilt Stift-malt/Finger-navigiert.
- Coalesced + predicted touches für flüssige Linien; runde Kappen; Pinselgröße
  in Bildschirmpunkten (bleibt beim Zoomen gleich groß auf dem Display).
- **Pencil-Doppeltipp / Squeeze** (`UIPencilInteraction`): Rückgängig.
- **Fortschritt:** pro Feld zählen, wie viele Gitterpixel bemalt sind (Pixel gilt
  als bemalt, wenn die Farbebene an seiner Mitte deckt). Feld ≥ 95 % → Feld wird
  sauber vollflächig gefüllt und `onFieldCompleted` feuert. Farbe fertig, wenn
  alle ihre Felder fertig.
- **Undo:** pro Strich, mindestens 30 Schritte (Ausschnitt-Snapshot vor dem
  Strich, nicht die ganze Ebene).
- Tests: Clipping (Strich über fremdes Feld ändert dort nichts), Fortschritt,
  Undo stellt exakt wieder her, PNG rund.

### 4.3 App: `App/`

**Galerie (Start)** – Raster großer Karten: jedes Bild zeigt den aktuellen
Malstand, Fortschrittsring, fertige mit kleinem Abzeichen. Erste Karte
„Neues Bild". Darunter/oben „Zum Ausprobieren": **4 mitgelieferte Motive**
(siehe §6), damit man sofort loslegen kann – auch ohne eigene Fotos (wichtig für
App Review). Langes Drücken: Umbenennen, Löschen (mit Bestätigung), Neu starten.

**Erstellen** – `PhotosPicker` (keine Foto-Berechtigung nötig) oder Motiv →
Editor: große Vorschau der Vorlage, Umschalter „Vorlage | Fertig" (Ränder+Nummern
vs. Farbflächen), **Schieber „Farben" (4–30)** und **„Details" (grob–fein)**.
Beim Schieben rechnet die Vorschau mit `maxSide` 320 live (alte Rechnung wird
abgebrochen), beim Loslassen in voller Auflösung. Farbleiste der Vorlage unter
der Vorschau. Knopf „Los geht's".

**Malen** – Malfläche randlos groß. Farbtöpfe als Leiste (unten, Querformat
seitlich möglich): runde Töpfe mit Nummer, Farbe, Fortschrittsring; fertige Farbe
bekommt Haken und eine kleine Animation und rutscht ans Ende. Gewählte Farbe:
ihre noch offenen Felder pulsieren kurz sanft auf (findet kleine Felder).
Pinselgröße (3 Stufen), Rückgängig, „Ganzes Bild", Zurück zur Galerie.
Autosave nach jedem Strich (gedrosselt) und beim Verlassen/Hintergrund.

**Fertig** – Konfetti, Bild ohne Ränder/Nummern („Rand ausblenden"-Umschalter),
Teilen per `ShareLink` (keine Foto-Berechtigung nötig).

**Speicher** – `Application Support/Artworks/<uuid>/`: `template.bin`,
`paint.png`, `thumb.jpg`, `meta.json` (Titel, erstellt, geändert, Fortschritt,
Optionen). Schreiben atomar. Defekte Ordner werden übersprungen, nicht zum
Absturz.

## 5. Gestaltung **(Claude)**

- Warm und verspielt, aber aufgeräumt: Papier-/Leinwand-Hintergrund (warmes
  Off-White), runde Formen, große Trefferflächen, SF Rounded für Zahlen und
  Titel, eine Akzentfarbe (kräftiges Koralle/Orange). Dark Mode: dunkle
  Arbeitsfläche, Leinwand bleibt weiß.
- Bewegung mit Sinn: Federanimationen beim Wählen eines Topfs, Funkeln bei
  fertigem Feld, Konfetti bei fertigem Bild. `Reduce Motion` respektieren.
- Barrierefreiheit: Töpfe mit VoiceOver-Label „Farbe 3, 40 % fertig", Dynamic
  Type in Galerie/Editor, Kontrast der Nummern ausreichend.
- Sprache der Oberfläche: Deutsch (Entwicklungssprache `de`), Texte kurz und
  freundlich, du-Form. *Nachtrag 2026-11-07 (Ruben):* zum Start in denselben
  neun Sprachen wie Sudoku (de, en, fr, es, it, ja, ko, nl, pt-BR), String Catalogs
  `App/Localizable.xcstrings` und `App/InfoPlist.xcstrings`.

## 6. Mitgelieferte Motive & Icon **(Claude)**

- 4 eigens erzeugte Illustrationen (flacher Stil, klare Flächen, eignen sich gut
  für 10–16 Farben): Fuchs im Herbstwald, Leuchtturm am Meer, Blumenstrauß in
  Vase, Heißluftballons über Hügeln. Erzeugt mit Codex/fal, ~1600 px, als JPG
  im Asset-Katalog. Keine Fotos realer Personen.
- App-Icon 1024×1024: Pinsel/Stift, der ein nummeriertes Feld bunt ausmalt,
  passend zur Akzentfarbe.

## 7. Auslieferung

- **CI** (kopiert von Sudoku): `ci.yml` (Engine `swift test`, App-Tests auf
  iPad-Simulator, Pflicht-Check `app`), `testflight.yml` (Push auf `main` →
  Archiv → Export → `fastlane beta`). Secrets `ASC_KEY_ID`, `ASC_ISSUER_ID`,
  `ASC_KEY_P8_BASE64`, Variable `TESTFLIGHT_GROUP`.
- **App Store Connect:** App-Datensatz „Griffel Malen nach Zahlen",
  `dev.rubeen.malen`, Primärsprache Deutsch, Kategorie Unterhaltung (Zweit:
  Grafik und Design), kostenlos, ohne In-App-Kauf (§9). Externe Gruppe „Öffentlich" mit öffentlichem
  Link, Beta-App-Beschreibung, Datenschutz-URL = `PRIVACY.md` auf GitHub.
- **App-Store-fähig von Anfang an:** `PrivacyInfo.xcprivacy` (keine Daten,
  benutzte Required-Reason-APIs deklariert), `ITSAppUsesNonExemptEncryption NO`,
  keine Berechtigungsdialoge, echtes Icon vor dem ersten Upload.

## 8. Offen / bewusst später

- ~~App-Store-Einreichung selbst (Screenshots, Texte)~~ – erledigt 2026-11-07, siehe
  [`docs/app-store.md`](../../app-store.md).
- iPhone-Layout.
- Eigene Farbe für ein Feld wählen, Pinsel-Texturen.

## 9. Geschäftsmodell (2026-11-07)

> **Nachtrag 2026-11-11 (Ruben): Die App ist komplett kostenlos.** Der In-App-Kauf „Vollversion“
> (`dev.rubeen.malen.unlock`) wurde nie verkauft und nie eingereicht und ist samt Kaufseite,
> Fotozähler und StoreKit-Konfiguration entfernt. Eigene Fotos sind unbegrenzt. Der Rest dieses
> Abschnitts ist nur noch Geschichte.

**Gratis laden, einmal freischalten (Ruben).** Keine Werbung **(Ruben)**, kein Abo.
Griffel-Haltung wie bei Sudoku: einmal zahlen, keine Daten, kein Konto.

- **Gratis (Ruben: ein Foto):** die 4 Motive und **1 Bild aus einem eigenen Foto**,
  mit allen Funktionen. Begrenzt wird die Menge, nicht die Qualität: Farben,
  Details, Übermalschutz und Teilen sind nie gesperrt **(Claude)**. Das erste
  Erlebnis „mein Foto wird ein Malbild“ soll das beste sein.
- **Vollversion:** ein nicht verbrauchbarer In-App-Kauf
  `dev.rubeen.malen.unlock`, Familienfreigabe an, Vorschlag 6,99 € **(Claude)**.
  Schaltet unbegrenzt eigene Fotos frei.
- **Zählen (Claude):** Ein Foto zählt, wenn „Los geht's“ das Bild anlegt. Fotos und
  Schieber im Editor ausprobieren ist frei. Der Zähler wächst nur (Löschen gibt
  kein Gratis-Foto zurück) und liegt in `UserDefaults`; nach Neuinstallation
  beginnt er neu, das ist in Ordnung.
- **Kaufseite statt Popup (Claude, Anti-Ziel §3):** erscheint nur, wenn „Los
  geht's“ ein weiteres eigenes Foto anlegen würde. Der Knopf zeigt dann ein
  Schloss, darunter ein Satz, warum. Nach dem Kauf geht es direkt weiter ins Bild.
  Die Seite hat „Käufe wiederherstellen“ (Pflicht bei nicht verbrauchbaren Käufen).
- **Technik:** StoreKit 2 (`Transaction.currentEntitlements`, `Transaction.updates`,
  SwiftUI-`purchase`-Aktion), kein Server, keine Fremdbibliothek. Die
  Datenschutz-Angabe bleibt „Keine Daten erhoben“. Code in `App/Purchase/`,
  Testprodukt in `StoreKit/Malen.storekit`.
- **Bewusst später:** Motiv-Pakete als weitere Käufe, wenn sich die Vollversion trägt.
