# Funk

Gegensprechanlage für zwei Macs im selben Netzwerk. Taste halten, sprechen, loslassen.
Wie ein Funkgerät, nur im Vollduplex: Ihr könnt auch gleichzeitig reden.

- Sprechtaste auf dem **Stream Deck** oder per **Tastenkürzel** (F13 bis F19, ⌃⌥ Leertaste)
- **Echo Cancellation**, funktioniert also auch über Lautsprecher
- Andere Apps (Musik, Calls) werden beim Funken **automatisch leiser**
- **Funk-Piep**, bevor der Partner spricht, **Nicht stören** zum Stummschalten
- Findet den anderen Mac automatisch per Bonjour, keine IP-Adressen nötig
- Menüleisten-App, startet beim Login, kein Dock-Icon

Voraussetzungen: macOS 14 oder neuer, Xcode Command Line Tools.
Für das Stream-Deck-Plugin die Stream Deck App ab 7.1.

## Installation

Auf beiden Macs:

```bash
xcode-select --install          # falls noch nicht vorhanden
git clone https://github.com/DavidSchuchert/funk.git
cd funk
make install
```

Beim ersten Start fragt macOS nach **Mikrofon** und **lokalem Netzwerk**: beides erlauben.
Danach im Menü auf **Plugin installieren** klicken und die Aktion *Funk → Sprechtaste*
auf eine Stream-Deck-Taste ziehen.

Beim allerersten `make install` legt das Makefile ein lokales Signaturzertifikat an
(*Funk Local Signing*). Fragt macOS dabei nach dem Schlüsselbund: **Immer erlauben**.

### Update

```bash
git pull && make install
```

Die Mikrofonfreigabe bleibt erhalten, weil jede Version mit demselben Zertifikat signiert ist.

### Deinstallation

```bash
make uninstall
```

## Anzeige

| Menüleiste | Stream Deck | Bedeutung |
|---|---|---|
| Antenne durchgestrichen | grau, "niemand da" | Partner nicht gefunden |
| Antenne | blau, "bereit" | bereit |
| Mikrofon | rot, "SENDET" | du sprichst |
| Welle | grün, "EMPFANG" | Partner spricht |
| | orange, "DUPLEX" | ihr sprecht beide |
| Lautsprecher durchgestrichen | lila, "stumm" | Nicht stören ist an |
| | grau, "App aus" | Funk-App läuft nicht |

## Wie es funktioniert

```
Stream Deck ──TCP 127.0.0.1:47811──▶ Funk.app ◀──UDP / Bonjour──▶ Funk.app (Partner)
Tastenkürzel ───────────────────────▶
```

- **Audio:** AVAudioEngine mit Voice Processing (Echo Cancellation, Rauschunterdrückung, Ducking).
  Die Engine läuft nur bei Aktivität, weil das Ducking an ihr hängt.
- **Übertragung:** unkomprimiertes PCM, 48 kHz mono, 10-ms-Pakete per UDP. Im Heimnetz
  sind das unter 1 Mbit/s, ein Codec würde nur Latenz und Komplexität bringen.
  20 ms Jitter-Puffer, mehr als 200 ms Rückstand werden verworfen.
- **Stream Deck:** Das Plugin ist nur Sprechtaste und Anzeige. Das Mikrofon gehört der App.
- **Tastenkürzel:** Carbon-Hotkey-API. Meldet Drücken und Loslassen, ohne Bedienungshilfen-Recht.

Projektstruktur:

```
Sources/Funk/     Swift-App (SwiftUI MenuBarExtra)
plugin/           Stream-Deck-Plugin (TypeScript, @elgato/streamdeck)
Resources/        Info.plist, Icon, gepacktes Plugin
scripts/          Signaturzertifikat, Aufräumen alter Versionen
```

## Entwicklung

```bash
make run       # bauen und aus build/ starten
make plugin    # Stream-Deck-Plugin neu bauen und packen (braucht Node.js 24)
```

Logs: Console.app, Filter `de.schuchert.funk`, oder

```bash
log stream --predicate 'subsystem == "de.schuchert.funk"'
```

## Bekannte Eigenheiten

- **AirPods:** Wird das AirPods-Mikro als Eingabe benutzt, schaltet Bluetooth in den
  Headset-Modus und Musik klingt dumpf. Abhilfe: in den Systemeinstellungen das
  eingebaute Mikrofon als Eingabe wählen.
- **Oranger Mikrofon-Punkt** auch beim reinen Empfangen: Voice Processing braucht Ein-
  und Ausgang gleichzeitig, sonst funktioniert die Echo Cancellation nicht.
- **Mikrofonwahl** gibt es bewusst nicht: Voice Processing baut intern ein eigenes
  Aggregate-Device, ein anderes Eingabegerät hineinzuzwingen ist unter macOS unzuverlässig.
  Funk nimmt das System-Standardmikrofon.
- Gedacht für **zwei Macs**. Bei mehr Macs im Netz sprechen alle mit allen, und
  gleichzeitige Sprecher werden nicht getrennt gemischt.

## Lizenz

MIT
