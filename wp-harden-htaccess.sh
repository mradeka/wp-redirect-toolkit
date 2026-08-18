#!/usr/bin/env bash
#
# wp-harden-htaccess.sh
#
# Legt eine abgesicherte .htaccess in jeder WordPress-Installation unter
# /home/<benutzer>/public_html[/wordpress] an - plus eine zweite in
# wp-content/uploads/, die die Ausfuehrung hochgeladener Skripte verhindert.
#
# Warum das riskanter ist als die uebrigen Skripte, und was dagegen getan wird:
# Eine fehlerhafte .htaccess nimmt die Seite sofort vom Netz. Deshalb
#   1. wird die vorhandene Datei gesichert,
#   2. werden eigene Rewrite-Regeln uebernommen statt ueberschrieben,
#   3. wird das Layout erkannt (Webroot oder Unterverzeichnis) und die
#      RewriteBase entsprechend gesetzt,
#   4. wird der HTTP-Status VOR und NACH der Aenderung gemessen und bei
#      Verschlechterung automatisch zurueckgerollt.
#
# DRY RUN, solange --apply fehlt.
#
# Usage:
#   ./wp-harden-htaccess.sh --inventory          # ZUERST: was steht ueberhaupt drin?
#   ./wp-harden-htaccess.sh                      # Trockenlauf
#   ./wp-harden-htaccess.sh --only siteuser
#   ./wp-harden-htaccess.sh --apply
#   ./wp-harden-htaccess.sh --apply --strict     # nur PHP-Handler uebernehmen
#   ./wp-harden-htaccess.sh --apply --no-xmlrpc-block   # XML-RPC offen lassen
#   ./wp-harden-htaccess.sh --restore            # letzte Sicherung zurueckspielen
#
# Warum die vorhandenen Dateien nicht einfach geloescht werden:
# Bei fcgid-Sites steht die PHP-Version in der .htaccess (AddHandler/AddType).
# Faellt die Zeile weg, laeuft die Seite mit der Server-Vorgabe - oder PHP wird
# gar nicht mehr ausgefuehrt und der Browser laedt den Quelltext herunter.
# Umgekehrt darf auch nicht blind alles uebernommen werden: nach einem Vorfall
# kann dort eine eingeschleuste Regel stehen. Deshalb wird jede Zeile
# klassifiziert - siehe --inventory.

set -uo pipefail

ONLY=""
APPLY=0
RESTORE=0
INVENTORY=0
STRICT=0
BLOCK_XMLRPC=1
BACKUP_DIR="/root/htaccess-backups"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --only)             ONLY="$2"; shift 2 ;;
    --apply)            APPLY=1; shift ;;
    --restore)          RESTORE=1; shift ;;
    --inventory)        INVENTORY=1; shift ;;
    --strict)           STRICT=1; shift ;;
    --no-xmlrpc-block)  BLOCK_XMLRPC=0; shift ;;
    --backup-dir)       BACKUP_DIR="$2"; shift 2 ;;
    -h|--help)          sed -n '2,36p' "$0"; exit 0 ;;
    *) echo "Unbekannte Option: $1"; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Klassifikation eigener Regeln
#
# Warum nicht einfach alles uebernehmen: Nach einem Vorfall kann in einer
# .htaccess auch eine eingeschleuste Regel stehen. Warum nicht einfach alles
# loeschen: Bei fcgid-Sites steht dort die PHP-Version. Faellt die Zeile weg,
# laeuft die Seite mit der Server-Vorgabe - oder PHP wird gar nicht mehr
# ausgefuehrt und der Browser laedt den Quelltext herunter.
# ---------------------------------------------------------------------------
classify_line() {
  local L="$1"
  case "$L" in
    ''|'#'*) echo "kommentar"; return ;;
  esac
  # 1. Eindeutig boesartig - ZUERST pruefen. "php_value auto_prepend_file"
  #    sieht sonst wie ein harmloser PHP-Handler aus und wuerde uebernommen,
  #    obwohl genau darueber Schadcode bei jedem Aufruf nachgeladen wird.
  if grep -qiE 'auto_prepend_file|auto_append_file|base64_decode|eval\(|include_path\s*=|\bpython\b|\bperl\b.*-e' <<<"$L"; then
    echo "gefaehrlich"; return
  fi
  # 2. Muss erhalten bleiben - sonst bricht PHP oder die Panel-Konfiguration
  if grep -qiE '^\s*(AddHandler|AddType|FCGIWrapper|Action|SetHandler|php_value|php_admin_value|php_flag|php_admin_flag|suPHP)' <<<"$L"; then
    echo "php-handler"; return
  fi
  # Weiterleitung auf eine fremde Domain
  if grep -qiE '^\s*(RewriteRule|Redirect|RedirectMatch|RedirectPermanent)\b.*https?://' <<<"$L"; then
    echo "externe-weiterleitung"; return
  fi
  # Options-Direktiven brauchen "AllowOverride Options" bzw. "All". Panels
  # setzen dort meist eine Whitelist ohne FollowSymLinks/ExecCGI/Includes.
  # Steht so eine Zeile in der alten Datei, hat sie dort vielleicht
  # funktioniert - nach einer vhost-Aenderung liefert Apache aber
  #     Option FollowSymLinks not allowed here
  # und damit 500 fuer alles unterhalb. Deshalb nicht uebernehmen.
  if grep -qiE '^\s*Options\b' <<<"$L"; then
    if grep -qiE '^\s*Options\s+-Indexes\s*$' <<<"$L"; then
      echo "standard"; return
    fi
    echo "options-risiko"; return
  fi
  # 3. Uebliche, unkritische Kategorien
  grep -qiE '^\s*(Redirect|RedirectMatch|RedirectPermanent|RedirectTemp)\b' <<<"$L" && { echo "weiterleitung"; return; }
  grep -qiE '^\s*(RewriteEngine|RewriteBase|RewriteCond|RewriteRule|RewriteOptions)' <<<"$L" && { echo "rewrite"; return; }
  grep -qiE '^\s*(<Files|<FilesMatch|<Directory|<DirectoryMatch|<Limit|<LimitExcept|Require|Order|Allow|Deny|Auth|Satisfy)' <<<"$L" && { echo "zugriff"; return; }
  grep -qiE '^\s*(Header|RequestHeader|ExpiresByType|ExpiresActive|ExpiresDefault|AddOutputFilter|AddEncoding|AddCharset|BrowserMatch|Options|AddDefaultCharset|ErrorDocument|DirectoryIndex|FileETag|<IfModule|<If|</)' <<<"$L" && { echo "standard"; return; }
  echo "unbekannt"
}

[[ $EUID -ne 0 ]] && { echo "Bitte als root ausfuehren."; exit 1; }

hr()   { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { printf '\033[32m  [ok] %s\033[0m\n' "$*"; }
warn() { printf '\033[33m  [!] %s\033[0m\n' "$*"; }
bad()  { printf '\033[31m  [FEHLER] %s\033[0m\n' "$*"; }
note() { printf '  %s\n' "$*"; }

mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"

# ---------------------------------------------------------------------------
# Vorlagen
# ---------------------------------------------------------------------------
common_rules() {   # $1 = 1, wenn xmlrpc gesperrt werden soll
cat <<'HEAD'
# ---- Absicherung (erzeugt von wp-harden-htaccess) --------------------------
# Nur -Indexes. Jede Options-Direktive braucht "AllowOverride Options" bzw.
# "All"; Panels setzen dort meist eine Whitelist OHNE FollowSymLinks. Ein
# "+FollowSymLinks" quittiert Apache dann mit
#     Option FollowSymLinks not allowed here
# und liefert 500 fuer alles unterhalb des Verzeichnisses - auch fuer CSS.
Options -Indexes

<FilesMatch "^(wp-config\.php|wp-config-sample\.php|\.htaccess|\.htpasswd|\.user\.ini|php\.ini|readme\.html|license\.txt|liesmich\.html)$">
    Require all denied
</FilesMatch>

<FilesMatch "\.(sql|sql\.gz|tar|tar\.gz|tgz|zip|bak|backup|old|orig|save|swp|log|phar|env|dist)$">
    Require all denied
</FilesMatch>

RedirectMatch 404 /\.(?!well-known/)
RedirectMatch 404 /(\.git|\.svn|\.hg|node_modules)/

<FilesMatch "\.(php|php[0-9]|phtml|phps|pht|phar|shtml|cgi|pl|py)$">
    <If "%{REQUEST_URI} =~ m#/wp-content/(uploads|cache|languages)/#">
        Require all denied
    </If>
</FilesMatch>
HEAD

if [[ "${1:-1}" -eq 1 ]]; then
cat <<'XML'

<Files "xmlrpc.php">
    Require all denied
</Files>
XML
fi

cat <<'TAIL'

<IfModule mod_headers.c>
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set Referrer-Policy "strict-origin-when-cross-origin"
    Header always set Permissions-Policy "geolocation=(), microphone=(), camera=(), payment=(), usb=()"
    Header always unset X-Powered-By
    Header always unset X-Pingback
    # HSTS bewusst deaktiviert - erst einschalten, wenn HTTPS auf allen
    # Subdomains laeuft, ein Rueckweg ist waehrend max-age nicht moeglich:
    # Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains"
</IfModule>

<IfModule mod_rewrite.c>
    RewriteEngine On
    RewriteCond %{QUERY_STRING} (^|&)author=\d+ [NC]
    RewriteRule ^$ - [F,L]
</IfModule>

<IfModule mod_deflate.c>
    AddOutputFilterByType DEFLATE text/plain text/html text/xml text/css
    AddOutputFilterByType DEFLATE application/xml application/xhtml+xml
    AddOutputFilterByType DEFLATE application/javascript application/json
    AddOutputFilterByType DEFLATE image/svg+xml font/woff2
</IfModule>

<IfModule mod_expires.c>
    ExpiresActive On
    ExpiresDefault               "access plus 1 month"
    ExpiresByType text/html      "access plus 0 seconds"
    ExpiresByType application/json "access plus 0 seconds"
    ExpiresByType image/jpeg     "access plus 1 year"
    ExpiresByType image/png      "access plus 1 year"
    ExpiresByType image/webp     "access plus 1 year"
    ExpiresByType font/woff2     "access plus 1 year"
    ExpiresByType text/css       "access plus 1 year"
    ExpiresByType application/javascript "access plus 1 year"
</IfModule>

AddDefaultCharset UTF-8
# ---- Ende Absicherung -----------------------------------------------------
TAIL
}

wp_block() {   # $1 = RewriteBase, $2 = Pfad zur index.php
cat <<WPB
# BEGIN WordPress
<IfModule mod_rewrite.c>
RewriteEngine On
RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]
RewriteBase $1
RewriteRule ^index\\.php\$ - [L]
RewriteCond %{REQUEST_FILENAME} !-f
RewriteCond %{REQUEST_FILENAME} !-d
RewriteRule . $2 [L]
</IfModule>
# END WordPress
WPB
}

uploads_rules() {
cat <<'UPL'
# ---- erzeugt von wp-harden-htaccess ---------------------------------------
# Keine Ausfuehrung hochgeladener Skripte - zweite Verteidigungslinie.
<FilesMatch "\.(php|php[0-9]|phtml|phps|pht|phar|shtml|cgi|pl|py|asp|aspx)$">
    Require all denied
</FilesMatch>

# Doppelte Endungen ("bild.php.jpg") werden auf manchen Servern trotzdem
# als PHP ausgefuehrt - deshalb jede Skript-Endung IRGENDWO im Namen sperren.
<FilesMatch "\.(php|php[0-9]|phtml|phps|pht|phar|shtml|cgi|pl|py)\.">
    Require all denied
</FilesMatch>

AddType text/plain .php .phtml .phps .php3 .php4 .php5 .php7 .phar

<IfModule mod_mime.c>
    RemoveHandler .php .phtml .phps .php3 .php4 .php5 .php7 .phar
    RemoveType    .php .phtml .phps .php3 .php4 .php5 .php7 .phar
</IfModule>

# Bewusst nur -Indexes: -ExecCGI/-Includes braeuchten ebenfalls
# "AllowOverride Options". Die PHP-Ausfuehrung wird oben ueber FilesMatch,
# AddType und RemoveHandler unterbunden - dafuer genuegt AllowOverride
# FileInfo, das praktisch ueberall gesetzt ist.
Options -Indexes
UPL
}

# ---------------------------------------------------------------------------
# Wiederherstellung
# ---------------------------------------------------------------------------
if [[ $RESTORE -eq 1 ]]; then
  hr "Sicherungen zurueckspielen"
  FOUND=0
  while IFS= read -r META; do
    TARGET=$(head -1 "$META")
    DATA="${META%.meta}"
    [[ -f "$DATA" && -n "$TARGET" ]] || continue
    cp -p "$DATA" "$TARGET" && ok "wiederhergestellt: $TARGET" && FOUND=1
  done < <(find "$BACKUP_DIR" -name '*.meta' -newermt '-30 days' | sort | tail -50)
  [[ $FOUND -eq 0 ]] && warn "keine Sicherungen gefunden in ${BACKUP_DIR}"
  apachectl configtest 2>&1 | tail -1
  exit 0
fi

# ---------------------------------------------------------------------------
# Installationen finden
# ---------------------------------------------------------------------------
hr "Installationen"
mapfile -t CONFIGS < <(
  ls -d /home/*/public_html/wordpress/wp-config.php \
        /home/*/public_html/wp-config.php 2>/dev/null | sort -u
)
[[ ${#CONFIGS[@]} -eq 0 ]] && { echo "Keine WordPress-Installationen gefunden."; exit 0; }

# ---------------------------------------------------------------------------
# Inventarmodus: erst wissen, was da ist - dann entscheiden
# ---------------------------------------------------------------------------
if [[ $INVENTORY -eq 1 ]]; then
  hr "Inventar der vorhandenen .htaccess-Dateien"
  declare -A TOTAL=()
  for CONFIG in "${CONFIGS[@]}"; do
    WP_PATH=$(dirname "$CONFIG")
    SITE_USER=$(stat -c '%U' "$CONFIG")
    [[ -n "$ONLY" && "$SITE_USER" != "$ONLY" ]] && continue
    F="${WP_PATH}/.htaccess"
    printf '\n\033[1m%s\033[0m  (%s)\n' "$WP_PATH" "$SITE_USER"
    if [[ ! -f "$F" ]]; then
      printf '  keine .htaccess vorhanden\n'
      TOTAL[fehlt]=$(( ${TOTAL[fehlt]:-0} + 1 ))
      continue
    fi
    printf '  %s Zeilen, geaendert %s\n' "$(wc -l < "$F")" "$(stat -c '%y' "$F" | cut -c1-16)"
    RAW=$(awk '
      /# BEGIN WordPress/ { inwp=1 } /# END WordPress/ { inwp=0; next } inwp { next }
      /---- Absicherung/  { inown=1 } /---- Ende Absicherung/ { inown=0; next } inown { next }
      { print }' "$F" | sed -E '/^[[:space:]]*$/d')
    if [[ -z "$RAW" ]]; then
      printf '  nur Standardbloecke, nichts Eigenes\n'
      TOTAL[standard]=$(( ${TOTAL[standard]:-0} + 1 ))
      continue
    fi
    while IFS= read -r L; do
      [[ -z "$L" ]] && continue
      C=$(classify_line "$L")
      TOTAL[$C]=$(( ${TOTAL[$C]:-0} + 1 ))
      case "$C" in
        kommentar) continue ;;
        php-handler)          printf '\033[33m  [PHP-HANDLER] %s\033[0m\n' "$L" ;;
        gefaehrlich)          printf '\033[31m  [GEFAEHRLICH] %s\033[0m\n' "$L" ;;
        externe-weiterleitung) printf '  [ext. Weiterleitung] %s\n' "$L" ;;
        unbekannt)            printf '\033[33m  [unbekannt]   %s\033[0m\n' "$L" ;;
        *)                    printf '  [%s] %s\n' "$C" "$L" ;;
      esac
    done <<< "$RAW"
  done

  hr "Summe ueber alle Seiten"
  for K in "${!TOTAL[@]}"; do printf '  %-22s %s\n' "$K" "${TOTAL[$K]}"; done
  cat <<'NEXT'

  Zur Auswertung:
    PHP-HANDLER  legt die PHP-Version fuer diese Seite fest (fcgid). Faellt die
                 Zeile weg, laeuft die Seite mit der Server-Vorgabe - oder PHP
                 wird gar nicht mehr ausgefuehrt. Wird immer uebernommen.
                 Dauerhaft besser: PHP-Version im Panel bzw. vhost setzen,
                 dann ist die .htaccess davon unabhaengig.
    GEFAEHRLICH  wird nie uebernommen. Nach einem Vorfall die Zeile ansehen,
                 bevor du sie irgendwo wiederverwendest.
    unbekannt    von Hand ansehen - meist Plugin-Bloecke oder Handarbeit.

  Danach:
    wp-harden-htaccess              Trockenlauf mit klassifizierter Uebernahme
    wp-harden-htaccess --strict     nur PHP-Handler uebernehmen, sonst nichts
NEXT
  exit 0
fi

[[ $APPLY -eq 1 ]] && warn "APPLY-MODUS - Dateien werden geschrieben" \
                   || ok "TROCKENLAUF - es wird nichts geaendert"

STAMP=$(date +%F-%H%M%S)
CHANGED=0; SKIPPED=0; FAILED=0

for CONFIG in "${CONFIGS[@]}"; do
  WP_PATH=$(dirname "$CONFIG")
  SITE_USER=$(stat -c '%U' "$CONFIG")
  SITE_GROUP=$(stat -c '%G' "$CONFIG")
  [[ -n "$ONLY" && "$SITE_USER" != "$ONLY" ]] && continue

  hr "${WP_PATH}  (${SITE_USER})"

  # --- Layout bestimmen ----------------------------------------------------
  PARENT=$(dirname "$WP_PATH")
  if [[ "$(basename "$PARENT")" == "public_html" ]]; then
    LAYOUT="subdir"; SUB=$(basename "$WP_PATH")
    TARGET="${WP_PATH}/.htaccess"
    RBASE="/${SUB}/"; RIDX="/${SUB}/index.php"
  else
    LAYOUT="root"; SUB=""
    TARGET="${WP_PATH}/.htaccess"
    RBASE="/"; RIDX="/index.php"
  fi
  note "Layout: ${LAYOUT}   RewriteBase: ${RBASE}"

  # --- oeffentliche Adresse fuer den Vorher/Nachher-Test -------------------
  WPBIN=""
  for CAND in "/home/${SITE_USER}/wp" "/home/${SITE_USER}/.wp-cli.phar" /usr/local/bin/wp; do
    sudo -u "$SITE_USER" -H test -r "$CAND" 2>/dev/null && { WPBIN="$CAND"; break; }
  done
  SITE_URL=""
  [[ -n "$WPBIN" ]] && SITE_URL=$(sudo -u "$SITE_USER" -H "$WPBIN" --path="$WP_PATH" \
                                  --skip-plugins --skip-themes option get home 2>/dev/null)
  if [[ -n "$SITE_URL" ]]; then
    # Bei Unterverzeichnis-Installationen liegt die geschriebene .htaccess NICHT
    # im Webroot. Wird nur die Startseite geprueft, bleibt ein 500 im
    # Kernverzeichnis unbemerkt - genau dort fehlen dann CSS und JS.
    CORE_URL="${SITE_URL%/}${SUB:+/$SUB}"
    BEFORE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "${SITE_URL}/?nocache=$RANDOM")
    BEFORE_CORE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "${CORE_URL}/wp-includes/js/jquery/jquery.min.js?nocache=$RANDOM")
    note "HTTP vorher: Startseite ${BEFORE}, Asset im Kern ${BEFORE_CORE}  (${SITE_URL})"
  else
    BEFORE=""; BEFORE_CORE=""; CORE_URL=""
    warn "oeffentliche Adresse nicht ermittelbar - kein Vorher/Nachher-Test moeglich"
  fi

  # --- AllowOverride -------------------------------------------------------
  if ! grep -rqs -- "$PARENT" /etc/apache2/sites-enabled /etc/httpd/conf.d 2>/dev/null; then
    warn "kein vhost verweist auf ${PARENT} - AllowOverride bitte selbst pruefen"
  else
    AO=$(grep -rhs -A5 -- "$PARENT" /etc/apache2/sites-enabled /etc/httpd/conf.d 2>/dev/null \
         | grep -m1 -i 'AllowOverride' | awk '{print $2}')
    case "${AO:-unset}" in
      All|all) ok "AllowOverride All" ;;
      *) warn "AllowOverride ${AO:-nicht gefunden} - die Datei wird moeglicherweise ignoriert" ;;
    esac
  fi

  # --- eigene Regeln aus der bestehenden Datei klassifizieren --------------
  CUSTOM=""; DROPPED=""; KEPT_PHP=0
  if [[ -f "$TARGET" ]]; then
    RAW=$(awk '
      /# BEGIN WordPress/            { inwp=1 }
      /# END WordPress/              { inwp=0; next }
      inwp                           { next }
      /---- Absicherung/             { inown=1 }
      /---- Ende Absicherung/        { inown=0; next }
      inown                          { next }
      { print }
    ' "$TARGET" | sed -E '/^[[:space:]]*$/d')

    declare -A CAT_COUNT=()
    while IFS= read -r L; do
      [[ -z "$L" ]] && continue
      C=$(classify_line "$L")
      CAT_COUNT[$C]=$(( ${CAT_COUNT[$C]:-0} + 1 ))
      case "$C" in
        gefaehrlich)
          DROPPED+="[gefaehrlich] $L"$'\n' ;;
        options-risiko)
          # Nie uebernehmen: braucht AllowOverride Options, sonst 500
          DROPPED+="[Options braucht AllowOverride Options] $L"$'\n' ;;
        php-handler)
          KEPT_PHP=1
          CUSTOM+="$L"$'\n' ;;
        externe-weiterleitung|unbekannt)
          if [[ $STRICT -eq 1 ]]; then
            DROPPED+="[--strict] $L"$'\n'
          else
            CUSTOM+="$L"$'\n'
          fi ;;
        *)
          if [[ $STRICT -eq 1 ]]; then
            DROPPED+="[--strict] $L"$'\n'
          else
            CUSTOM+="$L"$'\n'
          fi ;;
      esac
    done <<< "$RAW"

    if [[ -n "$RAW" ]]; then
      note "vorhandene eigene Zeilen nach Kategorie:"
      for K in "${!CAT_COUNT[@]}"; do printf '      %-22s %s\n' "$K" "${CAT_COUNT[$K]}"; done
    else
      ok "keine eigenen Regeln vorhanden"
    fi
    [[ $KEPT_PHP -eq 1 ]] && ok "PHP-Handler gefunden - wird in jedem Fall uebernommen"
    if [[ -n "$DROPPED" ]]; then
      warn "diese Zeilen werden NICHT uebernommen:"
      echo "$DROPPED" | sed -E '/^\s*$/d' | head -10 | sed 's/^/      /'
    fi
    if [[ -n "$CUSTOM" ]]; then
      CLINES=$(grep -c . <<<"$CUSTOM")
      note "uebernommen werden ${CLINES} Zeile(n):"
      echo "$CUSTOM" | head -12 | sed 's/^/      /'
      [[ "$CLINES" -gt 12 ]] && note "      ... und $((CLINES - 12)) weitere Zeilen"
    fi
  else
    note ".htaccess existiert noch nicht"
  fi

  # --- Inhalt zusammenbauen ------------------------------------------------
  NEW=$(mktemp)
  {
    if [[ -n "$CUSTOM" ]]; then
      echo "# ---- uebernommen aus der bisherigen .htaccess ----"
      echo "$CUSTOM"
      echo
    fi
    common_rules "$BLOCK_XMLRPC"
    echo
    wp_block "$RBASE" "$RIDX"
  } > "$NEW"

  if [[ $APPLY -eq 0 ]]; then
    note "wuerde schreiben: ${TARGET} ($(wc -l < "$NEW") Zeilen)"
    note "wuerde schreiben: ${WP_PATH}/wp-content/uploads/.htaccess"
    rm -f "$NEW"
    continue
  fi

  # --- sichern -------------------------------------------------------------
  if [[ -f "$TARGET" ]]; then
    B="${BACKUP_DIR}/$(echo "$TARGET" | tr '/' '_')-${STAMP}"
    cp -p "$TARGET" "$B"
    echo "$TARGET" > "${B}.meta"
    ok "gesichert: ${B}"
  fi

  # --- schreiben -----------------------------------------------------------
  install -m 644 -o "$SITE_USER" -g "$SITE_GROUP" "$NEW" "$TARGET"
  rm -f "$NEW"

  UPL_DIR="${WP_PATH}/wp-content/uploads"
  if [[ -d "$UPL_DIR" ]]; then
    [[ -f "${UPL_DIR}/.htaccess" ]] && cp -p "${UPL_DIR}/.htaccess" \
        "${BACKUP_DIR}/$(echo "${UPL_DIR}/.htaccess" | tr '/' '_')-${STAMP}"
    uploads_rules > "${UPL_DIR}/.htaccess"
    chown "$SITE_USER:$SITE_GROUP" "${UPL_DIR}/.htaccess"
    chmod 644 "${UPL_DIR}/.htaccess"
    ok "uploads/.htaccess geschrieben"
  else
    warn "uploads-Verzeichnis nicht gefunden"
  fi

  # --- pruefen -------------------------------------------------------------
  if ! apachectl configtest >/dev/null 2>&1; then
    bad "apachectl configtest schlaegt fehl - Rueckrollung"
    [[ -n "${B:-}" && -f "${B:-}" ]] && cp -p "$B" "$TARGET"
    FAILED=$((FAILED+1)); continue
  fi

  if [[ -n "$SITE_URL" && -n "$BEFORE" ]]; then
    sleep 1
    AFTER=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "${SITE_URL}/?nocache=$RANDOM")
    AFTER_CORE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "${CORE_URL}/wp-includes/js/jquery/jquery.min.js?nocache=$RANDOM")
    note "HTTP nachher: Startseite ${AFTER}, Asset im Kern ${AFTER_CORE}"

    DEGRADED=0
    [[ "$BEFORE"      =~ ^(200|301|302)$ && ! "$AFTER"      =~ ^(200|301|302)$ ]] && DEGRADED=1
    [[ "$BEFORE_CORE" =~ ^(200|301|302)$ && ! "$AFTER_CORE" =~ ^(200|301|302)$ ]] && DEGRADED=1

    if [[ $DEGRADED -eq 1 ]]; then
      bad "Seite oder Assets antworten nach der Aenderung schlechter - Rueckrollung"
      # Der Grund steht im Apache-Fehlerlog, typischerweise eine Options-Direktive,
      # die AllowOverride nicht zulaesst.
      ERRL=$(grep -h "$WP_PATH" /var/log/apache2/*error*.log /var/log/httpd/*error*.log 2>/dev/null | tail -2)
      [[ -n "$ERRL" ]] && { note "  Apache meldet:"; echo "$ERRL" | sed 's/^/      /'; }
      if [[ -n "${B:-}" && -f "${B:-}" ]]; then
        cp -p "$B" "$TARGET"; ok "alte .htaccess wiederhergestellt"
      else
        rm -f "$TARGET"; ok ".htaccess entfernt (es gab vorher keine)"
      fi
      [[ -f "${UPL_DIR}/.htaccess" ]] && rm -f "${UPL_DIR}/.htaccess" && ok "uploads/.htaccess entfernt"
      FAILED=$((FAILED+1)); continue
    fi
  fi

  # --- Wirksamkeitstest: laesst sich PHP in uploads noch ausfuehren? -------
  if [[ -n "$SITE_URL" && -d "$UPL_DIR" ]]; then
    PROBE="hardening-probe-$RANDOM.php"
    printf '<?php echo "PHP-AUSFUEHRUNG-MOEGLICH"; ' > "${UPL_DIR}/${PROBE}"
    chown "$SITE_USER:$SITE_GROUP" "${UPL_DIR}/${PROBE}"
    URLPATH="${SITE_URL}${SUB:+/$SUB}/wp-content/uploads/${PROBE}"
    RESP=$(curl -s --max-time 15 "$URLPATH")
    if echo "$RESP" | grep -q 'PHP-AUSFUEHRUNG-MOEGLICH'; then
      bad "PHP in uploads wird WEITERHIN ausgefuehrt - AllowOverride pruefen!"
      note "  getestet: ${URLPATH}"
    else
      ok "PHP in uploads wird nicht ausgefuehrt"
    fi
    rm -f "${UPL_DIR}/${PROBE}"
  fi

  CHANGED=$((CHANGED+1))
done

hr "Ergebnis"
printf '  geaendert: %d   uebersprungen: %d   zurueckgerollt: %d\n' "$CHANGED" "$SKIPPED" "$FAILED"
if [[ $APPLY -eq 1 ]]; then
  printf '  Sicherungen: %s\n' "$BACKUP_DIR"
  printf '  Zuruecknehmen: %s --restore\n' "$0"
  echo
  echo "  Noch von Hand pruefen:"
  echo "    - Permalinks in wp-admin einmal speichern (Einstellungen -> Permalinks)"
  echo "    - Login, Medien-Upload und Block-Editor kurz testen"
  echo "    - bei aktivem Caching-Plugin dessen Regeln neu schreiben lassen"
else
  printf '  Mit --apply ausfuehren, um die Dateien zu schreiben.\n'
fi
