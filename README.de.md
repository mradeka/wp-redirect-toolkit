# wp-redirect-toolkit

[![shellcheck](https://github.com/mradeka/wp-redirect-toolkit/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/mradeka/wp-redirect-toolkit/actions/workflows/shellcheck.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

🇬🇧 [English version](README.md) — die Skriptausgaben sind englisch, diese
Dokumentation ist deutsch.


Werkzeuge zur Analyse und Bereinigung einer WordPress-Kompromittierung, bei der
eine Weiterleitung **direkt in die Datenbank** geschrieben wurde — ohne
Veränderung einer einzigen PHP-Datei.

Entstanden während eines realen Vorfalls auf einem Host mit zehn
WordPress-Installationen. Der vollständige Hergang samt Beweisführung steht in
[INCIDENT.md](INCIDENT.md).

Alle Skripte sind **standardmäßig Trockenlauf** und schreiben nichts, bis
`--apply` gesetzt wird. Vor jeder Änderung wird gesichert.

---

## Inhalt

| Skript | Zweck | Ändert etwas? | Als wem ausführen |
|---|---|---|---|
| [`wp-db-audit`](#wp-db-audit) | Datenbank und Konfiguration: Cron-Hooks, Nutzlast, URLs, Konten | nein | root |
| [`wp-asset-scan`](#wp-asset-scan) | Dateisystem: JS, Landeseiten, Loader, Prüfsummen | nur mit `--apply` | root |
| [`wp-cron-list`](#wp-cron-list) | WP-Cron-Hooks aller Seiten auflisten, Zufallsnamen markieren | nur mit `--delete` | root |
| [`wp-user-audit`](#wp-user-audit) | Benutzerkonten bewerten, Auth-Salts erneuern | nur mit `--delete` / `--shuffle-salts` | root |
| [`wp-redirect-cleanup`](#wp-redirect-cleanup) | Eine Installation bereinigen (v7) | nur mit `--apply` | Seitenbenutzer |
| [`wp-cleanup-all`](#wp-cleanup-all) | Bereinigung über alle Seiten | nur mit `--apply` | root |
| [`wp-rotate-db-passwords`](#wp-rotate-db-passwords) | Datenbankpasswörter rotieren | nur mit `--apply` | root |
| [`wp-move-to-subdir`](#wp-move-to-subdir) | Installation nach `public_html/wordpress/` verschieben | nur mit `--apply` | root |
| [`wp-fix-ownership`](#wp-fix-ownership) | Datei-Eigentümer prüfen und interaktiv korrigieren | nur nach Auswahl | root |
| [`check-usrlocalbin-access`](#check-usrlocalbin-access) | Prüft, ob jedes Konto die Werkzeuge nutzen kann | nein | root |
| [`apply-blocklist`](#apply-blocklist) | Domains der Kampagne sperren oder suchen | nur mit `--apply` | root |
| [`wp-harden-htaccess`](#wp-harden-htaccess) | Abgesicherte `.htaccess` je Installation ausrollen | nur mit `--apply` | root |

---

## Das Schadmuster in Kürze

Jeder Zeile in `wp_posts.post_content` wurde derselbe Block vorangestellt:

```html
<meta http-equiv="refresh" content="7; url=https://BÖSE.DOMAIN/TOKEN" />
<script>(window.matchMedia("(pointer:coarse)").matches|| … )
  &&location.replace("https://BÖSE.DOMAIN/TOKEN");</script>\r\n
```

Dass es Datenbankzugriff war und kein PHP-Backdoor, zeigen vier Punkte:
`post_modified` blieb unverändert, betroffen waren Zeilentypen die WordPress so
nie schreibt (`wp_global_styles`, `wp_navigation`), keine Datei war verändert,
und die `home`-Option war umgebogen.

**Die Zieldomain unterscheidet sich pro Seite** (`urshort.com`,
`ushort.company`, `ushort.org`). Deshalb erkennt `wp-redirect-cleanup` sie
selbst — eine fest vorgegebene Domain meldet betroffene Seiten fälschlich als
sauber.

---

## Installation

Kurzfassung. Die ausfuehrliche Anleitung samt Fehlerbehebung steht in
[INSTALL.md](INSTALL.md).

Voraussetzungen: Bash 4+, WP-CLI 2.7+, MySQL/MariaDB, `curl`, `sudo`.

```bash
git clone https://github.com/mradeka/wp-redirect-toolkit.git
cd wp-redirect-toolkit
chmod +x install.sh
sudo ./install.sh
```

Oder von Hand:

```bash
for S in wp-db-audit wp-cron-list wp-user-audit wp-redirect-cleanup \
         wp-cleanup-all wp-move-to-subdir check-usrlocalbin-access; do
  sudo install -m 755 "${S}.sh" "/usr/local/bin/${S}"
done
sudo install -m 700 wp-rotate-db-passwords.sh /usr/local/bin/wp-rotate-db-passwords
```

`wp-rotate-db-passwords` bekommt bewusst Modus 700 — es schreibt
Klartextpasswörter.

### WP-CLI

```bash
curl -fL -o /tmp/wp-cli.phar https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
php /tmp/wp-cli.phar --version
sudo install -m 755 /tmp/wp-cli.phar /usr/local/bin/wp
```

Beachte das Repository: **`wp-cli/builds`**, nicht `wp-cli/wp-cli`.
Versionen vor 2.7 liefern bei `--fields` zusammen mit `--format=csv` nichts —
die Skripte fangen das mit einer Rückfallebene ab, aktualisieren ist trotzdem
besser.

### Wenn ein Konto `/usr/local/bin/wp` nicht nutzen kann

Fehlerbild: `Could not open input file: /usr/local/bin/wp`, obwohl die Datei
existiert. Ursache ist meist `open_basedir` in der PHP-CLI-Konfiguration oder
ein Jailkit-Käfig. Abhilfe — Kopie ins Home des Kontos:

```bash
install -m 755 -o USER -g USER /usr/local/bin/wp /home/USER/wp
```

und beim Aufruf `--wp-bin /home/USER/wp` angeben. `wp-cleanup-all` erledigt das
selbst; mit `check-usrlocalbin-access` prüfst du alle Konten auf einmal.

---

## Empfohlener Ablauf

```
1. check-usrlocalbin-access      Werkzeuge überall nutzbar?
2. wp-db-audit                 Bestandsaufnahme, ändert nichts
3. wp-asset-scan                 Dateisystem: JS, Landeseiten, PHP
4. wp-cleanup-all                Trockenlauf über alle Seiten
5. wp-cleanup-all --apply        Datenbank bereinigen
6. wp-asset-scan --apply         JS-Injektionen entfernen
7. ─── Zugang schließen ───      Webmin auf 127.0.0.1, Firewall, Passwörter
8. wp-rotate-db-passwords --apply
9. wp-user-audit --shuffle-salts alle Sitzungen ungültig machen
10. apply-blocklist dnsmasq --apply
11. wp-db-audit + wp-asset-scan Kontrolllauf nach 1 h und am Folgetag
```

Schritt 7 vor 8 und 9 ist entscheidend. Wer die Zugangsdaten wechselt, während
der Weg hinein offen ist, sperrt nur sich selbst aus.

---

## Aufteilung der beiden Prüfskripte

Die Trennung folgt der **Datenquelle**, nicht dem Thema:

| | `wp-db-audit` | `wp-asset-scan` |
|---|---|---|
| Quelle | Datenbank und WP-Optionen | Dateisystem |
| Prüft | Cron-Hooks, Nutzlast in `wp_posts`, `home`/`siteurl`, Administratorkonten | JS-Injektionen, Landeseiten, `index.php`-Loader, PHP an falscher Stelle, mu-plugins, Verschleierung, Dumps im Webroot, Prüfsummen von Kern/Plugins/Themes |
| Ändert etwas | nie | nur `--apply`, und nur JS-Zeilen mit bekannter Domain |

> Frühere Versionen hatten beides in `wp-cron-audit` — der Name versprach Cron
> und lieferte alles. Das Skript heißt jetzt `wp-db-audit`; `install.sh`
> entfernt den alten Namen beim Installieren, damit nicht zwei Fassungen
> nebeneinander liegen.

Beide zusammen ergeben das vollständige Bild. Läuft nur eines, bleibt der
jeweils andere Infektionsweg unentdeckt.

## Die Skripte im Einzelnen

### wp-db-audit

Rein lesende Bestandsaufnahme dessen, was in der **Datenbank** und in der
WordPress-Konfiguration steht. Ändert nie etwas.

```bash
sudo wp-db-audit                   # alle Seiten
sudo wp-db-audit --only siteuser   # eine Seite
sudo wp-db-audit --quiet           # nur Funde, für cron geeignet
```

Geprüft wird pro Seite:

| Prüfung | Worauf |
|---|---|
| WP-Cron-Hooks | Zufallsnamen (12+ Zeichen, Buchstaben und Ziffern, keine Trennzeichen) — kein Plugin benennt Hooks so |
| Weiterleitungs-Nutzlast | `post_content`, das mit `<meta http-equiv="refresh"` beginnt, samt Zieldomain |
| `home` / `siteurl` | zeigen die beiden auf verschiedene Hosts, ist eines davon gekapert |
| Administratorkonten | Anzahl und Namen; auffällig viele werden gemeldet |

Rückgabewert 0 = sauber, 1 = Funde. Als wöchentliche Kontrolle:

```cron
0 6 * * 1 /usr/local/bin/wp-db-audit --quiet
```

Für das Dateisystem — JS-Injektionen, Landeseiten, Prüfsummen, mu-plugins —
ist [`wp-asset-scan`](#wp-asset-scan) zuständig. Beide zusammen ergeben das
vollständige Bild.

### wp-cron-list

Zeigt die Cron-Tabelle jeder Seite und markiert Hooks mit Zufallsnamen.

```bash
sudo wp-cron-list                 # alle Seiten, volle Tabelle
sudo wp-cron-list --suspicious    # nur die markierten Zeilen
sudo wp-cron-list --only siteuser
sudo wp-cron-list --delete        # markierte Hooks entfernen, mit Rückfrage
```

Dreistufige Bewertung: bekannte Kern- und Plugin-Hooks normal, unbekannte aber
lesbare gelb, zufällig aussehende (12+ Zeichen, Buchstaben und Ziffern, keine
Trennzeichen) rot.

Bei `--delete` wird zuerst geprüft, ob eine PHP-Datei den Hook registriert.
Findet sich Code, ist Löschen sinnlos — er trägt den Eintrag wieder ein.

### wp-user-audit

Bewertet Benutzerkonten anhand mehrerer Merkmale statt nur des Namens.

```bash
sudo wp-user-audit                        # nur Bericht
sudo wp-user-audit --only siteuser
sudo wp-user-audit --since 2026-07-15     # Zeitfenster erweitern
sudo wp-user-audit --delete               # löschen, Rückfrage je Konto
sudo wp-user-audit --delete --reassign 1  # Inhalte an ID 1 übertragen
sudo wp-user-audit --shuffle-salts        # neue Auth-Schlüssel auf allen Seiten
sudo wp-user-audit --shuffle-salts --yes  # ohne Rückfrage
```

Punktesystem: +3 Administrator, dessen Login vom Unix-Benutzer abweicht,
+2 nach dem Vorfallsdatum registriert, +2 fremde Mail-Domain, +1 keine
Beiträge, +1 maschinell wirkender Name, −3 alt und mit Inhalten, −3 reines
Abonnentenkonto von vor dem Vorfall. Ab 4 Punkten Verdacht.

> Die naheliegende Regel „WordPress-Login ≠ Unix-Benutzer → löschen" trifft zu
> viel: Redakteure, Autoren und Shop-Kunden heißen nie wie das
> Home-Verzeichnis, und `wp user delete` nimmt deren Beiträge mit. Konten mit
> eigenen Inhalten werden ohne `--reassign` grundsätzlich übersprungen.

`--shuffle-salts` erneuert die `AUTH_KEY`/`SALT`-Konstanten. Jede bestehende
Anmeldung wird ungültig — auch die eigene. Passwörter ändert es nicht.

### wp-redirect-cleanup

Das eigentliche Bereinigungsskript (v6).

```bash
# Trockenlauf
wp-redirect-cleanup \
  --path /home/SITE/public_html/wordpress \
  --wp-bin /home/SITE/wp \
  --backup /home/SITE/backups

# anwenden
wp-redirect-cleanup … --apply
```

| Option | Bedeutung |
|---|---|
| `--path` | Verzeichnis mit der `wp-config.php` (Pflicht) |
| `--domain` | Schaddomain — **weglassen**, wird aus der Nutzlast erkannt |
| `--url` | öffentliche Adresse (`home`); wird sonst abgeleitet |
| `--siteurl` | Ort des Kerns; bei Unterverzeichnis-Installationen abweichend |
| `--wp-bin` | Pfad zur WP-CLI-phar, falls `wp` nicht nutzbar ist |
| `--backup` | Zielverzeichnis für den Dump — **außerhalb von `public_html`** |
| `--apply` | schreibt Änderungen |

Ablauf: Sicherung → Analyse → `home`/`siteurl` korrigieren → vier
Bereinigungsdurchgänge → Reste → Webverzeichnis aufräumen → Caches leeren →
Verifikation von außen → Checkliste.

**Die vier Durchgänge**, vom engsten zum weitesten:

1. Schnitt vor dem ersten `\r\n` — der Normalfall
2. Schnitt hinter dem schließenden `</script>` — für Zeilen, die *nur* aus der
   Nutzlast bestehen
3. Herausschneiden mitten aus dem Text, indem beide Seiten wieder
   zusammengefügt werden; wiederholt für Zeilen mit mehreren Vorkommen
4. Entfernen zwischengespeicherten oEmbed-Markups
   (`<blockquote class="wp-embedded-content" data-secret="…"> … </iframe>`),
   das entstand, während `home` verbogen war

Zeilen, die danach leer sind, wandern bei `post`/`page` in den **Papierkorb**
statt gelöscht zu werden. Wegwerf-Typen (`oembed_cache`,
`customize_changeset`, `request`, `revision`) werden entfernt.

Nicht automatisiert bleiben serialisierte Werte in `wp_options`, `postmeta` und
`comments` — dort zerstört ein blinder Schnitt die Längenangaben. Sie werden
gemeldet und über `wp option get/set` bearbeitet.

### wp-cleanup-all

Führt die Bereinigung über alle gefundenen Installationen aus.

```bash
sudo wp-cleanup-all             # Trockenlauf
sudo wp-cleanup-all --summary   # eine Zeile pro Seite
sudo wp-cleanup-all --only siteuser
sudo wp-cleanup-all --apply
```

Ermittelt den Eigentümer aus der `wp-config.php`, führt die Bereinigung als
dieser aus, legt die phar bei Bedarf im Home des Benutzers ab und schreibt pro
Seite ein Protokoll nach `/root/wp-cleanup-logs`.

### wp-rotate-db-passwords

Erzeugt neue MySQL-Passwörter, trägt sie in `wp-config.php` ein und
protokolliert sie unter `/root/wp-db-credentials.txt` (Modus 600).

```bash
sudo wp-rotate-db-passwords                            # Trockenlauf
sudo wp-rotate-db-passwords --apply
sudo wp-rotate-db-passwords --apply --only siteuser
sudo wp-rotate-db-passwords --apply --length 40
sudo wp-rotate-db-passwords --defaults-file /etc/mysql/debian.cnf
```

Zwei Dinge, die eine naive Schleife falsch macht:

- **Gemeinsame Datenbankbenutzer.** Nutzen mehrere Installationen denselben
  `DB_USER`, wird einmal rotiert und in alle zugehörigen `wp-config.php`
  geschrieben. Sonst sperrst du alle Seiten bis auf die letzte aus.
- **Rollback.** Schlägt das Schreiben oder der Verbindungstest fehl, werden
  MySQL-Passwort **und** `wp-config.php` zurückgesetzt.

Das erzeugte Passwort enthält bewusst keine Anführungszeichen, Backslashes,
Dollarzeichen, Schrägstriche oder `&` — jedes davon müsste in PHP, SQL und sed
unterschiedlich maskiert werden.

Braucht MySQL-Adminzugang. Ohne Socket-Authentifizierung:

```bash
umask 077
printf '[client]\nuser=root\npassword=%s\n' 'PASSWORT' > /root/.my.cnf
chmod 600 /root/.my.cnf
```

Danach noch von Hand prüfen: Backup-Skripte, `~/.my.cnf` der Seitenbenutzer,
phpMyAdmin, eigene Cron-Jobs.

### wp-move-to-subdir

Verschiebt eine Installation von `public_html/` nach `public_html/wordpress/`
nach dem offiziellen Muster „Giving WordPress its own directory".

```bash
sudo wp-move-to-subdir --path /home/SITE/public_html
sudo wp-move-to-subdir --path /home/SITE/public_html --apply
sudo wp-move-to-subdir --path … --dir cms --apply
sudo wp-move-to-subdir --path … --skip-apache-check --apply
```

**Keine Bereinigungsmaßnahme** — eine Layoutänderung, die jede Datei einer
laufenden Seite anfasst. Eine Seite nach der anderen, nicht im Stapel.

- Kern wandert nach `wordpress/`, im Wurzelverzeichnis bleibt ein
  Loader-`index.php`
- `siteurl` → `https://domain/wordpress`, **`home` bleibt unverändert** — die
  öffentliche Adresse ändert sich nicht
- `AllowOverride` wird vorab geprüft; ohne `All` würde die Wurzel-`.htaccess`
  ignoriert und der Umzug bricht ab
- veraltete Rewrite-Regeln, deren Ziel nicht existiert (typisch ein
  Vorlagenrest `/my_subdir/`), werden samt zugehöriger `RewriteCond`-Zeilen
  entfernt; eigene Regeln bleiben erhalten
- PHP-Ausführung in `uploads/` wird unterbunden, Rechte gesetzt
- Datei- und Datenbanksicherung vorab

> **Erwartete Nebenwirkung:** Danach meldet `wp core verify-checksums`
> dauerhaft eine Abweichung bei `index.php`. Das ist korrekt — die Datei
> enthält den angepassten `require`-Pfad. Nicht mit
> `wp core download --force` überschreiben.

### wp-asset-scan

Prüft die **dateibasierten** Infektionswege derselben Kampagne, die die
übrigen Werkzeuge nicht abdecken.

```bash
sudo ./wp-asset-scan.sh                          # alle Installationen
sudo ./wp-asset-scan.sh --path /home/SITE/public_html
sudo ./wp-asset-scan.sh --suspicious             # Verdachtsfälle im Detail
sudo ./wp-asset-scan.sh --apply                  # Treffer in JS-Dateien entfernen
```

Hintergrund: Laut der Analyse von Sal Aguilar (WPSecurityAnalyzer, Mai 2026)
verbreitet sich dieselbe Kampagne zusätzlich über Weiterleitungen, die ans
**Ende bestehender JS-Dateien** angehängt werden, sowie über gefälschte
„Coming soon"-Seiten als `.htm`, `.html` und `.php`. Eine reine
Datenbankbereinigung lässt beides unberührt — die Seite leitet dann nach dem
Aufräumen weiter weiter.

Geprüft wird:

| Prüfung | Ansatz |
|---|---|
| JS-Injektion | nur die letzten 800 Bytes jeder `.js` — dort sitzt der angehängte Code, auch bei minifizierten Dateien |
| Protokollmarker | `"//https:` in einem String — so schreibt kein Entwickler eine URL |
| Landeseiten | `.htm`/`.html` mit Meta-Refresh oder `location`, Dateinamen mit „coming soon" |
| PHP an falscher Stelle | `uploads/`, `cache/`, `languages/` — Übersetzungsdateien (`*.l10n.php`) ausgenommen |
| `index.php`-Loader | inhaltlich statt per Prüfsumme — siehe unten |
| Prüfsummen | Kern, Plugins und Themes; nicht prüfbare Erweiterungen werden benannt |
| mu-plugins | werden immer geladen, beliebtes Versteck |
| Verschleierung | zweistufig: Ausführung **kombiniert mit** Verschleierung als Befund, einzelne Funktionen nur als Hinweis |
| `auto_prepend_file` | in `.htaccess`, `.user.ini`, `php.ini` |
| Dumps und Archive | `.sql`, `.tar.gz`, `.zip`, `.phar` im Webverzeichnis |
| Änderungsdatum | PHP-Dateien der letzten 7 Tage |

Zwei Stufen: **TREFFER** (eine Domain der Sperrliste kommt vor, mit `--apply`
entfernbar) und **VERDACHT** (Weiterleitungsmuster ohne bekannte Domain, wird
nur gemeldet — legitime Skripte enthalten ebenfalls `location`-Zuweisungen).

**Zur `index.php` bei Unterverzeichnis-Installationen:** Der Loader im Webroot
ist dort *immer* angepasst — der `require`-Pfad zeigt auf das Kernverzeichnis.
Die Prüfsumme kann also nie stimmen, und eine Warnung darüber wäre reines
Rauschen. Deshalb laufen die Prüfsummen gegen das **Installationsverzeichnis**,
und der Loader wird stattdessen inhaltlich bewertet. Als Befund gilt:

- verschleiernde oder ausführende Konstrukte (`eval`, `base64_decode`,
  `shell_exec`, `preg_replace` mit `/e`, …)
- Nachladen aus dem Netz (`file_get_contents("https://…")`, `curl_exec`,
  `fsockopen`)
- eine `header("Location: …")`-Weiterleitung
- `include`/`require` auf etwas anderes als `wp-blog-header.php`,
  `wp-load.php` oder `wp-settings.php`
- mehr als 15 Zeilen Code oder über 2 KB — ein Loader hat zwei Anweisungen

Ein sauberer Loader wird als solcher gemeldet, mit dem Hinweis, dass die
Prüfsummenabweichung dort normal ist.

**Zu Übersetzungsdateien:** Seit WordPress 6.5 liegen Sprachpakete zusätzlich
als PHP-Dateien (`*.l10n.php`) unter `wp-content/languages/` — das ist legitim
und lädt schneller als die alten `.mo`-Dateien. Sie werden von der Prüfung
ausgenommen, ebenso andere Dateien dort, die nur ein `return [...]`-Array
enthalten. Eine PHP-Datei unter `languages/`, die tatsächlich Code ausführt,
wird weiterhin gemeldet.

**Zur Verschleierungssuche:** Ein Grep auf `eval`, `base64_decode` oder
`gzinflate` allein erzeugt Fehlalarme — der WordPress-Kern selbst enthält
solche Aufrufe. `wp-admin/includes/class-pclzip.php` etwa nutzt
`gzinflate`/`gzdeflate`, um ZIP-Archive zu entpacken, und trägt ein
auskommentiertes `eval(` aus alten Versionen. Deshalb:

- **Der Kern wird nicht durchsucht** — er ist durch `wp core verify-checksums`
  abgedeckt, was zuverlässiger ist als jede Mustersuche. Gesucht wird nur in
  `wp-content/`.
- **Befund** ist die *Kombination*: `eval(base64_decode(…))`,
  `assert($_POST…)`, `preg_replace` mit `/e`-Modifikator, oder ein
  base64-Blob über 200 Zeichen in einer Dekodierfunktion.
- **Hinweis** (nur mit `--suspicious`) sind einzelne Funktionen. Caches,
  Minifier und Importer nutzen sie legitim.

**Zu gekauften Themes und Plugins:** Prüfsummen gibt es nur für Erweiterungen
aus dem offiziellen WordPress-Verzeichnis. Enfold, Divi, Avada, WP Rocket, ACF
Pro und Ähnliches stehen dort nicht — WP-CLI meldet `Could not retrieve the
checksums` und überspringt sie. Das Skript unterdrückt diese Meldung nicht,
sondern listet die betroffenen Erweiterungen auf und warnt ausdrücklich, dass
sie **nicht** geprüft wurden. Bei Verdacht hilft nur der Vergleich gegen das
Original:

```bash
diff -rq wp-content/themes/enfold/ /pfad/zum/entpackten/original/enfold/
```

Das Original dabei aus dem eigenen Kundenkonto laden, niemals aus einer
Sammelquelle — genau darüber gelangt Schadcode in solche Installationen.

> **Zum Bereinigen von JS:** Entfernt wird gezielt die eingeschleuste
> Anweisung, nicht die ganze Zeile. Bei minifizierten Dateien steht der
> gesamte Code oft auf einer einzigen Zeile — ein zeilenweises Löschen würde
> das Skript zerstören. Jede geänderte Datei wird vorher daneben gesichert.
> HTML- und PHP-Funde werden nie automatisch gelöscht.

### apply-blocklist

Wandelt `blocklist-domains.txt` in Sperrregeln um oder durchsucht die
Installationen nach den Domains der Kampagne.

```bash
./apply-blocklist.sh hosts               # Regeln nur ausgeben
sudo ./apply-blocklist.sh hosts --apply  # in /etc/hosts eintragen
sudo ./apply-blocklist.sh dnsmasq --apply
./apply-blocklist.sh unbound
./apply-blocklist.sh firewalld           # IP-Regeln (siehe Warnung)
./apply-blocklist.sh nftables
./apply-blocklist.sh grep                # Suchmuster für eigene Skripte
./apply-blocklist.sh scan                # /home/*/public_html durchsuchen
```

`blocklist-domains.txt` enthält die im eigenen Vorfall beobachteten Domains
(`urshort.com`, `ushort.company`, `ushort.org`) sowie die von Sal Aguilar
(WPSecurityAnalyzer) im Mai 2026 zur selben Kampagne veröffentlichten
(`ushort.observer`, `ushort.info`, `u-short.net`, `urshort.live`,
`ushort.today`, `ushort.com`, `ushort.dev`).

> **Sperre per DNS, nicht per IP.** Die Domains zeigen auf CDN- und
> Hosting-Adressen, die sich ändern und mit tausenden legitimen Seiten geteilt
> werden — eine IP-Regel trifft zu viel und wirkt nur kurz. Und prüfe
> `ushort.com` gesondert: kurze generische Domains wechseln den Besitzer.

### wp-harden-htaccess

Rollt eine abgesicherte `.htaccess` in jede Installation aus, plus eine zweite
in `wp-content/uploads/`, die die Ausführung hochgeladener Skripte verhindert.

```bash
sudo ./wp-harden-htaccess.sh --inventory     # ZUERST: was steht überhaupt drin?
sudo ./wp-harden-htaccess.sh                 # Trockenlauf
sudo ./wp-harden-htaccess.sh --only siteuser
sudo ./wp-harden-htaccess.sh --apply
sudo ./wp-harden-htaccess.sh --apply --strict          # nur PHP-Handler übernehmen
sudo ./wp-harden-htaccess.sh --apply --no-xmlrpc-block
sudo ./wp-harden-htaccess.sh --restore                 # letzte Sicherung zurückspielen
```

**Warum die vorhandenen Dateien nicht einfach gelöscht werden.** Ein
einheitlicher Stand über alle Seiten ist das richtige Ziel — aber ein
pauschales Löschen bricht zwei Dinge:

- **PHP-Handler.** Bei fcgid-Sites legt die `.htaccess` die PHP-Version fest
  (`AddHandler fcgid-script .php`, `AddType application/x-httpd-php81 .php`).
  Fällt die Zeile weg, läuft die Seite mit der Server-Vorgabe — oder PHP wird
  gar nicht mehr ausgeführt und der Browser lädt den Quelltext herunter.
- **Domain-Umleitungen** mit SEO-Wert und Blöcke von Caching-Plugins.

Umgekehrt darf auch nicht blind alles übernommen werden: Nach einem Vorfall
kann dort eine eingeschleuste Regel stehen. Deshalb wird **jede Zeile
klassifiziert**:

| Kategorie | Behandlung |
|---|---|
| `php-handler` | immer übernommen, auch mit `--strict` |
| `gefaehrlich` (`auto_prepend_file`, `auto_append_file`, `eval(`) | **nie** übernommen, wird gemeldet |
| `options-risiko` (jede `Options`-Zeile außer `Options -Indexes`) | **nie** übernommen — braucht `AllowOverride Options`, sonst liefert Apache 500 |
| `externe-weiterleitung`, `rewrite`, `zugriff`, `standard`, `weiterleitung` | übernommen, mit `--strict` verworfen |
| `unbekannt` | übernommen, mit `--strict` verworfen — vorher ansehen |

`--inventory` zeigt diese Aufstellung für alle Seiten, ohne etwas zu ändern.
Das ist der richtige erste Schritt, wenn die Dateien historisch gewachsen und
von Seite zu Seite verschieden sind.

> Dauerhaft sauberer ist es, die PHP-Version im Panel bzw. im vhost zu setzen
> statt in der `.htaccess`. Dann ist die Datei davon unabhängig und ein
> einheitlicher Stand über alle Seiten wirklich erreichbar.

Enthalten sind: Verzeichnisauflistung aus, Sperre für `wp-config.php`, Dumps,
Archive und Punktdateien, keine PHP-Ausführung in `uploads/`, `cache/` und
`languages/`, XML-RPC gesperrt, Sicherheits-Header, Schutz gegen
Benutzer-Aufzählung über `?author=`, Komprimierung und Browser-Caching.

**Warum dieses Skript vorsichtiger vorgeht als die übrigen:** Eine fehlerhafte
`.htaccess` nimmt die Seite sofort vom Netz. Deshalb:

- die vorhandene Datei wird nach `/root/htaccess-backups` gesichert
- **eigene Rewrite-Regeln werden übernommen**, nicht überschrieben — ein
  früher erzeugter Absicherungsblock dagegen verworfen, sonst stapeln sich
  die Blöcke bei jedem Lauf
- das Layout wird erkannt und die `RewriteBase` entsprechend gesetzt
  (`/` oder `/wordpress/`)
- `apachectl configtest` läuft nach dem Schreiben
- der **HTTP-Status wird vor und nach der Änderung gemessen**; antwortet die
  Seite danach nicht mehr, wird automatisch zurückgerollt
- zum Schluss ein Wirksamkeitstest: eine harmlose Testdatei in `uploads/` wird
  abgerufen und wieder gelöscht. Wird sie ausgeführt, greift die Regel nicht —
  meist fehlt dann `AllowOverride All`

> Nach dem Ausrollen die Permalinks in wp-admin einmal speichern und Login,
> Medien-Upload sowie den Block-Editor kurz testen. Bei aktivem
> Caching-Plugin dessen Regeln neu schreiben lassen.

### wp-fix-ownership

Prüft über alle Installationen, ob die Dateien dem jeweiligen Seitenbenutzer
gehören — und bietet danach eine Auswahl an, welche korrigiert werden sollen.

```bash
sudo ./wp-fix-ownership.sh              # prüfen, dann interaktiv auswählen
sudo ./wp-fix-ownership.sh --report     # nur prüfen
sudo ./wp-fix-ownership.sh --all --yes  # alle betroffenen ohne Rückfrage
sudo ./wp-fix-ownership.sh --no-chmod   # nur Eigentümer, Rechte unverändert
```

Auswahl per Nummer: einzeln (`2 5 7`), als Bereich (`2-5`), gemischt
(`1 3-5 8`), alle (`a`) oder abbrechen (`q`).

**Warum das auftritt:** Läuft ein `wp core download`, ein Update oder ein
Skript versehentlich als root, gehören die Dateien danach root. Die Symptome
sehen aus wie unabhängige Probleme:

| Betroffener Bereich | Symptom |
|---|---|
| Kern (`wp-admin`, `wp-includes`, Wurzel) | Aktualisierungen fragen nach FTP-Zugangsdaten |
| `wp-content/uploads` | Medien-Uploads scheitern |
| generierte Theme-Assets (`uploads/dynamic_avia/`) | Seite verliert ihre Formatierung |

Uploads und Updates können unabhängig voneinander brechen: Für Uploads genügt
Schreibrecht in `uploads/`, für Updates muss der gesamte Kern dem
Seitenbenutzer gehören. Deshalb weist die Übersicht den betroffenen Bereich
aus.

Zur Nachkontrolle ruft das Skript `get_filesystem_method()` auf — genau die
Funktion, mit der WordPress entscheidet, ob es nach FTP fragt. `direct`
bedeutet: Aktualisierungen laufen wieder durch.

> `--no-chmod` verwenden, wenn eigene Skripte mit Ausführungsbit im
> Verzeichnis liegen. Andernfalls werden Rechte auf 755/644 vereinheitlicht;
> vorher ausführbare Dateien werden vorsorglich nach `/root` protokolliert.

### check-usrlocalbin-access

Prüft für jedes Konto, ob `/usr/local/bin` und die Werkzeuge dort nutzbar sind.

```bash
sudo check-usrlocalbin-access          # Konten mit WordPress-Installation
sudo check-usrlocalbin-access --all    # alle /home-Konten
sudo check-usrlocalbin-access --bin php
```

Vier Dinge werden getrennt geprüft, weil sie gern verwechselt werden:
`dir` (durchsuchbar), `exec` (ausführbar gesetzt), `run` (läuft tatsächlich —
hier schlägt `open_basedir` zu) und `PATH`. Dazu `jail` und ein
Funktionstest von `wp-redirect-cleanup` je Konto.

Bei Jailkit-Konten läuft `sudo -u` **außerhalb** des Käfigs und funktioniert;
ein SSH-Login desselben Benutzers sieht `/usr/local/bin` dagegen nicht. Für
diese Konten ist die Kopie im Home die richtige Lösung.

---

## Nach der Bereinigung

Die Zeilen zu säubern beseitigt das Symptom, nicht die Ursache.

- [ ] Webmin und phpMyAdmin aus dem Internet nehmen:
      `bind=127.0.0.1` in `/etc/webmin/miniserv.conf`, dann `/etc/webmin/restart`
- [ ] Zugriff per SSH-Tunnel: `ssh -L 10000:127.0.0.1:10000 user@host` —
      im Tunnel und im Browser **`127.0.0.1`**, nicht `localhost`
- [ ] Cloud-Firewall ist Default-Deny: 22, 80, 443, 25 und weitere explizit
      erlauben, jede Regel für `0.0.0.0/0` **und** `::/0`
- [ ] `/var/webmin/webmin.log` und `miniserv.log` auf fremde Sitzungen prüfen,
      `/etc/webmin/miniserv.users` auf unbekannte Konten
- [ ] Zugangsdaten wechseln: Datenbank, alle Administratorkonten, Salts, SSH,
      Webmin
- [ ] `last`, `lastb`, `authorized_keys` in allen Homes
- [ ] `mailq | tail` — ein kompromittierter Host mit Postfix wird als
      Spam-Relais missbraucht
- [ ] Kontrolllauf nach einer Stunde und am Folgetag

Steigt die Fundzahl wieder, besteht der Zugang weiter — dann die Seite offline
nehmen statt erneut zu bereinigen. Zeigen die Webmin-Protokolle eine unbekannte
Sitzung: Webmin läuft als root, also ist von vollständiger
Host-Kompromittierung auszugehen, und ein Neuaufbau ist die einzige belastbare
Konsequenz.

---

## Häufige Fehlerbilder

| Symptom | Ursache |
|---|---|
| `wp: command not found` | WP-CLI nicht installiert |
| `Could not open input file: /usr/local/bin/wp` | `open_basedir` oder Jail sperrt den Pfad |
| `WP-CLI cannot read this install` | falscher Pfad oder `wp-config.php` nicht lesbar |
| `sudo: unable to execute ./script: Permission denied` | Skript in `/root` (Modus 700) |
| `X is not in the sudoers file` | `sudo -u` als Nicht-root aufgerufen |
| `could not read cron events` / `users` | WP-CLI älter als 2.7 |
| `PR_CONNECT_RESET_ERROR` im Tunnel | `localhost` statt `127.0.0.1` (IPv6) |
| Seite ohne Formatierung nach Bereinigung | `home`/`siteurl` verbogen |
| Weiterleitung trotz sauberem `curl` | Browsercache |
| `curl 404` beim WP-CLI-Download | Repository ist `wp-cli/builds` |

---

## Haftungsausschluss

Diese Skripte verändern Datenbanken und Konfigurationsdateien produktiver
Websites. Sie legen vor jeder Änderung Sicherungen an und laufen ohne `--apply`
folgenlos — trotzdem gilt: erst Trockenlauf lesen, dann anwenden, und eine
eigene Sicherung außerhalb des Servers schadet nie.

Bei einer Kompromittierung mit root-Zugriff ist keine Bereinigung vollständig.
Im Zweifel neu aufsetzen.

## Mitwirken

Rückmeldungen aus echten Vorfällen sind das Wertvollste — besonders
Fehlalarme und nicht erkannte Varianten. Siehe [CONTRIBUTING.md](CONTRIBUTING.md).

Sicherheitsprobleme **in diesen Skripten** bitte nicht als öffentliches Issue,
sondern über die private Meldefunktion von GitHub — siehe
[SECURITY.md](SECURITY.md).

## Lizenz

MIT
