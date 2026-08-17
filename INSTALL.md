# Installation

Schritt-für-Schritt-Anleitung für das wp-redirect-toolkit. Für die Bedienung
der einzelnen Skripte siehe [README.md](README.md), für den Hintergrund
[INCIDENT.md](INCIDENT.md).

---

## Inhalt

1. [Voraussetzungen](#1-voraussetzungen)
2. [WP-CLI installieren, aktualisieren, aus dem Webroot entfernen](#2-wp-cli-installieren)
3. [Toolkit installieren](#3-toolkit-installieren)
4. [Zugriff pro Seitenbenutzer sicherstellen](#4-zugriff-pro-seitenbenutzer-sicherstellen)
5. [MySQL-Adminzugang einrichten](#5-mysql-adminzugang-einrichten-nur-für-die-passwortrotation)
6. [Installation prüfen](#6-installation-prüfen)
7. [Erster Lauf](#7-erster-lauf)
8. [Regelmäßige Kontrolle einrichten](#8-regelmäßige-kontrolle-einrichten)
9. [Aktualisieren](#9-aktualisieren)
10. [Deinstallieren](#10-deinstallieren)
11. [Fehlerbehebung](#11-fehlerbehebung)

---

## 1. Voraussetzungen

| Komponente | Mindestversion | Prüfen mit |
|---|---|---|
| Bash | 4.0 | `bash --version` |
| PHP CLI | 7.4 | `php -v` |
| WP-CLI | 2.7 | `wp --version --allow-root` |
| MySQL/MariaDB Client | – | `mysql --version` |
| curl | – | `curl --version` |
| sudo | – | `sudo -V \| head -1` |
| zip/unzip | – | nur zum Entpacken des Archivs |

Getestet auf Ubuntu 24.04 mit MariaDB 10.11 und PHP 8.3, unter Virtualmin mit
Jailkit. Auf Debian, RHEL und AlmaLinux sollte es unverändert laufen; die
Pfadannahmen sind `/home/<benutzer>/public_html[/wordpress]`.

Fehlende Pakete nachinstallieren:

```bash
# Debian / Ubuntu
apt update && apt install -y php-cli mariadb-client curl unzip

# RHEL / AlmaLinux / Rocky
dnf install -y php-cli mariadb curl unzip
```

**WP-CLI 2.6 und älter** liefert bei `--fields` zusammen mit `--format=csv`
keine Ausgabe. Die Skripte fangen das mit einer Rückfallebene ab und weisen
darauf hin, aber ein Update erspart dir mehrere Sonderfälle.

---

## 2. WP-CLI installieren

Dieser Abschnitt deckt drei Dinge ab: die aktuelle Fassung beziehen und
installieren, vorhandene Kopien aktualisieren, und phar-Dateien aus
webseitig erreichbaren Verzeichnissen entfernen.

```bash
curl -fL -o /tmp/wp-cli.phar https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
ls -la /tmp/wp-cli.phar          # sollte rund 7 MB sein
php /tmp/wp-cli.phar --version   # sollte 2.12.x oder neuer zeigen
install -m 755 /tmp/wp-cli.phar /usr/local/bin/wp
wp --version --allow-root
```

Zwei häufige Stolpersteine:

- Das Repository heißt **`wp-cli/builds`**, nicht `wp-cli/wp-cli`. Letzteres
  liefert einen 404.
- Das `-f` bei curl ist wichtig: Ohne dieses Flag schreibt curl bei einem
  HTTP-Fehler die Fehlerseite in die Datei. Das Ergebnis ist eine phar, die
  PHP mit `Could not open input file` ablehnt.

Ist WP-CLI bereits vorhanden, aber veraltet:

```bash
wp cli update --allow-root
```

### Kopien in den Home-Verzeichnissen mitziehen

Liegt die phar zusätzlich in einzelnen Home-Verzeichnissen (siehe Abschnitt 4),
laufen diese Kopien nach einem Update weiter auf der alten Version. Alle auf
einmal aktualisieren:

```bash
find /home -maxdepth 2 -type f \( -name 'wp' -o -name '.wp-cli.phar' \) 2>/dev/null \
| while read -r W; do
    U=$(stat -c '%U' "$W")
    install -m 755 -o "$U" -g "$(id -gn "$U")" /usr/local/bin/wp "$W" \
      && echo "aktualisiert: $W ($U)"
  done
```

Versionen anschließend gegenprüfen — alle sollten identisch sein:

```bash
find /home -maxdepth 2 -type f \( -name 'wp' -o -name '.wp-cli.phar' \) 2>/dev/null \
| while read -r W; do
    U=$(stat -c '%U' "$W")
    printf '%-20s %-32s %s\n' "$U" "$W" "$(sudo -u "$U" -H "$W" --version 2>&1 | head -1)"
  done
```

### phar-Dateien aus dem Webverzeichnis entfernen

Eine phar unter `public_html` ist über den Browser abrufbar — je nach
Serverkonfiguration sogar ausführbar. Sie gehört dort weg, unabhängig davon,
ob du sie selbst abgelegt hast:

```bash
# 1. erst ansehen, was gefunden wird — Erkennung ueber den INHALT, nicht den
#    Namen: eine phar wird oft in "wp" umbenannt und heisst dann nicht mehr
#    wp-cli.phar. Der Stub jeder phar enthaelt "Phar::mapPhar".
find /home/*/public_html -maxdepth 3 -type f -size -20M \
     ! -name '*.jpg' ! -name '*.png' ! -name '*.gif' ! -name '*.webp' \
     -exec sh -c 'head -c 200 "$1" | grep -q "Phar::mapPhar" && ls -la "$1"' _ {} \; 2>/dev/null

# ergaenzend ueber den Namen, falls der Stub abweicht
find /home/*/public_html -maxdepth 3 -type f \
     \( -name '*.phar' -o -name 'wp-cli*' -o -name 'wp' \) 2>/dev/null -ls

# 2. war die Datei schon abrufbar? (Zugriffe ohne 404)
grep -hiE '\.phar|wp-cli|/wp[^-a-z]' /var/log/apache2/*access*.log 2>/dev/null \
  | grep -v ' 404 ' | tail

# 3. entfernen — nur was tatsaechlich eine phar ist
find /home/*/public_html -maxdepth 3 -type f -size -20M \
     -exec sh -c 'head -c 200 "$1" | grep -q "Phar::mapPhar" && rm -v "$1"' _ {} \; 2>/dev/null
```

Der zweite Schritt lohnt sich: Zeigt das Log erfolgreiche Abrufe von außen,
war die Datei nicht nur erreichbar, sondern wurde auch geholt.

Bei der Gelegenheit gehören auch Datenbank-Dumps und Archive aus dem
Webverzeichnis — die enthalten Passwort-Hashes:

```bash
find /home/*/public_html -maxdepth 3 \
     \( -name '*.sql' -o -name '*.sql.gz' -o -name '*.tar.gz' -o -name '*.zip' \) \
     -type f 2>/dev/null -ls
```

Verschieben statt löschen, falls du sie noch brauchst:

```bash
mkdir -p /root/aus-webroot && chmod 700 /root/aus-webroot
mv /home/*/public_html/**/*.sql /root/aus-webroot/ 2>/dev/null
```

`wp-redirect-cleanup` und `wp-db-audit` melden solche Funde ohnehin bei
jedem Lauf — dieser Abschnitt ist die manuelle Variante für den Einstieg.

---

## 3. Toolkit installieren

### Variante A — aus dem Git-Repository

```bash
git clone https://github.com/mradeka/wp-redirect-toolkit.git
cd wp-redirect-toolkit
chmod +x install.sh
sudo ./install.sh
```

Das `chmod +x` ist nötig, weil das Ausführungsbit je nach Git-Konfiguration
(`core.fileMode=false`) oder restriktiver `umask` nicht ankommt. Alternativ
ohne Rechteänderung:

```bash
sudo bash install.sh
```

### Variante B — aus dem ZIP-Archiv

```bash
unzip wp-redirect-toolkit.zip
cd wp-redirect-toolkit
chmod +x install.sh
sudo ./install.sh
```

### Variante C — von Hand

```bash
for S in wp-db-audit wp-cron-list wp-user-audit wp-redirect-cleanup \
         wp-cleanup-all wp-move-to-subdir wp-asset-scan \
         check-usrlocalbin-access apply-blocklist; do
  sudo install -m 755 "${S}.sh" "/usr/local/bin/${S}"
done
sudo install -m 700 wp-rotate-db-passwords.sh /usr/local/bin/wp-rotate-db-passwords
sudo install -d -m 755 /usr/local/share/wp-redirect-toolkit
sudo install -m 644 blocklist-domains.txt /usr/local/share/wp-redirect-toolkit/
```

### Was `install.sh` tut

- kopiert jedes Skript ohne `.sh`-Endung nach `/usr/local/bin`
- prüft vorher jedes Skript mit `bash -n` und überspringt fehlerhafte
- setzt Modus 755 — außer bei `wp-rotate-db-passwords`, das **700** bekommt,
  weil es Klartextpasswörter schreibt
- legt `blocklist-domains.txt` unter `/usr/local/share/wp-redirect-toolkit/` ab
- prüft anschließend alle Voraussetzungen und meldet, was fehlt

Optionen:

```bash
sudo ./install.sh --prefix /opt/bin    # anderes Zielverzeichnis
sudo ./install.sh --uninstall          # entfernt die Skripte wieder
```

Bei abweichendem Präfix findet `apply-blocklist` die Domainliste über die
Umgebungsvariable:

```bash
LIST=/usr/local/share/wp-redirect-toolkit/blocklist-domains.txt apply-blocklist hosts
```

---

## 4. Zugriff pro Seitenbenutzer sicherstellen

`wp-redirect-cleanup` läuft bewusst **als Seitenbenutzer**, nicht als root —
sonst entstehen root-eigene Dateien, die später die Theme-CSS-Generierung
blockieren. Dafür muss jedes Konto WP-CLI ausführen können.

```bash
sudo check-usrlocalbin-access
```

Die Tabelle trennt vier Dinge, die gern verwechselt werden:

| Spalte | Bedeutung |
|---|---|
| `dir` | ist `/usr/local/bin` für das Konto durchsuchbar |
| `exec` | ist die Datei ausführbar gesetzt |
| `run` | läuft sie tatsächlich — hier schlägt `open_basedir` zu |
| `PATH` | steht `/usr/local/bin` in der Login-PATH |
| `jail` | ist das Konto chrootet (Jailkit) |

**Bei `run = NEIN` trotz `exec = ok`** beschränkt `open_basedir` in der
PHP-CLI-Konfiguration das Konto auf sein Home. Fehlerbild:
`Could not open input file: /usr/local/bin/wp`, obwohl die Datei existiert.
Abhilfe — eine Kopie ins Home legen:

```bash
find /home -maxdepth 4 -name wp-config.php 2>/dev/null | while read -r C; do
  U=$(stat -c '%U' "$C")
  H=$(getent passwd "$U" | cut -d: -f6)
  [[ -d "$H" ]] || continue
  install -m 755 -o "$U" -g "$(id -gn "$U")" /usr/local/bin/wp "${H}/wp" \
    && echo "$U -> ${H}/wp"
done | sort -u
```

Danach beim Aufruf `--wp-bin /home/SITE/wp` angeben. `wp-cleanup-all` legt
diese Kopien selbst an.

**Bei `jail = JA`** läuft `sudo -u` außerhalb des Käfigs und funktioniert; ein
SSH-Login desselben Benutzers sieht `/usr/local/bin` dagegen nicht. Auch hier
ist die Kopie im Home die richtige Lösung.

> Lege die phar **nicht** in `public_html` — dort ist sie über den Browser
> erreichbar. `wp-redirect-cleanup` meldet das als Fund im Webverzeichnis.

---

## 5. MySQL-Adminzugang einrichten (nur für die Passwortrotation)

`wp-rotate-db-passwords` braucht Adminrechte auf der Datenbank. Test:

```bash
mysql -e 'SELECT 1'
```

Kommt `Access denied … (using password: NO)`, ist keine Socket-Authentifizierung
aktiv. Drei Wege:

```bash
# 1. Wartungskonto der Distribution
mysql --defaults-file=/etc/mysql/debian.cnf -e 'SELECT 1'
sudo wp-rotate-db-passwords --defaults-file /etc/mysql/debian.cnf

# 2. Von Virtualmin/Webmin hinterlegtes Passwort
grep -iE 'pass|login' /etc/webmin/mysql/config

# 3. Eigene Zugangsdatei
umask 077
printf '[client]\nuser=root\npassword=%s\n' 'PASSWORT' > /root/.my.cnf
chmod 600 /root/.my.cnf
mysql -e 'SELECT 1'
```

Bei Variante 3 das Passwort nicht direkt in die Kommandozeile tippen, wenn die
Shell-History mitschreibt — sonst steht es dauerhaft in `~/.bash_history`.

---

## 6. Installation prüfen

```bash
for S in wp-db-audit wp-cron-list wp-user-audit wp-redirect-cleanup \
         wp-cleanup-all wp-move-to-subdir wp-asset-scan \
         check-usrlocalbin-access apply-blocklist wp-rotate-db-passwords; do
  printf '%-28s ' "$S"
  command -v "$S" >/dev/null && stat -c '%A %n' "$(command -v "$S")" || echo "FEHLT"
done
```

Erwartet: neun Skripte mit `-rwxr-xr-x`, `wp-rotate-db-passwords` mit
`-rwx------`.

Funktionstest ohne Nebenwirkungen:

```bash
wp-db-audit --help
apply-blocklist grep          # gibt das Suchmuster aus
wp-asset-scan --help
```

---

## 7. Erster Lauf

Alles unten ist Trockenlauf und ändert nichts.

```bash
sudo check-usrlocalbin-access     # 1. sind die Werkzeuge überall nutzbar?
sudo wp-db-audit                # 2. Bestandsaufnahme aller Seiten
sudo wp-asset-scan                # 3. Dateisystem: JS, Landeseiten, PHP
sudo wp-cleanup-all               # 4. Trockenlauf der Bereinigung
```

Erst wenn die Ausgabe von Schritt 4 plausibel ist, mit `--apply` wiederholen.
Vor jeder Änderung wird die Datenbank gesichert.

Die vollständige Reihenfolge steht im README unter „Empfohlener Ablauf". Der
entscheidende Punkt daraus: **erst den Zugang schließen, dann die Zugangsdaten
wechseln.** Andersherum sperrst du nur dich selbst aus.

---

## 8. Regelmäßige Kontrolle einrichten

`wp-db-audit` gibt 0 zurück, wenn alles sauber ist, und 1 bei Funden — als
cron-Eintrag meldet es sich also nur, wenn es etwas zu melden gibt:

```cron
# /etc/cron.d/wp-toolkit
MAILTO=admin@example.tld
0 6 * * 1 root /usr/local/bin/wp-db-audit --quiet
30 6 * * 1 root /usr/local/bin/wp-asset-scan
```

Nach einem Vorfall zusätzlich engmaschig: einmal nach einer Stunde, einmal am
Folgetag. Steigt die Fundzahl wieder von 0 auf mehr, besteht der Zugang weiter
— dann die Seite offline nehmen statt erneut zu bereinigen.

---

## 9. Aktualisieren

```bash
cd wp-redirect-toolkit
git pull
chmod +x install.sh
sudo ./install.sh
```

`install.sh` überschreibt vorhandene Versionen. Deine Daten sind davon nicht
betroffen: `/root/wp-db-credentials.txt` und `/root/wp-cleanup-logs` bleiben
erhalten.

Eigene Ergänzungen an `blocklist-domains.txt` gehen beim Überschreiben
verloren — vorher sichern:

```bash
cp /usr/local/share/wp-redirect-toolkit/blocklist-domains.txt /root/
```

---

## 10. Deinstallieren

```bash
sudo ./install.sh --uninstall
```

Entfernt die Skripte aus `/usr/local/bin`. Absichtlich **nicht** entfernt
werden:

- `/root/wp-db-credentials.txt` — enthält die aktiven Datenbankpasswörter
- `/root/wp-cleanup-logs/` — Protokolle vergangener Läufe
- Datenbanksicherungen in den Home-Verzeichnissen

Diese musst du bewusst löschen, wenn du sie nicht mehr brauchst.

---

## 11. Fehlerbehebung

| Meldung | Ursache und Lösung |
|---|---|
| `wp: command not found` | WP-CLI nicht installiert → Abschnitt 2 |
| `Could not open input file: /usr/local/bin/wp` | Datei existiert, Konto kann sie nicht nutzen (`open_basedir`, Jail) → Abschnitt 4 |
| `WP-CLI cannot read this install` | falscher `--path`, oder `wp-config.php` für das Konto nicht lesbar. Prüfen: `stat -c '%U:%G %a' <pfad>/wp-config.php` |
| `sudo: unable to execute ./script: Permission denied` | Skript liegt in `/root` (Modus 700). Nach `/usr/local/bin` installieren |
| `X is not in the sudoers file` | `sudo -u` wurde als Nicht-root aufgerufen. Direkt starten oder als root |
| `could not read cron events` / `users` | WP-CLI älter als 2.7 → aktualisieren |
| `No MySQL admin access` | → Abschnitt 5 |
| `grep: binary file matches` | Logdatei enthält Binärzeichen → `grep -a` |
| `curl 404` beim WP-CLI-Download | falsches Repository, richtig ist `wp-cli/builds` |
| Skript findet keine Installationen | Pfadannahme ist `/home/*/public_html[/wordpress]`. Prüfen mit `find /home -maxdepth 4 -name wp-config.php` |

### Wenn ein Lauf abbricht

Alle schreibenden Skripte legen vorher eine Sicherung an:

| Skript | Sicherung |
|---|---|
| `wp-redirect-cleanup` | Datenbank-Dump im `--backup`-Verzeichnis |
| `wp-rotate-db-passwords` | `/root/wp-db-credentials.txt` (vor der Änderung geschrieben), `wp-config.php`-Kopie unter `/root` |
| `wp-asset-scan` | `<datei>.bak-<zeitstempel>` neben der geänderten Datei |
| `wp-move-to-subdir` | Datei-Tarball und DB-Dump im `tmp/` des Seitenbenutzers |

Zurückspielen einer Datenbank:

```bash
sudo -u SITE -H wp --path=/home/SITE/public_html/wordpress db import /pfad/zum/dump.sql
```

### Wenn nichts mehr geht

Die Skripte sind eigenständig lauffähig — du kannst jedes einzeln aus dem
entpackten Verzeichnis starten, ohne es zu installieren:

```bash
bash ./wp-db-audit.sh
```
