# Playbook: Vorfall

Ablauf von der ersten Diagnose bis zur Kontrolle am Folgetag. Die Reihenfolge
ist nicht beliebig — Schritt 5 vor 6 und 7 ist der wichtigste Punkt der ganzen
Seite.

---

## 0. Nicht zuerst aufräumen

Der Reflex ist, sofort zu putzen. Sinnvoller ist die Reihenfolge:
**sichern → verstehen → schließen → bereinigen → kontrollieren.**

Wer bereinigt, während der Weg hinein offen ist, macht die Arbeit zweimal —
und verliert dabei die Spuren, die zeigen, wie jemand hereinkam.

```bash
# Beweise sichern, bevor Logs rotieren
mkdir -p /root/forensik-$(date +%F) && chmod 700 /root/forensik-$(date +%F)
cp -a /var/webmin/miniserv.log /var/webmin/webmin.log /root/forensik-$(date +%F)/ 2>/dev/null
cp -a /var/log/apache2/*access*.log /root/forensik-$(date +%F)/ 2>/dev/null
```

---

## 1. Symptom eingrenzen

```bash
curl -s https://DEINE-DOMAIN/ | grep -iE 'http-equiv="refresh"|location\.replace'
curl -sI https://DEINE-DOMAIN/ | grep -i location
```

| Beobachtung | Bedeutung |
|---|---|
| Meta-Refresh oder `location.replace` im HTML | Nutzlast im Seiteninhalt → Datenbank |
| `Location:`-Header | Weiterleitung auf Serverebene → `.htaccess` oder vhost |
| curl sauber, Browser leitet um | Browser-Cache oder Bedingung auf User-Agent |

Bei der letzten Zeile mit mobilem User-Agent gegenprüfen — die Kampagne
zielt auf Touch-Geräte:

```bash
curl -s -A "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) Mobile/15E148" \
  "https://DEINE-DOMAIN/?nocache=$RANDOM" | grep -c 'refresh'
```

---

## 2. Bestandsaufnahme über alle Seiten

```bash
sudo wp-db-audit
sudo wp-asset-scan
sudo wp-cron-list --suspicious
sudo wp-user-audit
```

Alles rein lesend. Notiere pro Seite: Zieldomain, Anzahl betroffener Zeilen,
ob `home`/`siteurl` verbogen sind, ob Dateien betroffen sind.

**Die Zieldomain unterscheidet sich pro Seite.** Trage sie nirgends fest ein —
die Skripte lesen sie selbst aus der Nutzlast.

---

## 3. Trockenlauf der Bereinigung

```bash
sudo wp-cleanup-all
```

Lies die Ausgabe, bevor du weitergehst. Drei Blöcke sind entscheidend:

- **`rows matching the payload pattern`** — Anzahl betroffener Zeilen. 0 heißt
  entweder sauber, oder das Muster passt nicht.
- **`[HIT]`-Zeilen aus Dateisystem und Prüfsummen.** Findet sich dort PHP in
  `uploads` oder eine veränderte Kerndatei, ist es **keine** reine
  Datenbanksache — dann erst die Dateien klären.
- **Treffer in options, postmeta, comments.** Die werden bewusst nicht
  automatisch bereinigt: dort stecken serialisierte Werte, und ein blinder
  Schnitt zerstört die Längenangaben.

---

## 4. Bereinigen

```bash
sudo wp-cleanup-all --apply
sudo wp-asset-scan --apply
```

Vor jeder Änderung wird ein Datenbank-Dump geschrieben. Danach von Hand:

```bash
systemctl reload php8.*-fpm          # opcache leeren
```

Und im Browser: **privates Fenster oder anderes Gerät.** Eine
Meta-Refresh-Seite ist voll cachefähig — nach der Bereinigung leitet der
eigene Browser oft weiter, obwohl der Server sauberes HTML liefert.

---

## 5. Zugang schließen — VOR den Zugangsdaten

Das ist der Punkt, an dem die Reihenfolge zählt. Wer erst die Passwörter
wechselt, sperrt nur sich selbst aus.

```bash
# Webmin nur noch lokal
# /etc/webmin/miniserv.conf:  bind=127.0.0.1
/etc/webmin/restart
ss -tlnp | grep -E '10000|3306'
```

Zugriff danach per SSH-Tunnel:

```bash
ssh -L 10000:127.0.0.1:10000 user@host
```

Im Tunnel **und** im Browser `127.0.0.1` verwenden, nicht `localhost` —
letzteres löst zuerst auf `::1` auf, dort lauscht Webmin nach
`bind=127.0.0.1` nicht mehr. Fehlerbild: `PR_CONNECT_RESET_ERROR`.

Cloud-Firewall nicht vergessen: Sie arbeitet als Default-Deny. Nach dem
Anlegen einer einzigen Regel ist alles andere zu — also 22, 80, 443, 25 und
was du sonst brauchst explizit freigeben, **jede Regel für `0.0.0.0/0` und
`::/0`**.

Details: [Absicherung](Absicherung).

---

## 6. Zugangsdaten wechseln

```bash
sudo wp-rotate-db-passwords            # Trockenlauf
sudo wp-rotate-db-passwords --apply
```

Dazu von Hand: Webmin-root **und alle Panel-Konten**, SSH-Schlüssel,
WordPress-Administratoren.

Prüfe außerdem, ob private SSH-Schlüssel ohne Passphrase auf dem Server
liegen — Panels legen sie beim Anlegen einer Domain dort ab:

```bash
for K in /root/.ssh/id_* /home/*/.ssh/id_*; do
  [ -f "$K" ] && [[ "$K" != *.pub ]] || continue
  ssh-keygen -y -P '' -f "$K" >/dev/null 2>&1 && echo "OHNE PASSPHRASE: $K"
done
```

Wer root-Zugriff hatte, konnte diese Schlüssel mitnehmen. Eine unauffällige
`authorized_keys` ist deshalb allein keine Entwarnung.

---

## 7. Sitzungen beenden

```bash
sudo wp-user-audit --shuffle-salts
```

Erneuert die `AUTH_KEY`/`SALT`-Konstanten. Jede bestehende Anmeldung wird
ungültig — auch deine eigene. Passwörter ändert es nicht.

---

## 8. Domains sperren

```bash
sudo apply-blocklist dnsmasq --apply
apply-blocklist scan
```

Per DNS sperren, nicht per IP: Die Domains liegen hinter CDN-Adressen, die
mit tausenden legitimen Seiten geteilt werden.

---

## 9. Kontrolllauf

Nach einer Stunde und am Folgetag:

```bash
sudo wp-db-audit --quiet
sudo wp-asset-scan
```

**Steigt die Fundzahl wieder von 0 auf mehr, besteht der Zugang weiter.** Dann
nicht erneut bereinigen, sondern die Seite offline nehmen:

```bash
a2dissite DEINE-SEITE.conf && systemctl reload apache2
```

---

## Wann Neuaufbau

Prüfe die Panel-Protokolle auf fremde Sitzungen:

```bash
grep -iE 'record-login|record-failed' /var/webmin/webmin.log | tail -40
grep -a -oE '"(GET|POST) [^ ?]+' /var/webmin/miniserv.log | sort | uniq -c | sort -rn | head -20
```

Achte auf `/xterm/`, `/filemin/`, `/shell/` — eine Browser-Shell bedeutet
root-Zugriff, und deren Eingaben stehen in **keinem** Log. Was in dieser Zeit
geschah, lässt sich nicht rekonstruieren.

In dem Fall ist die ehrliche Konsequenz ein Neuaufbau: neuer Host, frisches
System, **Inhalte** aus Sicherungen zurückspielen — Datenbankinhalte und
Uploads, keine ausführbaren Dateien. Kern, Themes und Plugins aus den
Originalquellen neu holen.

Eine Bereinigung im laufenden System ist dann eine Wette darauf, dass man
alles gefunden hat.
