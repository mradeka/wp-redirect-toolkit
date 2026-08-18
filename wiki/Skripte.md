# Skript-Referenz

Elf Skripte. Alle laufen ohne `--apply` als Trockenlauf, alle unterstützen
`--help`.

| Skript | Zweck | Ändert etwas? | Als wem |
|---|---|---|---|
| [`wp-db-audit`](#wp-db-audit) | Datenbank und Konfiguration | nein | root |
| [`wp-asset-scan`](#wp-asset-scan) | Dateisystem und Prüfsummen | nur `--apply` | root |
| [`wp-cron-list`](#wp-cron-list) | Cron-Hooks auflisten | nur `--delete` | root |
| [`wp-user-audit`](#wp-user-audit) | Konten bewerten, Salts erneuern | nur `--delete` / `--shuffle-salts` | root |
| [`wp-redirect-cleanup`](#wp-redirect-cleanup) | Eine Installation bereinigen | nur `--apply` | Seitenbenutzer |
| [`wp-cleanup-all`](#wp-cleanup-all) | Bereinigung über alle Seiten | nur `--apply` | root |
| [`wp-rotate-db-passwords`](#wp-rotate-db-passwords) | DB-Passwörter rotieren | nur `--apply` | root |
| [`wp-harden-htaccess`](#wp-harden-htaccess) | Abgesicherte `.htaccess` ausrollen | nur `--apply` | root |
| [`wp-move-to-subdir`](#wp-move-to-subdir) | Umzug nach `public_html/wordpress/` | nur `--apply` | root |
| [`apply-blocklist`](#apply-blocklist) | Domains sperren oder suchen | nur `--apply` | root |
| [`wp-fix-ownership`](#wp-fix-ownership) | Datei-Eigentümer prüfen und korrigieren | nur nach Auswahl | root |
| [`check-usrlocalbin-access`](#check-usrlocalbin-access) | Nutzbarkeit je Konto | nein | root |

---

## wp-db-audit

Rein lesende Bestandsaufnahme der **Datenbank**.

```bash
sudo wp-db-audit                   # alle Seiten
sudo wp-db-audit --only siteuser
sudo wp-db-audit --quiet           # nur Funde, für cron
```

Prüft: Cron-Hooks mit Zufallsnamen (12+ Zeichen, Buchstaben und Ziffern, keine
Trennzeichen), Nutzlast in `wp_posts`, auseinanderlaufende `home`/`siteurl`,
Administratorkonten.

Rückgabewert 0 = sauber, 1 = Funde.

Hieß früher `wp-cron-audit` — der Name versprach Cron und lieferte alles.
`install.sh` entfernt den alten Namen beim Installieren.

---

## wp-asset-scan

Alles, was im **Dateisystem** liegt.

```bash
sudo wp-asset-scan
sudo wp-asset-scan --path /home/SITE/public_html
sudo wp-asset-scan --suspicious    # Verdachtsfälle im Detail
sudo wp-asset-scan --apply         # JS-Injektionen entfernen
```

| Prüfung | Ansatz |
|---|---|
| JS-Injektion | nur die letzten 800 Bytes jeder `.js` — dort sitzt angehängter Code, auch bei minifizierten Dateien |
| Protokollmarker | `"//https:` in einem String |
| Landeseiten | `.htm`/`.html` mit Meta-Refresh, Namen mit „coming soon" |
| PHP an falscher Stelle | `uploads/`, `cache/`, `languages/` (Übersetzungen ausgenommen) |
| `index.php`-Loader | inhaltlich statt per Prüfsumme |
| Prüfsummen | Kern, Plugins, Themes |
| mu-plugins, Verschleierung, `auto_prepend`, Dumps im Webroot | |

**Zum Bereinigen von JS:** Entfernt wird gezielt die eingeschleuste Anweisung,
nicht die ganze Zeile — bei minifizierten Dateien steht der gesamte Code oft
auf einer Zeile. Jede geänderte Datei wird vorher gesichert. HTML- und
PHP-Funde werden nie automatisch gelöscht.

---

## wp-cron-list

```bash
sudo wp-cron-list                 # volle Tabelle
sudo wp-cron-list --suspicious    # nur markierte Zeilen
sudo wp-cron-list --delete        # entfernen, mit Rückfrage
```

Dreistufig: bekannte Kern- und Plugin-Hooks normal, unbekannte aber lesbare
gelb, zufällig aussehende rot.

Bei `--delete` wird zuerst geprüft, ob eine PHP-Datei den Hook registriert.
Findet sich Code, ist Löschen sinnlos — er trägt den Eintrag wieder ein.

---

## wp-user-audit

```bash
sudo wp-user-audit
sudo wp-user-audit --since 2026-07-15
sudo wp-user-audit --delete --reassign 1
sudo wp-user-audit --shuffle-salts
```

Punktesystem statt Namensvergleich: +3 Administrator mit abweichendem Login,
+2 nach dem Vorfallsdatum registriert, +2 fremde Mail-Domain, +1 keine
Beiträge, +1 maschineller Name, −3 alt und mit Inhalten, −3 reines
Abonnentenkonto von vor dem Vorfall. Ab 4 Punkten Verdacht.

> Die naheliegende Regel „Login ≠ Unix-Benutzer → löschen" trifft zu viel:
> Redakteure, Autoren und Shop-Kunden heißen nie wie das Home-Verzeichnis, und
> `wp user delete` nimmt deren Beiträge mit. Konten mit eigenen Inhalten
> werden ohne `--reassign` grundsätzlich übersprungen.

`--shuffle-salts` erneuert die Auth-Schlüssel. Jede Anmeldung wird ungültig —
auch die eigene. Passwörter ändert es nicht.

---

## wp-redirect-cleanup

```bash
wp-redirect-cleanup --path /home/SITE/public_html/wordpress \
                    --wp-bin /home/SITE/wp \
                    --backup /home/SITE/backups
# dann dieselbe Zeile mit --apply
```

| Option | Bedeutung |
|---|---|
| `--path` | Verzeichnis mit `wp-config.php` (Pflicht) |
| `--domain` | **weglassen** — wird aus der Nutzlast erkannt |
| `--url` / `--siteurl` | werden abgeleitet, wenn eines von beiden sauber ist |
| `--wp-bin` | Pfad zur phar, falls `wp` nicht nutzbar ist |
| `--backup` | **außerhalb von `public_html`** |

**Vier Durchgänge**, vom engsten zum weitesten:

1. Schnitt vor dem ersten `\r\n` — der Normalfall
2. Schnitt hinter `</script>` — Zeilen, die nur aus der Nutzlast bestehen
3. Herausschneiden mitten aus dem Text, beide Seiten zusammengefügt
4. Zwischengespeichertes oEmbed-Markup, entstanden während `home` verbogen war

Leere Zeilen wandern bei `post`/`page` in den **Papierkorb**. Wegwerf-Typen
werden gelöscht.

Bricht ab, wenn `home` **und** `siteurl` dieselbe Domain tragen — dann gibt es
nichts zum Ableiten, und ein Weitermachen würde raten.

---

## wp-cleanup-all

```bash
sudo wp-cleanup-all             # Trockenlauf
sudo wp-cleanup-all --summary   # eine Zeile pro Seite
sudo wp-cleanup-all --apply
```

Findet die Installationen, ermittelt den Eigentümer, führt die Bereinigung als
dieser aus, legt die phar bei Bedarf im Home ab, protokolliert nach
`/root/wp-cleanup-logs`.

---

## wp-rotate-db-passwords

```bash
sudo wp-rotate-db-passwords
sudo wp-rotate-db-passwords --apply
sudo wp-rotate-db-passwords --defaults-file /etc/mysql/debian.cnf
```

Zwei Dinge, die eine naive Schleife falsch macht:

- **Gemeinsame Datenbankbenutzer** werden einmal rotiert und in alle
  zugehörigen `wp-config.php` geschrieben
- **Rollback**: Schlägt Schreiben oder Verbindungstest fehl, werden
  MySQL-Passwort und `wp-config.php` zurückgesetzt

Das erzeugte Passwort enthält keine Anführungszeichen, Backslashes,
Dollarzeichen, Schrägstriche oder `&` — jedes davon müsste in PHP, SQL und sed
unterschiedlich maskiert werden.

Passwörter landen in `/root/wp-db-credentials.txt` (Modus 600).

---

## wp-harden-htaccess

```bash
sudo wp-harden-htaccess --inventory   # ZUERST: was steht überhaupt drin?
sudo wp-harden-htaccess               # Trockenlauf
sudo wp-harden-htaccess --apply --strict
sudo wp-harden-htaccess --restore
```

**Warum vorhandene Dateien nicht gelöscht werden:** Bei fcgid-Sites legt die
`.htaccess` die PHP-Version fest. Fällt die Zeile weg, läuft die Seite mit der
Server-Vorgabe — oder PHP wird gar nicht mehr ausgeführt und der Browser lädt
den Quelltext herunter.

Jede Zeile wird klassifiziert:

| Kategorie | Behandlung |
|---|---|
| `php-handler` | immer übernommen, auch mit `--strict` |
| `dangerous` (`auto_prepend_file`, `auto_append_file`, `eval(`) | **nie** übernommen |
| `options-risk` (jede `Options`-Zeile außer `Options -Indexes`) | **nie** übernommen — braucht `AllowOverride Options`, sonst liefert Apache 500 |
| `rewrite`, `access`, `standard`, `redirect`, `external-redirect` | übernommen, mit `--strict` verworfen |
| `unknown` | übernommen, mit `--strict` verworfen |

> Die Kategorienamen erscheinen so auch in der Ausgabe von `--inventory`.
> Die Skriptausgaben sind durchgehend englisch, diese Dokumentation deutsch.

Absicherungen: Sicherung nach `/root/htaccess-backups`, `apachectl
configtest`, HTTP-Status vor und nach der Änderung mit automatischem Rollback,
und ein Wirksamkeitstest (eine Testdatei in `uploads/` wird abgerufen und
wieder gelöscht).

---

## wp-move-to-subdir

```bash
sudo wp-move-to-subdir --path /home/SITE/public_html
sudo wp-move-to-subdir --path /home/SITE/public_html --apply
```

**Keine Bereinigungsmaßnahme** — eine Layoutänderung, die jede Datei einer
laufenden Seite anfasst. Eine Seite nach der anderen.

`siteurl` → `https://domain/wordpress`, **`home` bleibt unverändert**. Prüft
vorab `AllowOverride` und entfernt veraltete Rewrite-Regeln samt zugehöriger
`RewriteCond`-Zeilen.

> Danach meldet `core verify-checksums` dauerhaft eine Abweichung bei
> `index.php`. Das ist korrekt — siehe [Fehlalarme](Fehlalarme).

---

## apply-blocklist

```bash
./apply-blocklist.sh hosts               # Regeln nur ausgeben
sudo ./apply-blocklist.sh dnsmasq --apply
./apply-blocklist.sh scan                # Installationen durchsuchen
./apply-blocklist.sh grep                # Suchmuster ausgeben
```

Per DNS sperren, nicht per IP — die Domains liegen hinter CDN-Adressen, die
mit tausenden legitimen Seiten geteilt werden.

---

## wp-fix-ownership

```bash
sudo wp-fix-ownership              # prüfen, dann interaktiv auswählen
sudo wp-fix-ownership --report     # nur prüfen
sudo wp-fix-ownership --all --yes
sudo wp-fix-ownership --no-chmod   # nur Eigentümer, Rechte unverändert
```

Auswahl per Nummer: einzeln `2 5 7`, Bereich `2-5`, gemischt `1 3-5 8`, alle
`a`, abbrechen `q`.

Läuft ein `wp core download`, ein Update oder ein Skript versehentlich als
root, gehören die Dateien danach root. Die Symptome wirken wie getrennte
Probleme:

| Bereich | Symptom |
|---|---|
| Kern (`wp-admin`, `wp-includes`, Wurzel) | Aktualisierungen fragen nach FTP-Zugangsdaten |
| `wp-content/uploads` | Medien-Uploads scheitern |
| generierte Theme-Assets (`uploads/dynamic_avia/`) | Seite verliert ihre Formatierung |

Uploads und Updates brechen unabhängig voneinander: Für Uploads genügt
Schreibrecht in `uploads/`, für Updates muss der gesamte Kern dem
Seitenbenutzer gehören. Eine Seite kann also Dateien hochladen und trotzdem
nach FTP fragen — deshalb weist die Übersicht den betroffenen Bereich aus.

Zur Nachkontrolle wird `get_filesystem_method()` aufgerufen — dieselbe
Funktion, mit der WordPress über die FTP-Abfrage entscheidet. `direct`
bedeutet: Aktualisierungen laufen wieder durch.

> `--no-chmod` verwenden, wenn eigene Skripte mit Ausführungsbit im
> Verzeichnis liegen. Sonst werden Rechte auf 755/644 vereinheitlicht; vorher
> ausführbare Dateien werden nach `/root` protokolliert.

## check-usrlocalbin-access

```bash
sudo check-usrlocalbin-access
sudo check-usrlocalbin-access --all
```

Trennt vier Dinge, die gern verwechselt werden: `dir` (durchsuchbar), `exec`
(ausführbar gesetzt), `run` (läuft tatsächlich — hier schlägt `open_basedir`
zu) und `PATH`. Dazu `jail` und ein Funktionstest je Konto.

Bei Jailkit-Konten läuft `sudo -u` **außerhalb** des Käfigs und funktioniert;
ein SSH-Login desselben Benutzers sieht `/usr/local/bin` dagegen nicht.
