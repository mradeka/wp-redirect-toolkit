# FAQ

---

## Zur Benutzung

### Kann ich die Skripte gefahrlos ausprobieren?

Ja. Ohne `--apply` verändern sie nichts. `wp-db-audit`,
`check-usrlocalbin-access` und `wp-cron-list` (ohne `--delete`) schreiben
grundsätzlich nie.

Vor jeder schreibenden Aktion wird gesichert — Datenbank-Dump, Dateikopie oder
beides.

### Warum muss ich `--domain` nicht angeben?

Weil die Zieldomain sich pro Seite unterscheidet. Im untersuchten Fall trugen
drei Installationen drei verschiedene Domains derselben Kampagne. Mit fest
vorgegebener Domain meldet ein Scan betroffene Seiten fälschlich als sauber —
deshalb liest das Skript sie aus der Nutzlast selbst.

### Warum als Seitenbenutzer und nicht als root?

Weil root-eigene Dateien später Probleme machen. Konkret: Enfold erzeugt seine
Stylesheets nach `wp-content/uploads/dynamic_avia/`. Gehört dieses Verzeichnis
plötzlich root, kann das Theme dort nicht mehr schreiben — und die Seite
verliert ihre Formatierung, ohne dass ein Fehler erscheint.

### Meine Seite leitet nach der Bereinigung immer noch um.

In dieser Reihenfolge prüfen:

```bash
curl -s https://DOMAIN/ | grep -c 'SCHADDOMAIN'
```

Ist das 0, liefert der Server sauberes HTML — dann ist es dein Browser-Cache.
Eine Meta-Refresh-Seite ist voll cachefähig. Privates Fenster oder anderes
Gerät.

Ist es größer als 0, siehe [Fehlerbehebung](Fehlerbehebung).

### Kann ich einen Lauf rückgängig machen?

| Skript | Rückweg |
|---|---|
| `wp-redirect-cleanup` | `wp db import` des Dumps aus dem `--backup`-Verzeichnis |
| `wp-harden-htaccess` | `wp-harden-htaccess --restore` |
| `wp-asset-scan` | `.bak-<zeitstempel>` neben der Datei |
| `wp-rotate-db-passwords` | rollt bei Fehlschlag selbst zurück; alte Passwörter stehen in `/root/wp-db-credentials.txt` |
| `wp-move-to-subdir` | Tarball und Dump im `tmp/` des Seitenbenutzers |

---

## Zu den Entscheidungen

### Warum werden nicht alle Funde automatisch bereinigt?

Weil ein gemeldeter Fund zu viel harmloser ist als eine gelöschte Datei zu
wenig. Automatisch bereinigt wird nur, was eindeutig ist: die bekannte Nutzlast
in `post_content`, JS-Zeilen mit einer Domain aus der Sperrliste, Wegwerf-Typen
in der Datenbank.

Nicht automatisch: serialisierte Werte in `wp_options`, `postmeta` und
`comments` — dort zerstört ein blinder Schnitt die Längenangaben. Ebensowenig
HTML- und PHP-Dateien, die auch legitim sein können.

### Warum löscht `wp-user-audit` nicht einfach alle Konten, deren Name nicht zum Verzeichnis passt?

Weil das zu viel trifft. Ein WordPress-Login hat keinen Zusammenhang mit dem
Systemkonto: Redakteure, Autoren und Shop-Kunden heißen nie wie das
Home-Verzeichnis. Und `wp user delete` nimmt deren Beiträge mit.

Stattdessen ein Punktesystem aus Rolle, Registrierungsdatum, Mail-Domain,
Beitragszahl und Namensform. Konten mit eigenen Inhalten werden ohne
`--reassign` grundsätzlich übersprungen.

### Warum löscht `wp-harden-htaccess` bestehende Dateien nicht einfach?

Weil bei fcgid-Sites die PHP-Version in der `.htaccess` steht
(`AddHandler fcgid-script .php`). Fällt die Zeile weg, läuft die Seite mit der
Server-Vorgabe — oder PHP wird gar nicht mehr ausgeführt und der Browser lädt
den Quelltext herunter.

Umgekehrt wird auch nicht blind alles übernommen: Nach einem Vorfall kann dort
eine eingeschleuste Regel stehen. Deshalb wird jede Zeile klassifiziert;
`--inventory` zeigt das Ergebnis.

### Warum zwei Prüfskripte statt einem?

Die Trennung folgt der Datenquelle: `wp-db-audit` fragt die Datenbank,
`wp-asset-scan` sieht sich Dateien an. Früher war beides in einem Skript
namens `wp-cron-audit` — der Name versprach Cron und lieferte alles.

Beide zusammen ergeben das vollständige Bild. Läuft nur eines, bleibt der
jeweils andere Infektionsweg unentdeckt.

### Warum wird der WordPress-Kern nicht nach Schadmustern durchsucht?

Weil `verify-checksums` die bessere Antwort ist: ein Bytevergleich gegen das
Original statt einer Mustersuche. Fast alle behobenen Fehlalarme entstanden
dadurch, dass Verzeichnisse durchsucht wurden, deren Integrität ohnehin
feststellbar ist — siehe [Fehlalarme](Fehlalarme).

---

## Zur Lage

### Reicht Bereinigen, oder muss der Server neu?

Das hängt daran, wie weit der Zugriff reichte.

**Bereinigen ist vertretbar**, wenn alles auf Datenbankzugriff hindeutet: keine
veränderten Dateien, saubere Prüfsummen, keine mu-plugins, keine fremden Konten
— und die Kontrollläufe danach bleiben bei 0.

**Neuaufbau ist die ehrliche Konsequenz**, wenn die Panel-Protokolle eine
fremde Sitzung mit Browser-Shell zeigen (`/xterm/`, `/filemin/`, `/shell/`).
Deren Eingaben stehen in keinem Log; was in dieser Zeit geschah, lässt sich
nicht rekonstruieren.

Dann: neuer Host, frisches System, **Inhalte** zurückspielen — Datenbankinhalte
und Uploads, keine ausführbaren Dateien. Kern, Themes und Plugins aus den
Originalquellen.

### Woran erkenne ich, dass der Zugang noch besteht?

Am Kontrolllauf. Steigt die Fundzahl von 0 wieder auf mehr, ist jemand noch
drin. Dann nicht erneut bereinigen, sondern die Seite offline nehmen:

```bash
a2dissite DEINE-SEITE.conf && systemctl reload apache2
```

Cron-Hooks sind ein guter Frühindikator: Sie kommen innerhalb einer Stunde
zurück, wenn Code sie neu anlegt.

### Muss ich meine Besucher informieren?

Das ist eine Rechtsfrage, keine technische. In der EU kann eine Meldepflicht
nach DSGVO Art. 33/34 bestehen, wenn personenbezogene Daten betroffen sind —
und bei einem Datenbankzugriff auf `wp_users` sind sie das in der Regel. Die
Frist ist kurz (72 Stunden ab Kenntnis).

Ob das in deinem Fall greift, kann dir nur jemand mit juristischem Blick auf
den konkreten Sachverhalt sagen. Für die Bewertung hilfreich: Welche Tabellen
waren betroffen, gab es Shop- oder Formulardaten, wie lange bestand der
Zugriff.

---

## Zum Projekt

### Kann ich das für andere Kampagnen nutzen?

Teilweise. Die generischen Prüfungen — Cron-Hooks mit Zufallsnamen,
`home`/`siteurl`-Abgleich, Prüfsummen, PHP an falschen Orten, `auto_prepend` —
sind kampagnenunabhängig.

Die Bereinigung ist auf das beschriebene Nutzlastmuster zugeschnitten. Bei
anderem Aufbau greifen die Schnitte nicht, und die Skripte melden das ehrlich,
statt etwas Falsches zu tun.

### Wie melde ich einen Fehlalarm?

[Issue eröffnen](https://github.com/mradeka/wp-redirect-toolkit/issues) mit
Skript, Meldung, Pfad und — falls bekannt — der Begründung, warum die Datei
legitim ist. Das ist die nützlichste Art von Rückmeldung; jeder Eintrag im
Fehlalarm-Katalog hat zu einer Verbesserung geführt.

### Läuft das auch ohne Virtualmin/Webmin?

Ja. Die einzige Annahme ist der Pfad
`/home/<benutzer>/public_html[/wordpress]`. Panel-spezifisch sind nur einzelne
Hinweise in der Ausgabe.
