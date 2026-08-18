# Wiki veröffentlichen

Diese Datei gehört **nicht** ins Wiki — sie beschreibt nur, wie die übrigen
Seiten dorthin kommen. Vor dem Push löschen oder ignorieren.

## Einmalig: Wiki aktivieren

Auf GitHub im Repository → **Settings** → **Features** → Haken bei **Wikis**.
Dann im Reiter **Wiki** einmal *Create the first page* anklicken und speichern
— vorher existiert das Wiki-Repository nicht und lässt sich nicht klonen.

## Seiten hochladen

```bash
git clone https://github.com/mradeka/wp-redirect-toolkit.wiki.git
cd wp-redirect-toolkit.wiki

cp /pfad/zu/wiki/*.md .
rm -f PUBLISH.md

git add -A
git commit -m "Wiki: Playbook, Skript-Referenz, Fehlalarme, Absicherung"
git push
```

## Struktur

| Datei | Wird zu |
|---|---|
| `Home.md` | Startseite |
| `_Sidebar.md` | Navigation rechts (auf allen Seiten) |
| `_Footer.md` | Fußzeile (auf allen Seiten) |
| `Schnellstart.md` | Seite „Schnellstart" |
| `Playbook-Vorfall.md` | Seite „Playbook Vorfall" |
| `Skripte.md`, `Fehlalarme.md`, `Fehlerbehebung.md`, `FAQ.md`, `Anatomie-des-Angriffs.md`, `Absicherung.md` | jeweils eine Seite |

Interne Links funktionieren über den Dateinamen ohne Endung:
`[Fehlalarme](Fehlalarme)`. Bindestriche im Dateinamen bleiben im Link
erhalten, werden in der Überschrift aber als Leerzeichen angezeigt.

## Abgrenzung zum README

| | Inhalt |
|---|---|
| README | Was das Projekt ist, Installation, Optionstabellen |
| INSTALL.md | Ausführliche Installation, Voraussetzungen, Sonderfälle |
| INCIDENT.md | Der dokumentierte Vorfall als Bericht |
| Wiki | Anleitungen, Nachschlagewerk, Fehlalarme, FAQ |

Bewusst doppelt: die Kurzinstallation und die Skriptoptionen. Wer im Wiki
landet, soll nicht erst ins README wechseln müssen.

## Pflege

Ändert sich eine Option, sind zwei Stellen zu aktualisieren: `README.md` im
Hauptrepository und `Skripte.md` im Wiki. Ein neuer Fehlalarm gehört in
`Fehlalarme.md` — mit Pfad, Grund und der Verbesserung, die daraus folgte.
