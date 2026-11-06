# Malen nach Zahlen

Web-App, die aus einem Foto eine Malvorlage macht – Felder mit dünnem schwarzem Rand und Nummern. Ausgemalt wird mit Finger oder Apple Pencil, nicht per Antippen: Die Farbe landet nur in den Feldern mit der gewählten Nummer, über den Rand malen geht nicht.

## Nutzung

```sh
npm start        # statischer Server, dann im Browser öffnen
npm test         # Test der Vorlagen-Erzeugung
```

- **Bild wählen:** Foto aus der Mediathek, wird auf 600 px verkleinert, in 8–24 Farben zerlegt.
- **Malen:** Farbe unten wählen, mit einem Finger malen. Zwei Finger verschieben und zoomen.
- Das aktuelle Bild samt Ausgemaltem speichert der Browser (IndexedDB) – Tab zu, später weiter.
- Auf iPad/iPhone zum Home-Bildschirm hinzufügen: Safari löscht sonst gespeicherte Daten von Seiten, die 7 Tage nicht besucht wurden.

Keine Abhängigkeiten, kein Build: `index.html`, `app.js` (Oberfläche, Malen), `seg.js` (Foto → Felder).
