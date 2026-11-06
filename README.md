# Malen nach Zahlen

iPad-App: Aus einem Foto wird eine Malvorlage – Felder mit dünnem schwarzem Rand und Nummern –, die man mit dem Apple Pencil richtig ausmalt statt anzutippen. Die Farbe bleibt in den Feldern der gewählten Nummer. Farbanzahl und Detailgrad stellt man beim Erstellen mit Live-Vorschau ein.

Design: [`docs/superpowers/specs/2026-11-06-malen-design.md`](docs/superpowers/specs/2026-11-06-malen-design.md)

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

Jeder Push auf `main` baut in der CI und lädt nach TestFlight hoch.

## Lizenz

MIT, siehe [LICENSE](LICENSE). Datenschutz: [PRIVACY.md](PRIVACY.md).
