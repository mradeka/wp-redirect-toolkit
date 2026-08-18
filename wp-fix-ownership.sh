#!/usr/bin/env bash
#
# wp-fix-ownership.sh
#
# Prueft Eigentuemer und Rechte aller WordPress-Installationen unter
# /home/<benutzer>/public_html[/wordpress] und bietet danach eine Auswahl an,
# welche Seiten korrigiert werden sollen.
#
# Hintergrund: Laeuft ein "wp core download", ein Update oder ein Skript
# versehentlich als root, gehoeren die Dateien danach root. Symptome:
#
#   - WordPress fragt bei Aktualisierungen nach FTP-Zugangsdaten
#     (der PHP-Prozess ist nicht Eigentuemer -> get_filesystem_method()
#      liefert 'ftpext' statt 'direct')
#   - Medien-Uploads scheitern, wenn uploads/ betroffen ist
#   - Themes koennen ihre generierten Stylesheets nicht schreiben
#     (z. B. uploads/dynamic_avia/) - die Seite verliert ihre Formatierung
#
# Uploads und Updates koennen dabei unabhaengig voneinander brechen: fuer
# Uploads genuegt Schreibrecht in uploads/, fuer Updates muss der gesamte
# Kern dem Seitenbenutzer gehoeren.
#
# Aendert nichts ohne Auswahl und Bestaetigung.
#
# Usage:
#   ./wp-fix-ownership.sh              # pruefen, dann interaktiv auswaehlen
#   ./wp-fix-ownership.sh --report     # nur pruefen, keine Auswahl
#   ./wp-fix-ownership.sh --all --yes  # alle betroffenen ohne Rueckfrage
#   ./wp-fix-ownership.sh --only siteuser
#   ./wp-fix-ownership.sh --no-chmod   # nur Eigentuemer, Rechte unveraendert

set -uo pipefail

ONLY=""
REPORT=0
ALL=0
ASSUME_YES=0
DO_CHMOD=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --report)   REPORT=1; shift ;;
    --all)      ALL=1; shift ;;
    --yes)      ASSUME_YES=1; shift ;;
    --only)     ONLY="$2"; shift 2 ;;
    --no-chmod) DO_CHMOD=0; shift ;;
    -h|--help)  sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "Unbekannte Option: $1"; exit 1 ;;
  esac
done

[[ $EUID -ne 0 ]] && { echo "Bitte als root ausfuehren."; exit 1; }

hr()   { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { printf '\033[32m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*"; }
bad()  { printf '\033[31m%s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. Pruefen
# ---------------------------------------------------------------------------
hr "Pruefe Installationen"

mapfile -t CONFIGS < <(
  ls -d /home/*/public_html/wordpress/wp-config.php \
        /home/*/public_html/wp-config.php 2>/dev/null | sort -u
)
[[ ${#CONFIGS[@]} -eq 0 ]] && { echo "Keine WordPress-Installationen gefunden."; exit 0; }

declare -a PATHS=() USERS=() GROUPS=() COUNTS=() DETAILS=()
IDX=0

printf '\n  %-3s %-20s %8s  %-9s %s\n' "Nr" "Benutzer" "fremd" "Bereich" "Pfad"
printf '  %s\n' "---------------------------------------------------------------------------------------"

for CONFIG in "${CONFIGS[@]}"; do
  D=$(dirname "$CONFIG")
  U=$(stat -c '%U' "$CONFIG")
  G=$(stat -c '%G' "$CONFIG")
  [[ -n "$ONLY" && "$U" != "$ONLY" ]] && continue

  N=$(find "$D" ! -user "$U" 2>/dev/null | wc -l)

  # Wo genau sitzt das Problem? Das entscheidet, welches Symptom auftritt.
  N_CORE=$(find "$D" -maxdepth 1 ! -user "$U" 2>/dev/null | wc -l)
  N_ADMIN=$(find "$D/wp-admin" "$D/wp-includes" ! -user "$U" 2>/dev/null | wc -l)
  N_UP=$(find "$D/wp-content/uploads" ! -user "$U" 2>/dev/null | wc -l)
  N_CONT=$(find "$D/wp-content" -maxdepth 1 ! -user "$U" 2>/dev/null | wc -l)

  BEREICH=""
  [[ "$N_ADMIN" -gt 0 || "$N_CORE" -gt 0 ]] && BEREICH="Kern"
  [[ "$N_UP"    -gt 0 ]] && BEREICH="${BEREICH:+$BEREICH+}uploads"
  [[ "$N_CONT"  -gt 0 && -z "$BEREICH" ]] && BEREICH="content"
  [[ -z "$BEREICH" && "$N" -gt 0 ]] && BEREICH="sonstige"
  [[ "$N" -eq 0 ]] && BEREICH="-"

  # fremde Eigentuemer namentlich, das sagt oft schon, wer es war
  OWNERS=$(find "$D" ! -user "$U" -printf '%u\n' 2>/dev/null | sort -u | tr '\n' ' ')

  IDX=$((IDX+1))
  PATHS+=("$D"); USERS+=("$U"); GROUPS+=("$G"); COUNTS+=("$N")
  DETAILS+=("Kern:${N_ADMIN} uploads:${N_UP} content:${N_CONT} Eigentuemer:${OWNERS:-–}")

  if [[ "$N" -eq 0 ]]; then
    printf '  %-3s %-20s \033[32m%8s\033[0m  %-9s %s\n' "$IDX" "$U" "$N" "$BEREICH" "$D"
  else
    printf '  %-3s %-20s \033[31m%8s\033[0m  %-9s %s\n' "$IDX" "$U" "$N" "$BEREICH" "$D"
    printf '      %s\n' "${DETAILS[$((IDX-1))]}"
  fi
done

BETROFFEN=()
for i in "${!COUNTS[@]}"; do
  [[ "${COUNTS[$i]}" -gt 0 ]] && BETROFFEN+=("$i")
done

hr "Ergebnis"
if [[ ${#BETROFFEN[@]} -eq 0 ]]; then
  ok "  Alle ${IDX} Installationen gehoeren dem jeweiligen Seitenbenutzer."
  echo "  Uploads und Aktualisierungen sollten ohne FTP-Abfrage funktionieren."
  exit 0
fi

bad "  ${#BETROFFEN[@]} von ${IDX} Installation(en) mit fremden Eigentuemern."
cat <<'ERKL'

  Zur Einordnung:
    Kern betroffen     -> Aktualisierungen fragen nach FTP-Zugangsdaten
    uploads betroffen  -> Medien-Uploads scheitern
    beides moeglich    -> unabhaengig voneinander, je nach Bereich
ERKL

[[ $REPORT -eq 1 ]] && { echo; echo "  (--report: keine Aenderung)"; exit 1; }

# ---------------------------------------------------------------------------
# 2. Auswahl
# ---------------------------------------------------------------------------
AUSWAHL=()
if [[ $ALL -eq 1 ]]; then
  AUSWAHL=("${BETROFFEN[@]}")
  warn "  --all: alle betroffenen Installationen ausgewaehlt"
else
  hr "Auswahl"
  echo "  Zu korrigierende Nummern eingeben:"
  echo "    einzeln    2 5 7"
  echo "    Bereich    2-5"
  echo "    alle       a"
  echo "    abbrechen  q  (oder leer)"
  echo
  printf '  betroffen: '
  for i in "${BETROFFEN[@]}"; do printf '%s ' "$((i+1))"; done; echo
  echo
  read -r -p "  Auswahl: " EINGABE

  [[ -z "$EINGABE" || "${EINGABE,,}" == "q" ]] && { echo "  abgebrochen"; exit 0; }

  if [[ "${EINGABE,,}" == "a" ]]; then
    AUSWAHL=("${BETROFFEN[@]}")
  else
    for TOKEN in $EINGABE; do
      if [[ "$TOKEN" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        for ((n=${BASH_REMATCH[1]}; n<=${BASH_REMATCH[2]}; n++)); do
          [[ "$n" -ge 1 && "$n" -le "$IDX" ]] && AUSWAHL+=("$((n-1))")
        done
      elif [[ "$TOKEN" =~ ^[0-9]+$ ]]; then
        if [[ "$TOKEN" -ge 1 && "$TOKEN" -le "$IDX" ]]; then
          AUSWAHL+=("$((TOKEN-1))")
        else
          warn "  ignoriert: ${TOKEN} (ausserhalb 1-${IDX})"
        fi
      else
        warn "  ignoriert: ${TOKEN}"
      fi
    done
  fi
fi

# Duplikate entfernen
mapfile -t AUSWAHL < <(printf '%s\n' "${AUSWAHL[@]:-}" | grep -E '^[0-9]+$' | sort -un)
[[ ${#AUSWAHL[@]} -eq 0 ]] && { echo "  nichts ausgewaehlt"; exit 0; }

# ---------------------------------------------------------------------------
# 3. Bestaetigen
# ---------------------------------------------------------------------------
hr "Wird korrigiert"
for i in "${AUSWAHL[@]}"; do
  printf '  %-20s %6s Datei(en)  %s\n' "${USERS[$i]}" "${COUNTS[$i]}" "${PATHS[$i]}"
done
echo
echo "  chown -R <benutzer>:<gruppe> auf das Installationsverzeichnis"
if [[ $DO_CHMOD -eq 1 ]]; then
  echo "  chmod 755 fuer Verzeichnisse, 644 fuer Dateien, 640 fuer wp-config.php"
  warn "  Achtung: eigene Skripte mit Ausfuehrungsbit verlieren es dabei."
  warn "  Mit --no-chmod nur den Eigentuemer setzen."
else
  echo "  Rechte bleiben unveraendert (--no-chmod)"
fi

if [[ $ASSUME_YES -eq 0 ]]; then
  echo
  read -r -p "  Ausfuehren? [y/N] " ANS
  [[ "${ANS,,}" == "y" ]] || { echo "  abgebrochen"; exit 0; }
fi

# ---------------------------------------------------------------------------
# 4. Korrigieren
# ---------------------------------------------------------------------------
hr "Korrektur"
FEHLER=0
for i in "${AUSWAHL[@]}"; do
  D="${PATHS[$i]}"; U="${USERS[$i]}"; G="${GROUPS[$i]}"
  printf '  %s ... ' "$D"

  # Ausfuehrbare Dateien vorher festhalten, damit sie sich nachvollziehen
  # lassen, falls chmod etwas plattmacht
  EXECS=$(find "$D" -type f -perm -u+x 2>/dev/null | head -50)
  [[ -n "$EXECS" ]] && {
    LOG="/root/wp-fix-ownership-execs-$(basename "$(dirname "$D")")-$(date +%F-%H%M%S).txt"
    echo "$EXECS" > "$LOG"
  }

  if ! chown -R "$U:$G" "$D" 2>/dev/null; then
    bad "chown fehlgeschlagen"; FEHLER=$((FEHLER+1)); continue
  fi

  if [[ $DO_CHMOD -eq 1 ]]; then
    find "$D" -type d -exec chmod 755 {} + 2>/dev/null
    find "$D" -type f -exec chmod 644 {} + 2>/dev/null
    [[ -f "$D/wp-config.php" ]] && chmod 640 "$D/wp-config.php"
  fi

  REST=$(find "$D" ! -user "$U" 2>/dev/null | wc -l)
  if [[ "$REST" -eq 0 ]]; then
    ok "ok"
    [[ -n "${LOG:-}" ]] && printf '      vorher ausfuehrbare Dateien notiert in %s\n' "$LOG"
  else
    bad "noch ${REST} fremde Datei(en) - von Hand pruefen"
    FEHLER=$((FEHLER+1))
  fi
  unset LOG
done

# ---------------------------------------------------------------------------
# 5. Nachkontrolle
# ---------------------------------------------------------------------------
hr "Nachkontrolle"
for i in "${AUSWAHL[@]}"; do
  D="${PATHS[$i]}"; U="${USERS[$i]}"
  WPBIN=""
  for CAND in "/home/${U}/wp" "/home/${U}/.wp-cli.phar" /usr/local/bin/wp; do
    sudo -u "$U" -H test -r "$CAND" 2>/dev/null && { WPBIN="$CAND"; break; }
  done
  [[ -z "$WPBIN" ]] && continue
  M=$(sudo -u "$U" -H "$WPBIN" --path="$D" --skip-plugins --skip-themes eval \
        'require_once ABSPATH."wp-admin/includes/file.php"; echo get_filesystem_method();' 2>/dev/null)
  case "$M" in
    direct) printf '  %-20s \033[32mdirect\033[0m - Aktualisierungen ohne FTP-Abfrage\n' "$U" ;;
    "")     printf '  %-20s (nicht ermittelbar)\n' "$U" ;;
    *)      printf '  %-20s \033[31m%s\033[0m - fragt weiter nach Zugangsdaten\n' "$U" "$M" ;;
  esac
done

cat <<'NEXT'

  Noch pruefen:
    - Aktualisierung im Backend anstossen (darf nicht nach FTP fragen)
    - Medien-Upload testen
    - bei Enfold/Divi: generierte Stylesheets neu erzeugen lassen
      (Enfold -> Performance -> "Delete old CSS and JS files", dann speichern)

  Tauchen nach dem naechsten Update erneut fremde Eigentuemer auf, lief das
  Update selbst als root - dann liegt die Ursache in einem Cron-Job oder einem
  Panel-Vorgang, nicht in Handarbeit.
NEXT

exit $FEHLER
