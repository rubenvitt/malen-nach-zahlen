# Malen nach Zahlen

iPad-App: Aus einem Foto wird eine Malvorlage – Felder mit dünnem schwarzem Rand und Nummern –, die man mit dem Apple Pencil richtig ausmalt statt anzutippen. Gemalt wird frei über alles, mit Pinsel, Kreide oder Airbrush; Schatten und Licht dunkeln vorhandene Farbe ab oder hellen sie auf, je nach Stiftdruck. Farbanzahl und Detailgrad stellt man beim Erstellen mit Live-Vorschau ein.

Komplett kostenlos: 4 Motive und beliebig viele eigene Fotos, ohne In-App-Käufe, ohne Abo, ohne Werbung. Sprachen: Deutsch, Englisch, Französisch, Spanisch, Italienisch, Japanisch, Koreanisch, Niederländisch, Portugiesisch (Brasilien).

Design: [`docs/superpowers/specs/2026-11-06-malen-design.md`](docs/superpowers/specs/2026-11-06-malen-design.md) · App Store: [`docs/app-store.md`](docs/app-store.md)

## Aufbau

| Verzeichnis | Inhalt |
|---|---|
| `Packages/PaintEngine` | Foto → Vorlage (Quantisieren, Felder, Nummernplätze). `swift test`. |
| `App` | SwiftUI-App für iPadOS 18+, Malfläche in UIKit. |
| `prototype/web` | Web-Prototyp, Referenz für den Algorithmus. |

Das Xcode-Projekt entsteht aus `project.yml`:

```bash
brew install xcodegen
xcodegen generate && open Malen.xcodeproj
```

Jeder Push auf `main` baut in der CI und lädt nach TestFlight hoch. Texte, Screenshots, Einreichen und Veröffentlichen laufen über die Workflows **App Store** und **Release**.

## Lizenz

MIT, siehe [LICENSE](LICENSE). Datenschutz: [PRIVACY.md](PRIVACY.md).
