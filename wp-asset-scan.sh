#!/usr/bin/env bash
#
# wp-asset-scan.sh
#
# Sucht die DATEIBASIERTEN Infektionswege derselben Kampagne, die die
# uebrigen Werkzeuge nicht abdecken. Laut der Analyse von Sal Aguilar
# (WPSecurityAnalyzer, Mai 2026) verbreitet sie sich zusaetzlich ueber:
#
#   1. Weiterleitungen, die ans ENDE bestehender JS-Dateien angehaengt werden:
#        window.location.href = "//https://<domain>/<token>";
#      Das fuehrende // vor dem Protokoll ist ein auffaelliger Marker - so
#      schreibt kein Entwickler eine URL.
#   2. Gefaelschte "Coming soon"-Seiten als .htm, .html und .php mit einer
#      Variante derselben Weiterleitung.
#
# Zwei Stufen, bewusst getrennt:
#   TREFFER   - eine Domain aus der Sperrliste kommt vor. Eindeutig, mit
#               --apply automatisch entfernbar.
#   VERDACHT  - Weiterleitungsmuster ohne bekannte Domain. Wird nur gemeldet,
#               denn legitime Skripte enthalten ebenfalls location-Zuweisungen.
#
# DRY RUN, solange --apply fehlt. Vor jeder Aenderung wird die Datei gesichert.
#
# Usage:
#   ./wp-asset-scan.sh                      # alle Installationen
#   ./wp-asset-scan.sh --path /home/SITE/public_html
#   ./wp-asset-scan.sh --list ./blocklist-domains.txt
#   ./wp-asset-scan.sh --apply              # Treffer bereinigen
#   ./wp-asset-scan.sh --suspicious         # auch Verdachtsfaelle im Detail

set -uo pipefail

LIST="${LIST:-$(dirname "${BASH_SOURCE[0]}")/blocklist-domains.txt}"
ROOTS=()
APPLY=0
SHOW_SUSPECT=0
TAIL_BYTES=800          # Injektion sitzt am Dateiende, auch bei minifiziertem JS

while [[ $# -gt 0 ]]; do
  case "$1" in
    --path)       ROOTS+=("${2%/}"); shift 2 ;;
    --list)       LIST="$2"; shift 2 ;;
    --apply)      APPLY=1; shift ;;
    --suspicious) SHOW_SUSPECT=1; shift ;;
    -h|--help)    sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "Unbekannte Option: $1"; exit 1 ;;
  esac
done

hr()   { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { printf '\033[32m  [ok] %s\033[0m\n' "$*"; }
warn() { printf '\033[33m  [VERDACHT] %s\033[0m\n' "$*"; }
bad()  { printf '\033[31m  [TREFFER]  %s\033[0m\n' "$*"; }

# --- Domainmuster aus der Sperrliste -----------------------------------------
if [[ -f "$LIST" ]]; then
  mapfile -t DOMAINS < <(grep -vE '^\s*#|^\s*$' "$LIST" | tr -d ' \t')
  DOM_RE=$(IFS='|'; echo "${DOMAINS[*]}" | sed 's/\./\\./g')
  echo "Sperrliste: ${#DOMAINS[@]} Domains aus ${LIST}"
else
  DOM_RE=''
  echo "Hinweis: ${LIST} nicht gefunden - es wird nur nach Mustern gesucht,"
  echo "         nicht nach bekannten Domains."
fi

# Weiterleitungsmuster in JS. Das doppelte // vor dem Protokoll ist der
# staerkste Einzelmarker der Kampagne.
REDIR_RE='(window|document|top|self)?\.?location(\.href|\.replace\(|\.assign\()?\s*=?\s*["'"'"']//?https?:'
PROTO_RE='["'"'"']//https?:'

if [[ ${#ROOTS[@]} -eq 0 ]]; then
  mapfile -t ROOTS < <(ls -d /home/*/public_html 2>/dev/null)
fi
[[ ${#ROOTS[@]} -eq 0 ]] && { echo "Keine Installationen gefunden."; exit 0; }

TOTAL_HIT=0; TOTAL_SUS=0

for ROOT in "${ROOTS[@]}"; do
  [[ -d "$ROOT" ]] || continue
  hr "$ROOT"

  # -------------------------------------------------------------------------
  # 1. JS-Dateien: nur das Dateiende pruefen
  # -------------------------------------------------------------------------
  printf '  JS-Dateien (letzte %d Bytes)\n' "$TAIL_BYTES"
  JS_HIT=0; JS_SUS=0
  while IFS= read -r -d '' F; do
    TAIL=$(tail -c "$TAIL_BYTES" "$F" 2>/dev/null | tr -d '\000')
    [[ -z "$TAIL" ]] && continue

    if [[ -n "$DOM_RE" ]] && echo "$TAIL" | grep -qiE "$DOM_RE"; then
      bad "JS: $F"
      echo "$TAIL" | grep -oiE ".{0,40}(${DOM_RE}).{0,30}" | head -2 | sed 's/^/             /'
      JS_HIT=$((JS_HIT+1)); TOTAL_HIT=$((TOTAL_HIT+1))

      if [[ $APPLY -eq 1 ]]; then
        cp -p "$F" "${F}.bak-$(date +%s)"
        # Minifiziertes JS steht oft komplett auf einer Zeile - die ganze Zeile
        # zu loeschen wuerde das Skript zerstoeren. Deshalb wird nur die
        # eingeschleuste Anweisung herausgeschnitten:
        #   [window.|document.]location[.href|.replace(...)] = "…domain…" ;
        for D in "${DOMAINS[@]}"; do
          DE=${D//./\\.}
          sed -i -E \
            -e "s#[a-zA-Z_.]*location(\.href|\.assign|\.replace)?\s*(=|\()\s*[\"'][^\"']*${DE}[^\"']*[\"']\s*\)?\s*;?##g" \
            -e "s#[\"'][^\"']*${DE}[^\"']*[\"']##g" \
            "$F"
        done
        if grep -qiE "$DOM_RE" "$F"; then
          printf '\033[31m             Rest verblieben - bitte von Hand pruefen, Sicherung: %s.bak-*\033[0m\n' "$F"
        elif [[ ! -s "$F" ]]; then
          printf '\033[33m             Datei ist jetzt leer - bestand nur aus der Injektion\033[0m\n'
        else
          printf '\033[32m             bereinigt (Sicherung daneben, %d -> %d Bytes)\033[0m\n' \
                 "$(stat -c%s "${F}.bak-"* 2>/dev/null | tail -1)" "$(stat -c%s "$F")"
        fi
      fi

    elif echo "$TAIL" | grep -qE "$PROTO_RE"; then
      # //https: ist praktisch immer bösartig, auch ohne bekannte Domain
      bad "JS (Protokollmarker //http): $F"
      echo "$TAIL" | grep -oE ".{0,30}${PROTO_RE}.{0,40}" | head -2 | sed 's/^/             /'
      JS_HIT=$((JS_HIT+1)); TOTAL_HIT=$((TOTAL_HIT+1))

    elif echo "$TAIL" | grep -qiE "$REDIR_RE"; then
      JS_SUS=$((JS_SUS+1)); TOTAL_SUS=$((TOTAL_SUS+1))
      [[ $SHOW_SUSPECT -eq 1 ]] && {
        warn "JS: $F"
        echo "$TAIL" | grep -oiE ".{0,30}location.{0,50}" | head -1 | sed 's/^/             /'
      }
    fi
  done < <(find "$ROOT" -type f -name '*.js' ! -name '*.min.js.map' -print0 2>/dev/null)

  [[ $JS_HIT -eq 0 ]] && ok "keine infizierten JS-Dateien"
  [[ $JS_SUS -gt 0 && $SHOW_SUSPECT -eq 0 ]] && \
    printf '  %d JS-Datei(en) mit location-Zuweisung am Ende - mit --suspicious anzeigen\n' "$JS_SUS"

  # -------------------------------------------------------------------------
  # 2. Gefaelschte Landeseiten (.htm/.html) - in WordPress unueblich
  # -------------------------------------------------------------------------
  printf '  HTML-Dateien\n'
  HTML_HIT=0
  while IFS= read -r -d '' F; do
    case "$F" in */readme.html|*/license.html) continue ;; esac
    C=$(head -c 4000 "$F" 2>/dev/null)
    if { [[ -n "$DOM_RE" ]] && echo "$C" | grep -qiE "$DOM_RE"; } \
       || echo "$C" | grep -qiE 'http-equiv=["'"'"']?refresh|location\.(replace|href)'; then
      bad "HTML: $F  ($(stat -c '%y' "$F" | cut -c1-16))"
      HTML_HIT=$((HTML_HIT+1)); TOTAL_HIT=$((TOTAL_HIT+1))
    fi
  done < <(find "$ROOT" -type f \( -name '*.htm' -o -name '*.html' \) -print0 2>/dev/null)
  [[ $HTML_HIT -eq 0 ]] && ok "keine auffaelligen HTML-Dateien"

  # Dateinamen der Kampagne
  COMING=$(find "$ROOT" -type f -iname '*coming*soon*' -o -type f -iname '*under*construction*' 2>/dev/null | head -10)
  [[ -n "$COMING" ]] && { echo "$COMING" | while read -r F; do bad "Landeseite: $F"; done; TOTAL_HIT=$((TOTAL_HIT+1)); }

  # -------------------------------------------------------------------------
  # 3. PHP ausserhalb der ueblichen Pfade
  # -------------------------------------------------------------------------
  printf '  PHP an untypischen Orten\n'
  PHP_HIT=0
  while IFS= read -r -d '' F; do
    bad "PHP: $F  ($(stat -c '%y' "$F" | cut -c1-16))"
    PHP_HIT=$((PHP_HIT+1)); TOTAL_HIT=$((TOTAL_HIT+1))
  done < <(find "$ROOT" \( -path '*/wp-content/uploads/*' -o -path '*/wp-content/cache/*' \
                          -o -path '*/wp-content/languages/*' \) -name '*.php' -print0 2>/dev/null)
  [[ $PHP_HIT -eq 0 ]] && ok "kein PHP in uploads/cache/languages"

  # -------------------------------------------------------------------------
  # 3b. index.php im Webroot (Loader bei Unterverzeichnis-Installationen)
  # -------------------------------------------------------------------------
  printf '  index.php (Loader)\n'
  IDX_HIT=0
  for IDX in "${ROOT}/index.php" "${ROOT}"/*/index.php; do
    [[ -f "$IDX" ]] || continue
    # nur Dateien betrachten, die wie ein Loader aussehen sollen: Webroot oder
    # direkt darunter. Tiefer liegende index.php gehoeren zu Themes/Plugins.
    BODY=$(sed -E 's://.*$::; s:/\*.*\*/::' "$IDX" 2>/dev/null | grep -vE '^\s*(\*|/\*|\*/)?\s*$' | grep -v '^\s*#')
    LINES=$(echo "$BODY" | grep -cve '^\s*$')
    SIZE=$(stat -c%s "$IDX")
    # Eine index.php mit viel Code ist kein Loader - das ist normal fuer
    # den WordPress-Kern selbst, deshalb hier nur kleine Dateien bewerten.
    [[ "$LINES" -gt 60 ]] && continue

    DANGER=$(echo "$BODY" | grep -inE \
      'eval\(|base64_decode|gzinflate|gzuncompress|str_rot13|assert\(|create_function|preg_replace\s*\(\s*["'"'"'].*/e|system\(|exec\(|shell_exec|passthru|popen|proc_open|file_get_contents\s*\(\s*["'"'"']https?:|curl_exec|fsockopen|header\s*\(\s*["'"'"']\s*Location|include\s*\(?\s*["'"'"']https?:|auto_prepend' \
      | head -5)

    if [[ -n "$DANGER" ]]; then
      bad "index.php mit untypischen Konstrukten: $IDX"
      echo "$DANGER" | sed 's/^/             /'
      IDX_HIT=$((IDX_HIT+1)); TOTAL_HIT=$((TOTAL_HIT+1))
    elif echo "$BODY" | grep -qE 'require|include'; then
      if ! echo "$BODY" | grep -qE '(require|include)(_once)?[^;]*wp-(blog-header|load|settings)\.php'; then
        bad "index.php bindet etwas anderes als den WordPress-Kern ein: $IDX"
        echo "$BODY" | grep -E 'require|include' | head -3 | sed 's/^/             /'
        IDX_HIT=$((IDX_HIT+1)); TOTAL_HIT=$((TOTAL_HIT+1))
      elif [[ "$LINES" -le 15 ]]; then
        printf '    ok: %s ist ein Loader (%d Zeilen) - Pruefsummenabweichung hier normal\n' "$IDX" "$LINES"
      fi
    fi
  done
  [[ $IDX_HIT -eq 0 ]] && ok "keine auffaellige index.php"

  # -------------------------------------------------------------------------
  # 4. Theme-Assets, die aus der Datenbank neu erzeugt werden
  # -------------------------------------------------------------------------
  MERGED=$(find "$ROOT" -path '*uploads/dynamic_avia/*' -o -path '*cache/autoptimize/*' \
                        -o -path '*cache/min/*' 2>/dev/null | head -5)
  [[ -n "$MERGED" ]] && printf '  Hinweis: zusammengefuehrte Theme-Assets vorhanden - nach der\n           Bereinigung neu erzeugen lassen, sonst bleibt die alte Fassung aktiv.\n'
done

hr "Ergebnis"
printf '  Treffer:  %d\n  Verdacht: %d\n' "$TOTAL_HIT" "$TOTAL_SUS"
if [[ $TOTAL_HIT -eq 0 && $TOTAL_SUS -eq 0 ]]; then
  ok "Dateisystem unauffaellig"
elif [[ $APPLY -eq 0 && $TOTAL_HIT -gt 0 ]]; then
  echo "  Mit --apply werden die Zeilen mit bekannten Domains aus JS-Dateien entfernt."
  echo "  HTML- und PHP-Funde werden NIE automatisch geloescht - erst ansehen."
fi
cat <<'NEXT'

  Nach dem Bereinigen von JS-Dateien:
    - Theme-Cache und zusammengefuehrte Assets neu erzeugen lassen
    - opcache leeren: systemctl reload php*-fpm
    - Pruefsummen gegenpruefen: wp plugin verify-checksums --all
      (eine veraenderte Plugin-Datei zeigt sich dort zuverlaessiger als per grep)
NEXT
