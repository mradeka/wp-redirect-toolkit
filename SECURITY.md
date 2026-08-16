# Sicherheitshinweise

## Was diese Skripte tun — und was das bedeutet

Dieses Toolkit greift tief in produktive Systeme ein: Es liest und schreibt
WordPress-Datenbanken, ändert `wp-config.php`, rotiert Datenbankpasswörter und
löscht Dateien. Es ist für den Einsatz auf Servern gedacht, die man selbst
verwaltet.

Alle schreibenden Skripte laufen ohne `--apply` als Trockenlauf und legen vor
jeder Änderung eine Sicherung an. Das ersetzt kein eigenes Backup außerhalb
des Servers.

## Zwei Dateien mit besonderem Schutzbedarf

- **`/root/wp-db-credentials.txt`** — wird von `wp-rotate-db-passwords`
  angelegt und enthält Datenbankpasswörter im Klartext. Modus 600, gehört
  root, und darf niemals in ein Repository, ein Ticket oder ein weitergegebenes
  Backup gelangen. Die mitgelieferte `.gitignore` schließt sie aus.
- **`/root/wp-cleanup-logs/`** — Protokolle der Bereinigungsläufe. Sie können
  Pfade, Benutzernamen und Zieldomains enthalten.

## Eine Schwachstelle melden

Wenn du in diesen Skripten ein Sicherheitsproblem findest — etwa eine
Befehlsinjektion über einen Dateinamen, eine unsichere temporäre Datei oder
eine Rechteausweitung — melde es bitte **nicht** über ein öffentliches Issue.

Nutze stattdessen die private Meldefunktion von GitHub:
`Security` → `Report a vulnerability`.

Bitte gib an:

- welches Skript und welche Version betroffen sind
- wie sich das Problem reproduzieren lässt
- was ein Angreifer damit erreichen könnte

## Was hier nicht hingehört

Dieses Repository ist kein Meldeweg für kompromittierte WordPress-Seiten.
Wenn deine eigene Website betroffen ist, hilft dir die
[WordPress-Support-Community](https://wordpress.org/support/) weiter.

## Zu den Angreiferdomains

`blocklist-domains.txt` enthält Domains einer beobachteten Kampagne. Sie sind
zum Sperren gedacht — rufe sie nicht im Browser auf. Falls eine Domain den
Besitzer gewechselt hat und zu Unrecht auf der Liste steht, ist ein Issue der
richtige Weg.
