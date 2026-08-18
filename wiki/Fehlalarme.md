# Bekannte Fehlalarme

Alle hier aufgeführten Fälle sind **harmlos**. Sie stehen hier, weil sie
während der Entwicklung tatsächlich gemeldet wurden — jeder Eintrag hat zu
einer Verbesserung geführt.

Das Muster dahinter ist immer dasselbe: eine Namens- oder Mustersuche über
Verzeichnisse, deren Integrität sich auch per Prüfsumme feststellen lässt.
Deshalb gilt inzwischen: **Prüfsumme vor Mustersuche.**

---

## Der Universaltest

Bevor du eine Datei liest, frag zuerst, ob sie überhaupt vom Original
abweicht:

```bash
sudo -u SITEUSER -H wp --path=/pfad/zur/installation core verify-checksums
sudo -u SITEUSER -H wp --path=/pfad/zur/installation plugin verify-checksums --all
sudo -u SITEUSER -H wp --path=/pfad/zur/installation theme  verify-checksums --all
```

Meldet das zu deiner Datei nichts, ist sie byteidentisch mit dem Original —
dann brauchst du den Inhalt gar nicht zu bewerten.

**Ausnahmen:** Übersetzungen und gekaufte Erweiterungen haben keine
Prüfsummen. Dazu unten mehr.

---

## `page-coming-soon.php` im Theme

```
wp-content/themes/twentytwentyfive/patterns/page-coming-soon.php
wp-content/themes/twentytwentyfive/assets/images/coming-soon-bg-image.webp
```

**Legitim.** Das Standardtheme bringt ein eigenes Block-Muster „Coming soon"
mit. Erkennbar an `@package WordPress` im Kopf, `Slug:`- und
`Categories:`-Angaben sowie Gutenberg-Blockmarkup mit `esc_html_e()`.

Eine gefälschte Landeseite der Kampagne enthält stattdessen eine
Weiterleitung.

*Behoben:* Theme-, Plugin-, `wp-includes`- und `wp-admin`-Verzeichnisse sind
ausgenommen, und die Datei muss tatsächlich eine Weiterleitung enthalten.

---

## `index.php` bei Unterverzeichnis-Installationen

```
Warning: File doesn't verify against checksums: index.php
```

**Legitim und dauerhaft.** Beim Layout „WordPress in eigenem Verzeichnis" zeigt
der `require`-Pfad im Loader auf das Kernverzeichnis:

```php
require __DIR__ . '/wordpress/wp-blog-header.php';
```

Die Prüfsumme kann dort nie stimmen.

> **Auf keinen Fall** mit `wp core download --force` überschreiben — das macht
> die Anpassung rückgängig und die Seite ist nicht mehr erreichbar.

*Behoben:* Prüfsummen laufen gegen das Installationsverzeichnis, der Loader
wird inhaltlich bewertet. Als Befund gilt: verschleiernde Konstrukte,
Nachladen aus dem Netz, `header("Location: …")`, ein `include` auf etwas
anderes als `wp-blog-header.php`/`wp-load.php`/`wp-settings.php`, oder mehr
als 15 Zeilen Code.

---

## `class-pclzip.php` im Kern

```
wp-admin/includes/class-pclzip.php
```

**Legitim.** Die mitgelieferte ZIP-Bibliothek. `gzinflate`/`gzdeflate` sind
ihre eigentliche Aufgabe, und das gefundene `eval(` steht in einer
**auskommentierten** Zeile aus alten Versionen.

*Behoben:* Der Kern wird nicht mehr nach Verschleierung durchsucht — er ist
durch Prüfsummen abgedeckt. Gesucht wird nur in `wp-content/`, und Befund ist
die *Kombination* aus Ausführung und Verschleierung
(`eval(base64_decode(…))`), nicht die Einzelfunktion.

---

## `class-wp-filesystem-*.php` / `file.php` im Kern

**Legitim.** `base64_decode` dient dort der **Verifikation**: MD5-Prüfsummen
liegen base64-kodiert vor, und Paketsignaturen werden per ED25519 geprüft.
`base64_encode` erzeugt HTTP-Basic-Auth-Header für Loopback-Anfragen.

Das ist das Gegenteil von Verschleierung.

---

## `*.l10n.php` unter `wp-content/languages/`

```
wp-content/languages/admin-de_DE.l10n.php
```

**Legitim.** Seit WordPress 6.5 werden Sprachpakete zusätzlich im PHP-Format
ausgeliefert, weil das schneller lädt als `.mo`. Die Datei besteht
ausschließlich aus `return [...]` mit Übersetzungspaaren; erkennbar an
`'x-generator'=>'GlotPress/…'`.

*Behoben:* `.l10n.php` wird übersprungen, ebenso andere Dateien dort, die nur
ein `return`-Array enthalten. Eine PHP-Datei unter `languages/`, die
tatsächlich Code ausführt, wird weiterhin gemeldet.

**Achtung:** Übersetzungen sind **nicht** von `core verify-checksums`
abgedeckt. Bei Zweifeln neu beziehen:

```bash
wp language core update
wp language plugin update --all
```

---

## `view_*.php` unter `wp-content/cache/`

```
wp-content/cache/view_<hash>.php    →  "WP Super Cache Log Viewer"
```

**Legitim, aber unerwünscht.** WP Super Cache erzeugt diesen Debug-Log-Viewer,
wenn das Debugging in den Plugin-Einstellungen eingeschaltet ist.

Warum er trotzdem weg sollte: Das zugehörige Logfile protokolliert **Cookies
und Serverpfade** mit. Außerdem verknüpft die Zugangsprüfung Benutzername und
Passwort mit `&&` — eine der beiden Angaben genügt.

```bash
# Debugging in Einstellungen → WP Super Cache → Debug abschalten, dann:
rm -f wp-content/cache/view_*.php wp-content/cache/<hash>.php
```

Diese Meldung ist **richtig** — `wp-content/cache` wird bewusst nicht
ausgenommen. Ergebnis der Prüfung: legitim, aber abschalten.

---

## „File should not exist" im Kern

```
Warning: File should not exist: wp-includes/js/dist/…/latex-to-mathml.js
Success: WordPress installation verifies against checksums.
```

**Meist legitim.** Beachte die letzte Zeile: Keine Datei ist *verändert*. Die
Warnungen betreffen Dateien, die *vorhanden* sind, aber nicht in der
Prüfsummenliste dieser Version stehen.

Typische Ursachen: eine Entwicklungs- oder RC-Version, oder Reste eines
Versionswechsels. Prüfen:

```bash
wp core version --extra
```

Trotzdem nicht ungeprüft lassen — eine Hintertür erschiene in derselben
Kategorie. Verdächtig sind nur PHP-Dateien:

```bash
grep -rlE 'eval\(|base64_decode|\$_(GET|POST|REQUEST|COOKIE)' \
  wp-includes/assets/ wp-includes/blocks/*/*.asset.php 2>/dev/null
```

`*.asset.php` enthält normalerweise nur ein `return array(...)`.

---

## Gekaufte Themes und Plugins

```
Warning: Could not retrieve the checksums for version 7.1 of theme enfold, skipping.
```

**Kein Fehler — aber auch keine Entwarnung.** Enfold, Divi, Avada, WP Rocket,
ACF Pro und Ähnliches stehen nicht im offiziellen Verzeichnis und werden
deshalb **nicht geprüft**.

Das Skript unterdrückt diese Meldung bewusst nicht, sondern listet die
betroffenen Erweiterungen auf. Bei Verdacht hilft nur der Vergleich:

```bash
diff -rq wp-content/themes/enfold/ /pfad/zum/entpackten/original/enfold/
```

> Das Original aus dem **eigenen Kundenkonto** laden, niemals aus einer
> Sammelquelle. Nulled-Versionen sind ein Standard-Infektionsweg — ein `diff`
> dagegen würde die Kompromittierung bestätigen statt widerlegen.

---

## Was **kein** Fehlalarm ist

| Fund | Warum ernst nehmen |
|---|---|
| PHP-Datei in `wp-content/uploads/` | Dort gehört nie ausführbarer Code hin |
| `auto_prepend_file` in `.htaccess` oder `.user.ini` | Lädt Code bei **jedem** Aufruf |
| mu-plugins, die du nicht kennst | Werden immer geladen, ohne Aktivierung |
| Cron-Hook mit Zufallsnamen | Kein Plugin benennt Hooks so |
| `"//https://` in einer JS-Datei | So schreibt kein Entwickler eine URL |
| `home` und `siteurl` auf verschiedenen Hosts | Klassisches Zeichen einer Kaperung |
| Datenbank-Dump im Webverzeichnis | Enthält Passwort-Hashes, per Browser abrufbar |

---

## Neuen Fehlalarm melden

[Issue eröffnen](https://github.com/mradeka/wp-redirect-toolkit/issues) mit:

- welchem Skript und welcher Meldung
- dem Pfad (Domain und Benutzername gerne ersetzt)
- warum die Datei legitim ist, falls bekannt
