# Änderungsprotokoll

Format nach [Keep a Changelog](https://keepachangelog.com/de/1.1.0/),
Versionierung nach [SemVer](https://semver.org/lang/de/).

## [1.0.0] — 2026-08-16

Erste Veröffentlichung. Entstanden während eines realen Vorfalls; alle
Erkennungsmuster sind gegen echte Befunde und gegen legitime Gegenbeispiele
geprüft.

### Enthalten

- `wp-db-audit` — Datenbank und Konfiguration: Cron-Hooks mit Zufallsnamen,
  Weiterleitungs-Nutzlast, auseinanderlaufende `home`/`siteurl`,
  Administratorkonten
- `wp-asset-scan` — Dateisystem: JS-Injektionen, gefälschte Landeseiten,
  `index.php`-Loader, PHP an untypischen Orten, mu-plugins, Verschleierung,
  Dumps im Webverzeichnis, Prüfsummen von Kern, Plugins und Themes
- `wp-cron-list` — Cron-Tabelle aller Seiten, Zufallsnamen markiert
- `wp-user-audit` — Benutzerkonten bewerten, Auth-Salts erneuern
- `wp-redirect-cleanup` (v7) — Bereinigung einer Installation in vier
  Durchgängen
- `wp-cleanup-all` — Bereinigung über alle Seiten
- `wp-rotate-db-passwords` — Datenbankpasswörter rotieren, mit Rollback
- `wp-move-to-subdir` — Umzug nach `public_html/wordpress/`
- `check-usrlocalbin-access` — Nutzbarkeit der Werkzeuge je Konto
- `apply-blocklist` — Sperrregeln aus `blocklist-domains.txt`

### Bekannte Einschränkungen

- Serialisierte Werte in `wp_options`, `postmeta` und `comments` werden
  gemeldet, aber nicht automatisch bereinigt — ein blinder Schnitt zerstört
  dort die Längenangaben.
- Gekaufte Themes und Plugins haben keine Prüfsummen. Sie werden benannt und
  ausdrücklich als ungeprüft gekennzeichnet.
- Pfadannahme ist `/home/<benutzer>/public_html[/wordpress]`.
