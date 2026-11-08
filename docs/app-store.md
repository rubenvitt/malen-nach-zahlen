# App-Store-Veröffentlichung

Was im Repo vorbereitet ist und was nur in App Store Connect geht. Aufbau wie bei Griffel Sudoku.

## Geschäftsmodell

Gratis laden, einmal freischalten, keine Werbung, kein Abo (Begründung in der [Design-Spec §9](superpowers/specs/2026-11-06-malen-design.md#9-geschäftsmodell-2026-11-07)).

- **Gratis:** die 4 mitgelieferten Motive und **1 Bild aus einem eigenen Foto**, mit allen Funktionen.
- **Vollversion** (`dev.rubeen.malen.unlock`, nicht verbrauchbar, Familienfreigabe an): unbegrenzt eigene Fotos.
- Gezählt wird beim Anlegen („Los geht's“); Fotos im Editor ausprobieren bleibt frei. Löschen gibt kein Gratis-Foto zurück.
- Die Kaufseite erscheint nur, wenn jemand ein weiteres eigenes Foto anlegen will, und enthält „Käufe wiederherstellen“.

## Im Repo

| Was | Wo |
|---|---|
| Version (`MARKETING_VERSION`), Kategorie Unterhaltung | `project.yml` |
| Datenschutz-Manifest (keine Daten, kein Tracking) | `App/PrivacyInfo.xcprivacy` |
| Exportkontrolle: keine Verschlüsselung | `ITSAppUsesNonExemptEncryption = NO` in `project.yml` |
| Freischaltung (StoreKit 2, ohne Server) | `App/Purchase/` |
| Test-Produkt für Läufe aus Xcode | `StoreKit/Malen.storekit` (im Schema eingetragen) |
| Texte in neun Sprachen (Name, Untertitel, Beschreibung, Schlüsselwörter, Werbetext, URLs) | `fastlane/metadata/de-DE`, `en-US`, `fr-FR`, `es-ES`, `it`, `ja`, `ko`, `nl-NL`, `pt-BR` |
| App-Texte in denselben neun Sprachen (String Catalogs) | `App/Localizable.xcstrings`, `App/InfoPlist.xcstrings` (Homescreen-Name) |
| Notiz an das Prüfteam (inkl. Weg zur Kaufseite) | `fastlane/metadata/review_information/notes.txt` |
| Screenshots 13″ iPad quer, je Sprache | Workflow **Screenshots**, läuft auch im Workflow **App Store** mit |
| Build | Workflow **TestFlight** bei jedem Push auf `main` |
| Preis, Länder, In-App-Kauf, Altersfreigabe, Texte und Screenshots, optional einreichen | Workflow **App Store** (von Hand starten, nur auf `main`) |
| Freigegebene Version veröffentlichen | Workflow **Release** (von Hand starten, nur auf `main`) |

## Was der Workflow „App Store“ einrichtet

Vor dem Hochladen der Texte läuft `fastlane store_setup` (`fastlane/app_store_connect.rb`, über die App Store Connect API). Es legt nur an, was fehlt; Preise und Länder, die schon gesetzt sind, bleiben unverändert. Ändern geht danach in App Store Connect.

| Was | Wert |
|---|---|
| Preis der App | kostenlos (Deutschland als Basis) |
| Verfügbarkeit der App | alle Länder außer China (Festland braucht eine ICP-Nummer), neue Länder automatisch |
| In-App-Kauf | `dev.rubeen.malen.unlock`, nicht verbrauchbar, Referenzname „Vollversion“, Familienfreigabe an |
| Texte des Kaufs | neun Sprachen aus `fastlane/in_app_purchase.json` (Name ≤ 30, Beschreibung ≤ 45 Zeichen) |
| Preis des Kaufs | 6,99 € (`FULL_VERSION_PRICE` im Fastfile), andere Länder rechnet Apple um |
| Verfügbarkeit des Kaufs | wie die App |
| Prüfnotiz und Screenshot des Kaufs | `fastlane/in_app_purchase_review_note.txt`; Screenshot der Kaufseite aus dem Workflow **Screenshots** (`testInAppPurchaseReviewScreenshot`, englisch, Preis im Simulator per `-uiTestPrice` gesetzt) |
| Altersfreigabe | `fastlane/age_rating.json`, überall „Keine“ bzw. „Nein“ → 4+ (lädt `deliver` mit den Texten hoch) |

Vertrag für bezahlte Apps, Bankverbindung, Steuerformulare und EU-Händlerstatus gelten fürs ganze Konto und sind durch Griffel Sudoku schon erledigt.

## Was nur im Browser geht

1. **App-Datenschutz:** „Keine Daten erhoben“ auswählen und veröffentlichen. Den Kauf wickelt Apple ab; das zählt nicht als Datenerhebung der App. Dafür gibt es keine API.
2. **Erstes Einreichen**, weil der erste In-App-Kauf zusammen mit einer App-Version geprüft werden muss und das nur auf der Versionsseite geht: Version 1.0 öffnen, Build wählen, unter *In-App-Käufe und Abonnements* die Vollversion hinzufügen, **Zur Prüfung einreichen**.
3. Nach der Freigabe Workflow **Release** starten (oder in App Store Connect veröffentlichen).

Ab dem zweiten Update geht das Einreichen per Workflow (`submit` = `einreichen`).

## Workflow „App Store"

Startet unter *Actions → App Store → Run workflow* auf `main`:

- **Ohne Eingaben:** macht frische Screenshots und lädt sie mit allen Texten und der Prüfnotiz hoch (`fastlane metadata`). Nichts wird eingereicht.
- **`submit` = `einreichen`:** wie oben, hängt zusätzlich den neuesten verarbeiteten TestFlight-Build an (oder den aus `build_number`) und reicht die Version aus `project.yml` zur Prüfung ein (`fastlane submit`). Nach der Freigabe wird die App **nicht** automatisch veröffentlicht.
- **`screenshots` aus:** überspringt die Screenshots und behält die in App Store Connect, z. B. wenn du eigene, echt gemalte Screenshots vom iPad hochgeladen hast.

Kontakt für das Prüfteam (Pflicht beim Einreichen, bleibt aus dem öffentlichen Repo heraus), unter *Settings → Secrets and variables → Actions*, wie bei Sudoku:

| Name | Art |
|---|---|
| `REVIEW_FIRST_NAME`, `REVIEW_LAST_NAME`, `REVIEW_EMAIL` | Variable |
| `REVIEW_PHONE` | Secret, mit Ländervorwahl, z. B. `+49 …` |

## Screenshots

Der UI-Test `testAppStoreScreenshots` erzeugt je Sprache vier Bilder im Querformat: Malen (Fuchs zur Hälfte ausgemalt, per `-uiTestPrefill` nur in Debug-Builds), Vorlage im Editor, fertige Vorschau, Galerie. Der Workflow **Screenshots** lässt sich auch einzeln starten, um sie vorher anzusehen (Artefakt `screenshots-iPad-13`).

## Updates

1. `MARKETING_VERSION` in `project.yml` erhöhen und `fastlane/metadata/*/release_notes.txt` („Neuigkeiten“) schreiben. Für Version 1.0 gibt es keine Neuigkeiten, deshalb fehlen die Dateien noch.
2. Mergen: Der Workflow **TestFlight** baut die neue Version.
3. Workflow **App Store** mit `submit` = `einreichen` starten.
4. Nach Apples Freigabe Workflow **Release** mit `confirm` = `veröffentlichen` starten.

## Sprachen

Entwicklungssprache ist Deutsch: Die Schlüssel im String Catalog sind die deutschen Texte im Code. Übersetzt sind Englisch, Französisch, Spanisch, Italienisch, Japanisch, Koreanisch, Niederländisch und Portugiesisch (Brasilien). Anrede wie bei Sudoku: du/tú/je/você, Französisch „vous“, Japanisch und Koreanisch höflich.

- **Neuer oder geänderter Text:** In Xcode bauen, dann ergänzt Xcode den Schlüssel im Katalog; Übersetzungen im Katalog-Editor eintragen. Fehlt eine, zeigt die App den deutschen Text.
- **Neue Sprache:** in beiden Katalogen ergänzen, `fastlane/metadata/<locale>` anlegen und die Sprache in `.github/workflows/screenshots.yml` (`LANGUAGES`), `.github/workflows/app-store.yml` (Zuordnung zur Store-Locale), `MalenUITests/SmokeTests.swift` (Locale im Screenshot-Test) und `MalenTests/LocalizationTests.swift` eintragen.
