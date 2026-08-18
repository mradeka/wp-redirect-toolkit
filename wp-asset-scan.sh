#!/usr/bin/env bash
#
# wp-asset-scan.sh
#
# Checks everything that lives in the FILESYSTEM. Counterpart to wp-db-audit,
# which checks the database - the split follows the data source, not topic.
#
# Scope: JS injections, fake landing pages, PHP in unusual places,
# index.php loaders, mu-plugins, obfuscation, auto_prepend, dumps in the
# webroot, plus checksums for core, plugins and themes.
#
# The campaign-specific patterns come from the analysis that the other
# tools do not cover. According to the analysis by Sal Aguilar
# (WPSecurityAnalyzer, May 2026), the campaign also spreads via:
#
#   1. Redirects appended to the END of existing JS files:
#        window.location.href = "//https://<domain>/<token>";
#      The leading // before the protocol is a conspicuous marker - no
#      developer writes a URL that way.
#   2. Fake "Coming soon" pages as .htm, .html and .php carrying a variant
#      of the same redirect.
#
# Two levels, deliberately separated:
#   HIT       - a domain from the blocklist appears. Unambiguous, removable
#               automatically with --apply.
#   SUSPECT   - redirect pattern without a known domain. Reported only,
#               because legitimate scripts also assign to location.
#
# DRY RUN unless --apply is given. Every file is backed up before a change.
#
# Usage:
#   ./wp-asset-scan.sh                      # all installations
#   ./wp-asset-scan.sh --path /home/SITE/public_html
#   ./wp-asset-scan.sh --list ./blocklist-domains.txt
#   ./wp-asset-scan.sh --apply              # clean hits
#   ./wp-asset-scan.sh --suspicious         # show suspects in detail

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
warn() { printf '\033[33m  [SUSPECT] %s\033[0m\n' "$*"; }
bad()  { printf '\033[31m  [HIT]  %s\033[0m\n' "$*"; }

# --- Domainmuster aus der Sperrliste -----------------------------------------
if [[ -f "$LIST" ]]; then
  mapfile -t DOMAINS < <(grep -vE '^\s*#|^\s*$' "$LIST" | tr -d ' \t')
  DOM_RE=$(IFS='|'; echo "${DOMAINS[*]}" | sed 's/\./\\./g')
  echo "Blocklist: ${#DOMAINS[@]} domains from ${LIST}"
else
  DOM_RE=''
  echo "Note: ${LIST} not found - searching by pattern only,"
  echo "      not for known domains."
fi

# Redirect patterns in JS. The doubled // before the protocol is the
# strongest single marker of the campaign.
REDIR_RE='(window|document|top|self)?\.?location(\.href|\.replace\(|\.assign\()?\s*=?\s*["'"'"']//?https?:'
PROTO_RE='["'"'"']//https?:'

if [[ ${#ROOTS[@]} -eq 0 ]]; then
  mapfile -t ROOTS < <(ls -d /home/*/public_html 2>/dev/null)
fi
[[ ${#ROOTS[@]} -eq 0 ]] && { echo "No installations found."; exit 0; }

TOTAL_HIT=0; TOTAL_SUS=0

for ROOT in "${ROOTS[@]}"; do
  [[ -d "$ROOT" ]] || continue
  hr "$ROOT"

  # -------------------------------------------------------------------------
  # 1. JS-Dateien: nur das Dateiende pruefen
  # -------------------------------------------------------------------------
  printf '  JS files (last %d bytes)\n' "$TAIL_BYTES"
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
          printf '\033[31m             remainder left - check manually, backup: %s.bak-*\033[0m\n' "$F"
        elif [[ ! -s "$F" ]]; then
          printf '\033[33m             file is now empty - it contained only the injection\033[0m\n'
        else
          printf '\033[32m             cleaned (backup alongside, %d -> %d bytes)\033[0m\n' \
                 "$(stat -c%s "${F}.bak-"* 2>/dev/null | tail -1)" "$(stat -c%s "$F")"
        fi
      fi

    elif echo "$TAIL" | grep -qE "$PROTO_RE"; then
      # //https: ist praktisch immer bösartig, auch ohne bekannte Domain
      bad "JS (protocol marker //http): $F"
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

  [[ $JS_HIT -eq 0 ]] && ok "no infected JS files"
  [[ $JS_SUS -gt 0 && $SHOW_SUSPECT -eq 0 ]] && \
    printf '  %d JS file(s) with a trailing location assignment - show with --suspicious\n' "$JS_SUS"

  # -------------------------------------------------------------------------
  # 2. Gefaelschte Landeseiten (.htm/.html) - in WordPress unueblich
  # -------------------------------------------------------------------------
  printf '  HTML files\n'
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
  [[ $HTML_HIT -eq 0 ]] && ok "keine auffaelligen HTML files"

  # Dateinamen der Kampagne. Wichtig: das Standardtheme bringt selbst ein
  # Muster "page-coming-soon.php" samt Hintergrundbild mit - deshalb werden
  # Theme- und Plugin-Verzeichnisse ausgenommen und nur Dateien gemeldet, die
  # tatsaechlich eine Weiterleitung enthalten.
  COMING=$(find "$ROOT" -maxdepth 3 -type f \
             \( -iname '*coming*soon*' -o -iname '*under*construction*' \) \
             ! -path '*/wp-content/themes/*' ! -path '*/wp-content/plugins/*' \
             ! -path '*/wp-includes/*' ! -path '*/wp-admin/*' \
             \( -name '*.php' -o -name '*.htm' -o -name '*.html' \) 2>/dev/null | head -10)
  if [[ -n "$COMING" ]]; then
    while read -r F; do
      [[ -z "$F" ]] && continue
      if head -c 4000 "$F" | grep -qiE 'http-equiv=["'"'"']?refresh|location\.(replace|href)|header\s*\(\s*["'"'"']\s*Location'; then
        bad "landing page with redirect: $F"
        TOTAL_HIT=$((TOTAL_HIT+1))
      else
        warn "named like a landing page but contains no redirect: $F"
        TOTAL_SUS=$((TOTAL_SUS+1))
      fi
    done <<< "$COMING"
  fi

  # -------------------------------------------------------------------------
  # 3. PHP ausserhalb der ueblichen Pfade
  #    Seit WordPress 6.5 liegen Uebersetzungen zusaetzlich als PHP-Dateien
  #    (*.l10n.php) unter wp-content/languages - das ist legitim und deutlich
  #    schneller als die alten .mo-Dateien. Solche Dateien werden ausgenommen.
  # -------------------------------------------------------------------------
  printf '  PHP in unusual places\n'
  PHP_HIT=0
  while IFS= read -r -d '' F; do
    case "$F" in
      *.l10n.php) continue ;;                  # Uebersetzungsdatei
      */languages/*.php)
        # andere PHP-Dateien unter languages/ nur melden, wenn sie Code
        # ausfuehren statt nur ein Array zurueckzugeben
        head -c 200 "$F" | grep -qE '^\s*<\?php\s+return\s*\[' && continue
        ;;
    esac
    bad "PHP: $F  ($(stat -c '%y' "$F" | cut -c1-16))"
    PHP_HIT=$((PHP_HIT+1)); TOTAL_HIT=$((TOTAL_HIT+1))
  done < <(find "$ROOT" \( -path '*/wp-content/uploads/*' -o -path '*/wp-content/cache/*' \
                          -o -path '*/wp-content/languages/*' \) -name '*.php' -print0 2>/dev/null)
  [[ $PHP_HIT -eq 0 ]] && ok "no unexpected PHP in uploads/cache/languages"

  # -------------------------------------------------------------------------
  # 3b. index.php im Webroot (Loader bei Unterverzeichnis-Installationen)
  # -------------------------------------------------------------------------
  printf '  index.php (loader)\n'
  IDX_HIT=0
  for IDX in "${ROOT}/index.php" "${ROOT}"/*/index.php; do
    [[ -f "$IDX" ]] || continue
    # nur Dateien betrachten, die wie ein Loader aussehen sollen: Webroot oder
    # direkt darunter. Tiefer liegende index.php gehoeren zu Themes/Plugins.
    BODY=$(sed -E 's://.*$::; s:/\*.*\*/::' "$IDX" 2>/dev/null | grep -vE '^\s*(\*|/\*|\*/)?\s*$' | grep -v '^\s*#')
    LINES=$(echo "$BODY" | grep -cve '^\s*$')
    # Eine index.php mit viel Code ist kein Loader - das ist normal fuer
    # den WordPress-Kern selbst, deshalb hier nur kleine Dateien bewerten.
    [[ "$LINES" -gt 60 ]] && continue

    DANGER=$(echo "$BODY" | grep -inE \
      'eval\(|base64_decode|gzinflate|gzuncompress|str_rot13|assert\(|create_function|preg_replace\s*\(\s*["'"'"'].*/e|system\(|exec\(|shell_exec|passthru|popen|proc_open|file_get_contents\s*\(\s*["'"'"']https?:|curl_exec|fsockopen|header\s*\(\s*["'"'"']\s*Location|include\s*\(?\s*["'"'"']https?:|auto_prepend' \
      | head -5)

    if [[ -n "$DANGER" ]]; then
      bad "index.php with unusual constructs: $IDX"
      echo "$DANGER" | sed 's/^/             /'
      IDX_HIT=$((IDX_HIT+1)); TOTAL_HIT=$((TOTAL_HIT+1))
    elif echo "$BODY" | grep -qE 'require|include'; then
      if ! echo "$BODY" | grep -qE '(require|include)(_once)?[^;]*wp-(blog-header|load|settings)\.php'; then
        bad "index.php includes something other than WordPress core: $IDX"
        echo "$BODY" | grep -E 'require|include' | head -3 | sed 's/^/             /'
        IDX_HIT=$((IDX_HIT+1)); TOTAL_HIT=$((TOTAL_HIT+1))
      elif [[ "$LINES" -le 15 ]]; then
        printf '    ok: %s is a loader (%d lines) - a checksum mismatch is normal here\n' "$IDX" "$LINES"
      fi
    fi
  done
  [[ $IDX_HIT -eq 0 ]] && ok "no suspicious index.php"

  # -------------------------------------------------------------------------
  # 5. Weitere Dateibefunde (aus wp-db-audit hierher verschoben - alles, was
  #    im Dateisystem liegt, gehoert in dieses Skript)
  # -------------------------------------------------------------------------
  printf '  Further file checks\n'
  MISC=0

  if [[ -d "${ROOT}/wp-content/mu-plugins" ]]; then
    MU=$(find "${ROOT}/wp-content/mu-plugins" -name '*.php' 2>/dev/null | head -5)
    [[ -n "$MU" ]] && { bad "mu-plugins present (always loaded): $(echo "$MU" | tr '\n' ' ')"; MISC=1; TOTAL_HIT=$((TOTAL_HIT+1)); }
  fi

  # Verschleierung: Der Kern (wp-admin, wp-includes) ist bereits durch die
  # Pruefsummen abgedeckt und enthaelt legitime Treffer - class-pclzip.php
  # nutzt gzinflate/gzdeflate zum Ent- und Packen von ZIP-Daten und traegt ein
  # auskommentiertes eval(. Deshalb hier nur wp-content pruefen und zwischen
  # starken und schwachen Mustern unterscheiden.
  OBF_SCOPE="${ROOT}/wp-content"
  [[ -d "$OBF_SCOPE" ]] || OBF_SCOPE="$ROOT"

  # stark: die Kombination aus Ausfuehrung und Verschleierung, oder
  # Ausfuehrung direkt aus Benutzereingaben - beides hat in legitimem
  # Code praktisch nie einen Grund
  OBF_STRONG=$(grep -rlE \
    'eval\s*\(\s*(base64_decode|gzinflate|gzuncompress|str_rot13|stripslashes|\$_(GET|POST|REQUEST|COOKIE))|assert\s*\(\s*\$_|preg_replace\s*\(\s*["'"'"'][^"'"'"']*/[a-z]*e[a-z]*["'"'"']|create_function\s*\(.*\$_|\$\{\s*["'"'"']_(GET|POST|REQUEST)|(base64_decode|gzinflate)\s*\(\s*["'"'"'][A-Za-z0-9+/=]{200,}' \
    "$OBF_SCOPE" --include='*.php' 2>/dev/null | head -5)
  [[ -n "$OBF_STRONG" ]] && { bad "obfuscation + execution: $(echo "$OBF_STRONG" | tr '\n' ' ')"; MISC=1; TOTAL_HIT=$((TOTAL_HIT+1)); }

  # schwach: einzelne Funktionen, die auch legitim vorkommen (Caches,
  # Minifier, Importer). Nur mit --suspicious anzeigen.
  if [[ $SHOW_SUSPECT -eq 1 ]]; then
    OBF_WEAK=$(grep -rlE 'base64_decode|gzinflate|str_rot13|create_function' \
      "$OBF_SCOPE" --include='*.php' 2>/dev/null | head -10)
    if [[ -n "$OBF_WEAK" ]]; then
      warn "single obfuscation functions (often legitimate, please review):"
      echo "$OBF_WEAK" | sed 's/^/             /'
      TOTAL_SUS=$((TOTAL_SUS+1))
    fi
  fi

  PREP=$(grep -rn 'auto_prepend_file\|auto_append_file' \
         "${ROOT}/.htaccess" "${ROOT}/.user.ini" "${ROOT}/php.ini" 2>/dev/null | head -3)
  [[ -n "$PREP" ]] && { bad "auto_prepend/append: $(echo "$PREP" | tr '\n' ' ')"; MISC=1; TOTAL_HIT=$((TOTAL_HIT+1)); }

  DUMPS=$(find "$ROOT" -maxdepth 3 \
          \( -name '*.sql' -o -name '*.sql.gz' -o -name '*.tar.gz' -o -name '*.zip' -o -name '*.phar' \) \
          -type f 2>/dev/null | head -5)
  [[ -n "$DUMPS" ]] && { bad "dumps/archives in the webroot (contain password hashes): $(echo "$DUMPS" | tr '\n' ' ')"; MISC=1; TOTAL_HIT=$((TOTAL_HIT+1)); }

  RECENT=$(find "$ROOT" -name '*.php' -mtime -7 -type f 2>/dev/null | head -10)
  if [[ -n "$RECENT" ]]; then
    printf '    PHP files changed in the last 7 days (compare against your own work):\n'
    echo "$RECENT" | while read -r f; do printf '      %s\n' "$(stat -c '%y %n' "$f" | cut -c1-16,21-)"; done
  fi
  [[ $MISC -eq 0 ]] && ok "no further file findings"

  # -------------------------------------------------------------------------
  # 6. Pruefsummen - braucht WP-CLI, deshalb erst hier
  # -------------------------------------------------------------------------
  WPDIR=""
  for CAND in "$ROOT" "$ROOT"/wordpress "$ROOT"/wp; do
    [[ -f "${CAND}/wp-config.php" ]] && { WPDIR="$CAND"; break; }
  done
  if [[ -n "$WPDIR" ]]; then
    OWNER=$(stat -c '%U' "${WPDIR}/wp-config.php")
    WPBIN=""
    for CAND in "/home/${OWNER}/wp" "/home/${OWNER}/.wp-cli.phar" /usr/local/bin/wp; do
      sudo -u "$OWNER" -H test -r "$CAND" 2>/dev/null && { WPBIN="$CAND"; break; }
    done
    if [[ -n "$WPBIN" ]]; then
      printf '  checksums (%s)\n' "$WPDIR"
      WP="sudo -u ${OWNER} -H ${WPBIN} --path=${WPDIR} --skip-plugins --skip-themes"

      CK=$($WP core verify-checksums 2>&1 | grep -v '^Success')
      CK_REST=$(echo "$CK" | grep -viE "index\.php|doesn't verify against checksums" | grep -v '^$')
      [[ -z "$CK_REST" ]] && ok "core unchanged" \
        || { bad "core files modified: $(echo "$CK_REST" | head -3 | tr '\n' ' ')"; TOTAL_HIT=$((TOTAL_HIT+1)); }

      for KIND in plugin theme; do
        OUT=$($WP "$KIND" verify-checksums --all 2>&1)
        MOD=$(echo "$OUT" | grep -iE "doesn't verify|should not exist|File was added|File was modified|File doesn't exist" | head -10)
        if [[ -n "$MOD" ]]; then
          bad "${KIND}: modified files"
          echo "$MOD" | head -5 | sed 's/^/             /'
          TOTAL_HIT=$((TOTAL_HIT+1))
        else
          ok "${KIND}: all verifiable files unchanged"
        fi
        UNVERIF=$(echo "$OUT" | grep -i 'could not retrieve' \
                  | sed -E 's/.*(of|for) [a-z]+ ([A-Za-z0-9_.-]+).*/\2/I' | sort -u | tr '\n' ' ')
        if [[ -n "${UNVERIF// /}" ]]; then
          printf '    without checksums (not in the official repository): %s\n' "$UNVERIF"
          LOW=$(echo "$UNVERIF" | tr '[:upper:]' '[:lower:]')
          case "$LOW" in
            *enfold*|*divi*|*avada*|*bridge*|*flatsome*|*woodmart*|*jupiter*|*betheme*|*salient*|*thegem*|*impreza*|*porto*|*x-theme*|*elementor-pro*|*wp-rocket*|*acf-pro*|*gravityforms*|*wpml*|*layerslider*|*revslider*|*slider-revolution*)
              warn "includes a commercial extension - it is NOT verified."
              warn "On suspicion, diff against the original from your customer account"
              warn "(never against a copy of unknown origin):"
              warn "  diff -rq ${WPDIR}/wp-content/${KIND}s/<name>/ /pfad/zum/original/"
              TOTAL_SUS=$((TOTAL_SUS+1))
              ;;
          esac
        fi
      done
    else
      printf '  checksums skipped - no usable WP-CLI for %s\n' "$OWNER"
    fi
  fi

  # -------------------------------------------------------------------------
  # 7. Theme-Assets, die aus der Datenbank neu erzeugt werden
  # -------------------------------------------------------------------------
  MERGED=$(find "$ROOT" -path '*uploads/dynamic_avia/*' -o -path '*cache/autoptimize/*' \
                        -o -path '*cache/min/*' 2>/dev/null | head -5)
  [[ -n "$MERGED" ]] && printf '  Note: merged theme assets present - have them regenerated after\n      cleaning, otherwise the old version stays active.\n'
done

hr "Ergebnis"
printf '  hits:     %d\n  suspects: %d\n' "$TOTAL_HIT" "$TOTAL_SUS"
if [[ $TOTAL_HIT -eq 0 && $TOTAL_SUS -eq 0 ]]; then
  ok "filesystem clean"
elif [[ $APPLY -eq 0 && $TOTAL_HIT -gt 0 ]]; then
  echo "  With --apply, lines containing known domains are removed from JS files."
  echo "  HTML and PHP findings are NEVER deleted automatically - inspect first."
fi
cat <<'NEXT'

  After cleaning JS files:
    - have the theme cache and merged assets regenerated
    - clear opcache: systemctl reload php*-fpm
    - verify checksums - more reliable than any pattern search:
        wp plugin verify-checksums --all
        wp theme  verify-checksums --all
      Commercial themes (Enfold, Divi, Avada ...) are not in the official
      repository and are skipped. On suspicion they must be compared by hand
      against the original from your customer account:
        diff -rq wp-content/themes/<name>/ /path/to/extracted/original/
NEXT
