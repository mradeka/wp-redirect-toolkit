# Schnellstart

Drei Befehle, die **nichts verändern**. Danach weißt du, ob und wo etwas nicht
stimmt.

---

## 1. Installieren

```bash
git clone https://github.com/mradeka/wp-redirect-toolkit.git
cd wp-redirect-toolkit
chmod +x install.sh
sudo ./install.sh
```

`install.sh` prüft anschließend selbst, ob Bash, PHP, MySQL-Client, curl und
WP-CLI vorhanden sind, und meldet, was fehlt. Details und Sonderfälle:
[INSTALL.md](https://github.com/mradeka/wp-redirect-toolkit/blob/main/INSTALL.md).

> **WP-CLI 2.7 oder neuer.** Ältere Versionen liefern bei `--fields` zusammen
> mit `--format=csv` keine Ausgabe. Die Skripte fangen das mit einer
> Rückfallebene ab und weisen darauf hin, aber ein Update erspart mehrere
> Sonderfälle:
> ```bash
> curl -fL -o /tmp/wp-cli.phar https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
> sudo install -m 755 /tmp/wp-cli.phar /usr/local/bin/wp
> ```
> Beachte das Repository: **`wp-cli/builds`**, nicht `wp-cli/wp-cli`.

---

## 2. Können alle Konten die Werkzeuge nutzen?

```bash
sudo check-usrlocalbin-access
```

Die Bereinigung läuft bewusst als **Seitenbenutzer**, nicht als root — sonst
entstehen root-eigene Dateien, die später die Theme-CSS-Generierung blockieren.

Steht in der Spalte `run` ein `NEIN`, obwohl `exec` in Ordnung ist, beschränkt
`open_basedir` das Konto auf sein Home. Abhilfe:

```bash
find /home -maxdepth 4 -name wp-config.php 2>/dev/null | while read -r C; do
  U=$(stat -c '%U' "$C"); H=$(getent passwd "$U" | cut -d: -f6)
  [ -d "$H" ] && install -m 755 -o "$U" -g "$(id -gn "$U")" /usr/local/bin/wp "${H}/wp"
done
```

---

## 3. Bestandsaufnahme

```bash
sudo wp-db-audit        # Datenbank: Cron-Hooks, Nutzlast, URLs, Konten
sudo wp-asset-scan      # Dateisystem: JS, Landeseiten, Loader, Prüfsummen
```

Beide ändern nichts. `wp-db-audit` gibt 0 zurück, wenn alles sauber ist, und 1
bei Funden — damit eignet es sich direkt für cron.

**Was jetzt?**

| Ergebnis | Nächster Schritt |
|---|---|
| Beide sauber | [Absicherung](Absicherung) — damit es so bleibt |
| Funde gemeldet | [Playbook: Vorfall](Playbook-Vorfall) |
| Meldung sieht harmlos aus | [Bekannte Fehlalarme](Fehlalarme) |
| Ein Befehl schlägt fehl | [Fehlerbehebung](Fehlerbehebung) |

---

## Regelmäßige Kontrolle

```cron
# /etc/cron.d/wp-toolkit
MAILTO=admin@example.tld
0  6 * * 1 root /usr/local/bin/wp-db-audit --quiet
30 6 * * 1 root /usr/local/bin/wp-asset-scan
```

Meldet sich nur, wenn es etwas zu melden gibt.
