# App-Store-Veröffentlichung

Was im Repo vorbereitet ist und was nur in App Store Connect geht. Aufbau wie bei Griffel Sudoku.

## Geschäftsmodell

Komplett kostenlos: alle Funktionen, die 4 mitgelieferten Motive und beliebig viele eigene Fotos. Keine In-App-Käufe, keine Werbung, kein Abo (siehe [Design-Spec §9](superpowers/specs/2026-11-06-malen-design.md#9-geschäftsmodell-2026-11-07)).

## Im Repo

| Was | Wo |
|---|---|
| Version (`MARKETING_VERSION`), Kategorie Unterhaltung | `project.yml` |
| Datenschutz-Manifest (keine Daten, kein Tracking) | `App/PrivacyInfo.xcprivacy` |
| Exportkontrolle: keine Verschlüsselung | `ITSAppUsesNonExemptEncryption = NO` in `project.yml` |
| Texte in neun Sprachen (Name, Untertitel, Beschreibung, Schlüsselwörter, Werbetext, URLs) | `fastlane/metadata/de-DE`, `en-US`, `fr-FR`, `es-ES`, `it`, `ja`, `ko`, `nl-NL`, `pt-BR` |
| App-Texte in denselben neun Sprachen (String Catalogs) | `App/Localizable.xcstrings`, `App/InfoPlist.xcstrings` (Homescreen-Name) |
| Notiz an das Prüfteam | `fastlane/metadata/review_information/notes.txt` |
| Screenshots 13″ iPad quer, je Sprache | Workflow **Screenshots**, läuft auch im Workflow **App Store** mit |
| Build | Workflow **TestFlight** bei jedem Push auf `main` |
| Preis, Länder, Altersfreigabe, Texte und Screenshots, optional einreichen | Workflow **App Store** (von Hand starten, nur auf `main`) |
| Freigegebene Version veröffentlichen | Workflow **Release** (von Hand starten, nur auf `main`) |

## Was der Workflow „App Store“ einrichtet

Vor dem Hochladen der Texte läuft `fastlane store_setup` (`fastlane/app_store_connect.rb`, über die App Store Connect API). Es legt nur an, was fehlt; Preise und Länder, die schon gesetzt sind, bleiben unverändert. Ändern geht danach in App Store Connect.

| Was | Wert |
|---|---|
| Preis der App | kostenlos (Deutschland als Basis) |
| Verfügbarkeit der App | alle Länder außer China (Festland braucht eine ICP-Nummer), neue Länder automatisch |
| Altersfreigabe | `fastlane/age_rating.json`, überall „Keine“ bzw. „Nein“ → 4+ (lädt `deliver` mit den Texten hoch) |

## Was nur im Browser geht

1. **App-Datenschutz:** „Keine Daten erhoben“ auswählen und veröffentlichen. Dafür gibt es keine API.
2. Nach der Freigabe Workflow **Release** starten (oder in App Store Connect veröffentlichen).

Eingereicht wird per Workflow (`submit` = `einreichen`), auch schon die erste Version; ohne In-App-Kauf muss nichts von Hand an die Version gehängt werden.

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
