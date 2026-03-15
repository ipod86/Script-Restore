# ioBroker Script Restore

Ein schlankes und schnelles Web-Tool, um Skripte (JavaScript, TypeScript, Blockly und Rules) direkt aus ioBroker-Backups zu retten und wiederherzustellen.

Egal ob du aus Versehen ein Skript in ioBroker gelöscht hast oder dein System zerschossen ist – lade einfach deine Backup-Daten hoch. Das Tool extrahiert die Skripte, formatiert sie sauber (un-minified) und stellt sie dir direkt zum Kopieren oder Herunterladen zur Verfügung.

## ✨ Features

* **Flexible Uploads:** Unterstützt **Vollbackups** und **JavaScript-Backups** (als `.tar.gz`-Archive) sowie direkt entpackte `script.json`, `objects.json` oder `objects.jsonl` Dateien.
* **Intelligente Ordnerstruktur:** Das Tool bildet die ioBroker-Ordnerstruktur im Baum-Menü ab – inklusive eines Buttons zum schnellen Auf- und Einklappen aller Ordner.
* **Live-Suche:** Durchsuche deine Backups blitzschnell nach Skriptnamen, Pfaden oder sogar direkt nach Inhalten im Quellcode.
* **Unterstützt alle Skript-Typen:** JavaScript, TypeScript, Blockly (inklusive XML-Generierung für den Re-Import) und Rules.
* **Anpassbares UI:** Mit dem integrierten Resizer kannst du die Breite der Seitenleiste (oder die Höhe auf Mobilgeräten) individuell anpassen.
* **Einfacher Export:** Skripte können mit einem Klick in die Zwischenablage kopiert oder direkt als fertige Datei (`.js`, `.ts`, `.xml`, `.json`) heruntergeladen werden.
* **Management:** Das Setup-Skript installiert das Tool, übernimmt Updates und kann es wahlweise als Hintergrunddienst (systemd) einrichten.

## 🚀 Installation & Update

Kopiere den folgenden Befehl in die Konsole deines Linux-Systems (z. B. Raspberry Pi oder dein ioBroker-Server):

```bash
curl -sSL https://raw.githubusercontent.com/ipod86/Script-Restore/main/setup.sh -o setup.sh && chmod +x setup.sh && ./setup.sh
```
