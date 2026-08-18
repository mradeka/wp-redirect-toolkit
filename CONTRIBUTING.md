# Mitwirken

Beiträge sind willkommen — besonders Rückmeldungen aus echten Vorfällen:
Fehlalarme, nicht erkannte Varianten, Umgebungen, in denen etwas nicht läuft.

## Fehlalarme melden

Die nützlichste Art von Issue. Die bisherigen Fehlalarme entstanden alle nach
demselben Muster: eine Muster- oder Namenssuche über Verzeichnisse, deren
Integrität sich auch per Prüfsumme feststellen lässt. Beispiele aus der
Vergangenheit: das Theme-Muster `page-coming-soon.php`, die angepasste
`index.php` bei Unterverzeichnis-Installationen, `class-pclzip.php` im Kern,
Übersetzungsdateien `*.l10n.php`.

Bitte gib an:

- welches Skript und welche Meldung
- den Pfad der Datei (Domain und Benutzername gerne ersetzt)
- warum die Datei legitim ist, wenn du es weißt

## Erkennungsmuster ergänzen

Ergänzungen an `blocklist-domains.txt` und an den Suchmustern brauchen eine
Quelle: eigene Beobachtung mit Datum, oder ein öffentlich zugänglicher
Bericht. Bitte keine Domains auf Verdacht.

## Konventionen im Code

- **Bash 4+**, `set -uo pipefail`. Kein `set -e`: Die Skripte sollen bei einer
  fehlgeschlagenen Einzelprüfung weiterlaufen und am Ende berichten.
- **Trockenlauf ist der Standard.** Jede schreibende Aktion hängt an `--apply`.
- **Sichern vor Ändern.** Datenbank-Dump oder Dateikopie, bevor etwas
  überschrieben wird.
- **Nur eindeutige Funde automatisch bereinigen.** Alles Mehrdeutige wird
  gemeldet, nicht angefasst. Lieber ein gemeldeter Fund zu viel als eine
  gelöschte Datei zu wenig.
- **Prüfsumme vor Mustersuche.** Wo `wp core verify-checksums` oder
  `wp plugin/theme verify-checksums` greift, ist das die bessere Antwort.
- **Fehlermeldungen nicht verschlucken.** Kein `2>/dev/null` an Stellen, an
  denen der Anwender die Ursache braucht.
- **Kein `--force` ohne Rückfrage** bei Löschungen echter Inhalte.

## Vor dem Pull Request

```bash
for f in *.sh; do bash -n "$f"; done
shellcheck -S warning *.sh
for f in *.sh; do [ "$f" = install.sh ] || bash "$f" --help >/dev/null; done
```

Dieselben drei Schritte laufen in der CI. Neue Erkennungslogik bitte gegen
eine kleine Testumgebung prüfen und das Ergebnis im Pull Request zeigen —
sowohl den erkannten Fall als auch einen legitimen Gegenfall.

## Sprache

**Code, Kommentare, Optionsnamen und alle Ausgabetexte auf Englisch.** Das gilt
auch für Fehlermeldungen und Hilfetexte — wer das Werkzeug installiert, soll
nicht auf deutschsprachige Meldungen stoßen.

Dokumentation: `README.md` ist englisch und die maßgebliche Fassung.
`README.de.md` ist die deutsche Übersetzung. Ändert sich eine Option, gehören
beide angepasst. `INSTALL.md`, `INCIDENT.md` und das Wiki sind deutsch.

Issues und Pull Requests gerne in beiden Sprachen.
