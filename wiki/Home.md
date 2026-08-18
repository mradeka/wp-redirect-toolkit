# wp-redirect-toolkit

Werkzeuge zur Analyse und Bereinigung einer WordPress-Kompromittierung, bei der
eine Weiterleitung **direkt in die Datenbank** geschrieben wurde — ohne
Veränderung einer einzigen PHP-Datei.

Dieses Wiki ist deutsch; die Skriptausgaben sind englisch.

Entstanden während eines realen Vorfalls auf einem Host mit zehn
WordPress-Installationen. Jedes Erkennungsmuster ist gegen echte Befunde
**und** gegen legitime Gegenbeispiele geprüft.

---

## Wo willst du anfangen?

**„Meine Seite leitet auf eine fremde Domain um."**
→ [Playbook: Vorfall](Playbook-Vorfall) — der Ablauf von der ersten Diagnose
bis zur Kontrolle am Folgetag.

**„Ich will nur wissen, ob etwas nicht stimmt."**
→ [Schnellstart](Schnellstart) — drei Befehle, die nichts verändern.

**„Das Skript meldet eine Datei, die legitim aussieht."**
→ [Bekannte Fehlalarme](Fehlalarme) — Katalog der Fälle, die harmlos sind,
samt Begründung.

**„Ein Befehl schlägt fehl."**
→ [Fehlerbehebung](Fehlerbehebung)

**„Was macht welches Skript?"**
→ [Skript-Referenz](Skripte)

**„Wie verhindere ich das künftig?"**
→ [Absicherung](Absicherung)

**„Wie hat der Angreifer das gemacht?"**
→ [Anatomie des Angriffs](Anatomie-des-Angriffs)

---

## Die Grundidee in drei Sätzen

Die Nutzlast steht in der Datenbank, nicht in Dateien. `post_modified` blieb
unverändert, betroffen waren Zeilentypen, die WordPress so nie schreibt, und
`wp core verify-checksums` meldete nichts — es gab also keinen PHP-Backdoor,
sondern jemand hatte Datenbankzugriff.

Die Zieldomain unterscheidet sich **pro Seite**. Ein Scan mit fest
vorgegebener Domain meldet betroffene Seiten fälschlich als sauber; deshalb
liest das Bereinigungsskript sie aus der Nutzlast selbst.

Nach der Bereinigung leitet der Browser oft weiter, obwohl der Server sauberes
HTML liefert. Eine Meta-Refresh-Seite ist voll cachefähig — im privaten Fenster
oder mit `curl` gegenprüfen.

---

## Zwei Prüfskripte, getrennt nach Datenquelle

| | `wp-db-audit` | `wp-asset-scan` |
|---|---|---|
| Quelle | Datenbank und WP-Optionen | Dateisystem |
| Prüft | Cron-Hooks, Nutzlast in `wp_posts`, `home`/`siteurl`, Konten | JS-Injektionen, Landeseiten, Loader, PHP an falscher Stelle, mu-plugins, Verschleierung, Prüfsummen |
| Ändert etwas | nie | nur mit `--apply` |

Läuft nur eines von beiden, bleibt der jeweils andere Infektionsweg
unentdeckt.

---

## Grundsätze

- **Trockenlauf ist der Standard.** Jede schreibende Aktion hängt an `--apply`.
- **Sichern vor Ändern.** Datenbank-Dump oder Dateikopie, bevor etwas
  überschrieben wird.
- **Nur Eindeutiges automatisch bereinigen.** Alles Mehrdeutige wird gemeldet,
  nicht angefasst.
- **Prüfsumme vor Mustersuche.** Wo `verify-checksums` greift, ist das die
  bessere Antwort — und der Grund für fast alle behobenen Fehlalarme.

---

## Wichtiger Hinweis

Bei einer Kompromittierung mit root-Zugriff ist **keine** Bereinigung
vollständig. Diese Werkzeuge helfen beim Aufräumen und beim Verstehen — sie
ersetzen im Zweifel nicht das Neuaufsetzen des Servers. Siehe
[Playbook: Vorfall](Playbook-Vorfall), Abschnitt „Wann Neuaufbau".
