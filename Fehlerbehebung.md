# Fehlerbehebung

Jede Meldung hier ist während der Entwicklung tatsächlich aufgetreten.

---

## Übersicht

| Meldung | Ursache | Abschnitt |
|---|---|---|
| `wp: command not found` | WP-CLI fehlt | [WP-CLI](#wp-cli) |
| `Could not open input file: /usr/local/bin/wp` | Konto darf die Datei nicht nutzen | [open_basedir](#could-not-open-input-file) |
| `curl: (22) … 404` beim WP-CLI-Download | falsches Repository | [WP-CLI](#wp-cli) |
| `WP-CLI cannot read this install` | Pfad oder Leserechte | [Installation nicht lesbar](#wp-cli-cannot-read-this-install) |
| `could not read cron events` / `users` | WP-CLI älter als 2.7 | [Alte WP-CLI](#alte-wp-cli-version) |
| `sudo: unable to execute ./script: Permission denied` | Skript liegt in `/root` | [Rechte](#permission-denied-beim-skriptaufruf) |
| `X is not in the sudoers file` | `sudo -u` als Nicht-root | [sudoers](#is-not-in-the-sudoers-file) |
| `./install.sh: Permission denied` | Ausführungsbit fehlt | [Rechte](#permission-denied-beim-skriptaufruf) |
| `No MySQL admin access` | kein DB-Adminzugang | [MySQL](#no-mysql-admin-access) |
| `grep: binary file matches` | Binärzeichen im Log | [Logs lesen](#grep-binary-file-matches) |
| `PR_CONNECT_RESET_ERROR` im Tunnel | `localhost` statt `127.0.0.1` | [SSH-Tunnel](#pr_connect_reset_error) |
| Seite ohne Formatierung nach Bereinigung | `home`/`siteurl` verbogen | [Layout kaputt](#seite-ohne-formatierung) |
| Weiterleitung trotz sauberem `curl` | Browser-Cache | [Cache](#weiterleitung-trotz-sauberem-curl) |
| Upload scheitert, Updates fragen nach FTP | PHP läuft als `www-data` | [mod_php](#upload-scheitert-und-updates-fragen-nach-ftp) |
| `auto-detection … home UND siteurl` | nichts zum Ableiten | [Selbsterkennung](#selbsterkennung-bricht-ab) |

---

## WP-CLI

```bash
curl -fL -o /tmp/wp-cli.phar https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
ls -la /tmp/wp-cli.phar          # rund 7 MB
php /tmp/wp-cli.phar --version
sudo install -m 755 /tmp/wp-cli.phar /usr/local/bin/wp
```

Zwei Stolpersteine:

- Das Repository heißt **`wp-cli/builds`**, nicht `wp-cli/wp-cli`. Letzteres
  liefert einen 404.
- Das `-f` ist wichtig: Ohne dieses Flag schreibt curl bei einem HTTP-Fehler
  die Fehlerseite in die Datei. Ergebnis ist eine phar, die PHP mit
  `Could not open input file` ablehnt.

---

## `Could not open input file`

Ein **PHP**-Fehler, kein Shell-Fehler — die Datei wird also gefunden, kann aber
nicht geöffnet werden.

```bash
ls -la /usr/local/bin/wp
head -c 200 /usr/local/bin/wp        # muss mit "#!/usr/bin/env php" beginnen
sudo -u SITEUSER -H php -i | grep -E 'open_basedir|disable_functions'
```

Zeigt `head` HTML, war der Download kaputt → neu laden.

Ist `open_basedir` gesetzt, beschränkt es das Konto auf sein Home. Die phar
gehört dann dorthin:

```bash
install -m 755 -o SITEUSER -g SITEUSER /usr/local/bin/wp /home/SITEUSER/wp
```

und beim Aufruf `--wp-bin /home/SITEUSER/wp` angeben. `wp-cleanup-all` erledigt
das selbst.

> Lege die phar **nicht** in `public_html` — dort ist sie über den Browser
> erreichbar.

---

## `WP-CLI cannot read this install`

```bash
sudo -u SITEUSER -H wp --path=/pfad config get table_prefix   # echte Meldung
stat -c '%U:%G %a' /pfad/wp-config.php
namei -l /pfad/wp-config.php                                  # Rechte im ganzen Pfad
find /home/SITEUSER -maxdepth 3 -name wp-config.php           # liegt es woanders?
```

`namei -l` ist der nützlichste der vier — oft hakt es an einem
Elternverzeichnis, nicht an der Datei selbst.

---

## Alte WP-CLI-Version

Versionen vor 2.7 liefern bei `--fields` zusammen mit `--format=csv` keine
Ausgabe. Die Skripte fangen das mit einer Rückfallebene ab (gelber Hinweis
„Tabelle ausgewertet"), aber:

```bash
wp cli update --allow-root
```

Kopien in den Home-Verzeichnissen mitziehen:

```bash
find /home -maxdepth 2 -type f \( -name 'wp' -o -name '.wp-cli.phar' \) | while read -r W; do
  U=$(stat -c '%U' "$W")
  install -m 755 -o "$U" -g "$(id -gn "$U")" /usr/local/bin/wp "$W"
done
```

---

## `Permission denied` beim Skriptaufruf

**Nach `git clone`:** Das Ausführungsbit kommt je nach Git-Konfiguration
(`core.fileMode=false`) oder `umask` nicht an.

```bash
chmod +x install.sh && sudo ./install.sh
# oder ohne Rechteänderung:
sudo bash install.sh
```

**Bei `sudo -u SITEUSER ./skript.sh`:** Liegt das Skript in `/root` (Modus
700), darf der Seitenbenutzer das Verzeichnis nicht einmal betreten.

```bash
install -m 755 /root/skript.sh /usr/local/bin/skript
sudo -u SITEUSER -H /usr/local/bin/skript ...
```

Das `-H` nicht vergessen — sonst zeigt `$HOME` auf `/root` und Sicherungen
landen dort.

---

## `is not in the sudoers file`

`sudo -u` wurde als Nicht-root aufgerufen. Bist du bereits als der
Seitenbenutzer angemeldet, ruf das Skript direkt auf:

```bash
/usr/local/bin/wp-redirect-cleanup --path ... --wp-bin ...
```

Der Zusatz „This incident has been reported" ist der Standardtext von sudo,
kein Alarm.

---

## `No MySQL admin access`

```bash
mysql -e 'SELECT 1'                                    # echte Meldung sehen
mysql --defaults-file=/etc/mysql/debian.cnf -e 'SELECT 1'   # Wartungskonto
grep -iE 'pass|login' /etc/webmin/mysql/config              # Panel-Passwort
```

Eigene Zugangsdatei:

```bash
umask 077
printf '[client]\nuser=root\npassword=%s\n' 'PASSWORT' > /root/.my.cnf
chmod 600 /root/.my.cnf
```

Ein Zurücksetzen über `--skip-grant-tables` ist das letzte Mittel — dabei ist
die Datenbank kurzzeitig ohne Rechteprüfung offen.

---

## `grep: binary file matches`

```bash
grep -a 'MUSTER' /var/webmin/miniserv.log
```

Das `-a` erzwingt die Textausgabe bei Logdateien mit Binärzeichen.

---

## `PR_CONNECT_RESET_ERROR`

Der Tunnel steht, aber die Verbindung wird sofort abgerissen.

**Ursache in fast allen Fällen: IPv6.** `bind=127.0.0.1` bindet ausschließlich
auf IPv4; `localhost` löst zuerst auf `::1` auf.

- Im Tunnel (rechtes Feld / Remote server): **`127.0.0.1`**, nicht `localhost`
- Im Browser: `https://127.0.0.1:10000`

Gegenprüfen:

```bash
ss -tlnp | grep 10000            # auf dem Server
curl -kI https://127.0.0.1:10000 # ebenfalls auf dem Server
ssh -v -N -L 10000:127.0.0.1:10000 user@host
```

Steht in `miniserv.conf` `ssl=0`, sprichst du mit `https://` gegen einen
HTTP-Port — dann `http://127.0.0.1:10000` verwenden. Über den Tunnel ist das
unbedenklich, die Strecke ist durch SSH verschlüsselt.

Bei Referer-Fehlern in `/etc/webmin/config` ergänzen:

```
referers=127.0.0.1
```

---

## Firewall sperrt den eigenen Zugang

Cloud-Firewalls arbeiten als **Default-Deny**: Sobald eine Firewall zugewiesen
ist, kommt nur noch durch, was explizit erlaubt ist. Eine einzelne Regel für
Port 10000 sperrt also auch SSH.

Freizugeben: 22, 80, 443, 25, ggf. 465/587/143/993 und ICMP — **jede Regel für
`0.0.0.0/0` und `::/0`**.

```bash
ssh -4 -v user@host
ssh -6 -v user@host
```

Funktioniert nur eine der beiden, fehlt die Regel für die andere
Adressfamilie.

---

## Seite ohne Formatierung

Fast immer ist `home` oder `siteurl` verbogen: Alle Assets werden mit der
Schaddomain als Basis ausgeliefert und laufen ins Leere.

```bash
wp option get home && wp option get siteurl
```

Notfallweg über `wp-config.php`, oberhalb von `/* That's all */`:

```php
define('WP_HOME','https://www.example.de');
define('WP_SITEURL','https://www.example.de/wordpress');
```

Bei Enfold zusätzlich: Die generierten Stylesheets liegen in
`wp-content/uploads/dynamic_avia/` und werden nicht durch ein Theme-Update
wiederhergestellt. Unter Enfold → Performance „Delete old CSS and JS files",
dann unter General Styling einmal speichern.

---

## Weiterleitung trotz sauberem `curl`

```bash
curl -s https://DOMAIN/ | grep -c 'SCHADDOMAIN'    # 0
```

Wenn der Server sauberes HTML liefert, der Browser aber weiterleitet:

1. **Browser-Cache.** Eine Meta-Refresh-Seite ist voll cachefähig. Privates
   Fenster oder anderes Gerät.
2. **Ein verlinktes Asset.** JS- und CSS-Dateien mit prüfen:
   ```bash
   sudo wp-asset-scan --path /home/SITE/public_html
   ```
3. **Service Worker.** DevTools → Application → Service Workers, bei Bedarf
   abmelden. Die überleben ein Leeren des Caches.

Der definitive Test ist die DevTools-Netzwerkansicht: Die Spalte *Initiator*
nennt genau die Datei und Zeile, die die Navigation ausgelöst hat.

---

## Selbsterkennung bricht ab

```
Selbsterkennung nicht verwertbar: 'DOMAIN' steckt in home UND siteurl
```

Entweder sind beide Optionen gekapert — dann gibt es keinen sauberen Wert zum
Ableiten — oder die Erkennung hat die eigene Domain erwischt. In beiden Fällen
dieselbe Abhilfe:

```bash
# echte Zieldomain ermitteln
wp db query "SELECT DISTINCT SUBSTRING_INDEX(SUBSTRING_INDEX(post_content,'url=',-1),'\"',1) \
             FROM wp_posts WHERE post_content LIKE '<meta http-equiv=%' LIMIT 5;"
# öffentliche Adresse ermitteln
grep -rh ServerName /etc/apache2/sites-enabled/ | sort -u
```

Dann explizit übergeben:

```bash
wp-redirect-cleanup --path ... --domain SCHADDOMAIN \
  --url https://www.example.de --siteurl https://www.example.de/wordpress
```

---

## Upload scheitert und Updates fragen nach FTP

Symptome, die zusammengehören, auch wenn sie unabhängig wirken:

- „The uploaded file could not be moved to wp-content/uploads/…"
- WordPress fragt bei Aktualisierungen nach FTP-Zugangsdaten
- `WP_DEBUG_LOG` legt keine Datei an

Gemeinsame Ursache: Der PHP-Prozess ist nicht Eigentümer der Dateien. Auf
Panel-Servern läuft PHP normalerweise per `mod_fcgid`/suexec unter dem
jeweiligen Seitenbenutzer. Ist zusätzlich `mod_php` aktiv, setzt dessen
`SetHandler` das ausser Kraft — und PHP läuft auf **allen** Seiten als
`www-data`.

Feststellen, unter welcher Identität PHP tatsächlich läuft:

```bash
D=/home/SITE/public_html/wordpress
cat > "$D/whoami.php" <<'EOF'
<?php $u=posix_getpwuid(posix_geteuid()); echo $u['name']."\n";
echo is_writable(__DIR__.'/wp-content/uploads/'.date('Y/m')) ? "schreibbar\n" : "NICHT schreibbar\n";
EOF
chown SITE:SITE "$D/whoami.php"
curl -s "https://DOMAIN/wordpress/whoami.php"
rm -f "$D/whoami.php"
```

Steht dort `www-data`, ist `mod_php` die Ursache:

```bash
ls -la /etc/apache2/mods-enabled/ | grep -i php
a2dismod php8.3
apachectl configtest && systemctl restart apache2
```

> Sicherheitlich ist das mehr als ein Betriebsproblem: Unter `mod_php` teilen
> sich alle Domains eine Prozessidentität. Code einer kompromittierten Seite
> kann dann auf die Dateien aller anderen zugreifen. Nach einem Vorfall lohnt
> der Blick, **wann** die Module aktiviert wurden:
> ```bash
> ls -la /etc/apache2/mods-enabled/php*.*
> grep -i php8 /var/log/apt/history.log | tail
> ```

Zeigt der Test den richtigen Benutzer, `uploads` aber trotzdem als nicht
schreibbar, prüfe den **Monatsordner** statt des Elternverzeichnisses — ein
`2026/08`, das root gehört, blockiert trotz korrektem `uploads`:

```bash
find /home/SITE/public_html/wordpress/wp-content/uploads ! -user SITE | head
chown -R SITE:SITE /home/SITE/public_html/wordpress/wp-content/uploads
```

## Nach einem abgebrochenen Lauf

| Skript | Sicherung |
|---|---|
| `wp-redirect-cleanup` | DB-Dump im `--backup`-Verzeichnis |
| `wp-rotate-db-passwords` | `/root/wp-db-credentials.txt` (vor der Änderung geschrieben), `wp-config.php`-Kopie unter `/root` |
| `wp-asset-scan` | `<datei>.bak-<zeitstempel>` daneben |
| `wp-harden-htaccess` | `/root/htaccess-backups`, `--restore` spielt zurück |
| `wp-move-to-subdir` | Tarball und DB-Dump im `tmp/` des Seitenbenutzers |

Datenbank zurückspielen:

```bash
sudo -u SITE -H wp --path=/pfad db import /pfad/zum/dump.sql
```
