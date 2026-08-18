# Absicherung

Was nach der Bereinigung zu tun ist — und was den Vorfall überhaupt möglich
gemacht hat.

Die Reihenfolge zählt: **erst den Zugang schließen, dann die Zugangsdaten
wechseln.** Andersherum sperrst du nur dich selbst aus.

---

## 1. Panel aus dem Internet nehmen

Der größte Einzelhebel. Ein erreichbares Webmin mit Terminal-Modul macht ein
einziges bekanntes Passwort zum vollständigen root-Zugriff.

```bash
# /etc/webmin/miniserv.conf
bind=127.0.0.1
```

```bash
/etc/webmin/restart
ss -tlnp | grep 10000        # muss 127.0.0.1:10000 zeigen
```

Zugriff danach über einen SSH-Tunnel:

```bash
ssh -L 10000:127.0.0.1:10000 user@host
```

Dann `https://127.0.0.1:10000` im Browser.

> **`127.0.0.1`, nicht `localhost`** — weder im Tunnel noch im Browser.
> `localhost` löst zuerst auf `::1` auf, dort lauscht Webmin nach
> `bind=127.0.0.1` nicht mehr. Fehlerbild: `PR_CONNECT_RESET_ERROR`.

In MobaXterm: Tools → MobaSSHTunnel → Local port forwarding, rechtes Feld
(Remote server) auf `127.0.0.1`, Port 10000. Im Zahnrad den SSH-Key hinterlegen
und auto-reconnect aktivieren.

**Alternative:** WireGuard oder Tailscale auf dem Host, Panel an die
VPN-Adresse binden. Dann brauchst du gar keinen offenen Port.

### Falls es doch öffentlich sein muss

Nach Wirksamkeit sortiert:

1. **Aktuell halten.** `cat /etc/webmin/version` — ältere Fassungen hatten
   root-RCE-Lücken.
2. **IP-Allowlist** (Webmin Configuration → IP Access Control). Bei fester
   IP-Adresse entfernt das fast die gesamte Angriffsfläche.
3. **Zwei-Faktor-Authentifizierung** (Webmin Users → TOTP).
4. **Nie als root anmelden.** Ein Konto mit nur den nötigen Modulen anlegen.
5. **Gefährliche Module entfernen:** `xterm`, `filemin`, `custom`, `shell`,
   `mysql`, `upload`. Genau dort landen die RCE-Ketten.
6. **Brute-Force-Schutz** in `miniserv.conf`:
   ```
   blockhost_failures=3
   blockhost_time=3600
   passdelay=1
   logouttime=10
   ssl=1
   ```

Auch mit allem zusammen bleibt der Tunnel die stärkere Lösung.

---

## 2. Firewall

Cloud-Firewalls arbeiten als **Default-Deny**. Sobald eine zugewiesen ist,
kommt nur noch durch, was explizit erlaubt ist — eine einzelne Regel für Port
10000 sperrt also auch SSH.

| Port | Zweck |
|---|---|
| 22 | SSH — Grundlage für den Tunnel |
| 80, 443 | Websites |
| 25 | eingehende Mail |
| 465, 587 | Submission |
| 143, 993 | IMAP |
| ICMP | Diagnose |

**Jede Regel für `0.0.0.0/0` UND `::/0`.** Ist der Host per IPv6 angebunden und
die Regel nur für IPv4 gesetzt, sieht es aus wie ein Totalausfall.

```bash
ssh -4 -v user@host
ssh -6 -v user@host
```

Zusätzlich auf dem Host:

```bash
ufw deny 10000/tcp
ss -tlnp | grep -E '3306|10000'    # von AUSSEN gegenprüfen, nicht lokal
```

---

## 3. SSH

```bash
# /etc/ssh/sshd_config
PasswordAuthentication no
PubkeyAuthentication yes
PermitRootLogin prohibit-password
```

```bash
sshd -t && systemctl reload ssh
```

Dabei eine funktionierende Sitzung offen lassen, bis du dich in einem zweiten
Fenster erfolgreich neu verbunden hast.

Schlüssel erzeugen — auf dem **Arbeitsplatzrechner**, nicht auf dem Server:

```bash
ssh-keygen -t ed25519 -C "arbeitsplatz"
```

Mit Passphrase. Bei Diebstahl des Rechners ist ein ungeschützter Schlüssel
sofort nutzbar.

### Private Schlüssel auf dem Server

Panels legen beim Anlegen einer Domain Schlüsselpaare an — und lassen den
privaten Teil im Home-Verzeichnis liegen:

```bash
for K in /root/.ssh/id_* /home/*/.ssh/id_*; do
  [ -f "$K" ] && [[ "$K" != *.pub ]] || continue
  ssh-keygen -y -P '' -f "$K" >/dev/null 2>&1 && echo "OHNE PASSPHRASE: $K"
done
```

Wer root-Zugriff hatte, konnte diese mitnehmen und sich später als jeder dieser
Benutzer anmelden — ohne dass es in `authorized_keys` auffällt. Auf dem Server
werden sie nicht gebraucht:

```bash
grep -rn 'IdentityFile' /home/*/.ssh/config /root/.ssh/config 2>/dev/null
mkdir -p /root/keys-alt && chmod 700 /root/keys-alt
mv /home/*/.ssh/id_rsa /root/keys-alt/ 2>/dev/null
```

Erst prüfen, ob sie für ausgehende Verbindungen genutzt werden, dann
verschieben — und die zugehörigen `authorized_keys`-Einträge ersetzen.

---

## 4. `.htaccess` ausrollen

```bash
sudo wp-harden-htaccess --inventory     # erst sehen, was vorhanden ist
sudo wp-harden-htaccess                 # Trockenlauf
sudo wp-harden-htaccess --apply
```

Enthalten: Verzeichnisauflistung aus, Sperre für `wp-config.php`, Dumps,
Archive und Punktdateien, **keine PHP-Ausführung in `uploads/`**, XML-RPC
gesperrt, Sicherheits-Header, Schutz gegen Benutzer-Aufzählung.

Der wichtigste Punkt ist die PHP-Sperre in `uploads/`. Eine hochgeladene
PHP-Datei ist der klassische Weg zur Hintertür — und dagegen hilft eine zweite
`.htaccess` direkt in dem Verzeichnis, die auch dann wirkt, wenn die Hauptdatei
überschrieben wird.

> Danach die Permalinks in wp-admin einmal speichern und Login, Medien-Upload
> und Block-Editor kurz testen.

Voraussetzung ist `AllowOverride All`. Ohne das wird die gesamte Datei
stillschweigend ignoriert — das Skript prüft es und macht am Ende einen
Wirksamkeitstest.

---

## 5. Zugangsdaten

```bash
sudo wp-rotate-db-passwords --apply
sudo wp-user-audit --shuffle-salts
```

Dazu von Hand: Panel-root **und alle Domain-Konten**, WordPress-Administratoren,
SSH-Schlüssel.

Nicht vergessen: Dienste, die dieselben Zugangsdaten verwenden — Backup-Skripte,
`~/.my.cnf` der Seitenbenutzer, phpMyAdmin, eigene Cron-Jobs.

---

## 6. Domains sperren

```bash
sudo apply-blocklist dnsmasq --apply
```

Per DNS, nicht per IP — die Domains liegen hinter CDN-Adressen, die mit
tausenden legitimen Seiten geteilt werden.

---

## 7. Laufende Kontrolle

```cron
MAILTO=admin@example.tld
0  6 * * 1 root /usr/local/bin/wp-db-audit --quiet
30 6 * * 1 root /usr/local/bin/wp-asset-scan
```

Nach einem Vorfall zusätzlich engmaschig: nach einer Stunde und am Folgetag.

Und im Blick behalten, wenn auf dem Host ein Mailserver läuft:

```bash
mailq | tail
grep -c 'status=sent' /var/log/mail.log
```

Ein kompromittierter Host wird als Spam-Relais missbraucht — und darüber landet
man auf Blocklisten, was länger nachwirkt als der eigentliche Vorfall.

---

## Dauerhafte Gewohnheiten

- **Keine Dumps im Webverzeichnis.** `--backup` immer außerhalb von
  `public_html`.
- **Keine phar-Dateien im Webroot.** Auch nicht kurz.
- **Nulled-Themes und -Plugins meiden.** Enfold, Divi und Co. aus dem eigenen
  Kundenkonto — Sammelquellen sind ein Standard-Infektionsweg, und ein
  Prüfsummenvergleich ist dagegen wirkungslos.
- **`DISALLOW_FILE_EDIT`** in `wp-config.php`: nimmt dem Datei-Editor im
  Backend die Schärfe.
- **PHP-Version im Panel setzen**, nicht in der `.htaccess`. Dann ist die Datei
  davon unabhängig und ein einheitlicher Stand über alle Seiten erreichbar.
