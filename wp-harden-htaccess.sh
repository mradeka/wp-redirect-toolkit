#!/usr/bin/env bash
#
# wp-harden-htaccess.sh
#
# Writes a hardened .htaccess into every WordPress install under
# /home/<user>/public_html[/wordpress] - plus a second one in
# wp-content/uploads/ that prevents execution of uploaded scripts.
#
# Why this is riskier than the other scripts, and what is done about it:
# A broken .htaccess takes the site offline immediately. Therefore
#   1. the existing file is backed up,
#   2. custom rewrite rules are carried over instead of overwritten,
#   3. the layout is detected (webroot or subdirectory) and RewriteBase
#      is set accordingly,
#   4. the HTTP status is measured BEFORE and AFTER the change, with an
#      automatic rollback if it gets worse.
#
# DRY RUN unless --apply is given.
#
# Usage:
#   ./wp-harden-htaccess.sh --inventory          # FIRST: what is actually in there?
#   ./wp-harden-htaccess.sh                      # dry run
#   ./wp-harden-htaccess.sh --only siteuser
#   ./wp-harden-htaccess.sh --apply
#   ./wp-harden-htaccess.sh --apply --strict     # carry over PHP handlers only
#   ./wp-harden-htaccess.sh --apply --no-xmlrpc-block   # leave XML-RPC open
#   ./wp-harden-htaccess.sh --restore            # restore the last backup
#
# Why existing files are not simply deleted:
# On fcgid sites the PHP version lives in .htaccess (AddHandler/AddType).
# If that line disappears the site falls back to the server default - or PHP
# stops running entirely and the browser downloads the source.
# Conversely, nothing may be carried over blindly either: after an incident
# an injected rule may sit in there. Every line is therefore classified
# - see --inventory.

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
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Classification of custom rules
#
# Why not carry everything over: after an incident an injected rule may sit
# in a .htaccess. Why not delete everything: on fcgid sites the PHP version
# lives there. If that line disappears the site runs with the server
# default - or PHP stops running entirely and the browser downloads the
# source.
# ---------------------------------------------------------------------------
classify_line() {
  local L="$1"
  case "$L" in
    ''|'#'*) echo "comment"; return ;;
  esac
  # 1. Clearly malicious - checked FIRST. Otherwise "php_value
  #    auto_prepend_file" looks like a harmless PHP handler and would be
  #    carried over, although that is exactly how malicious code gets loaded
  #    on every request.
  if grep -qiE 'auto_prepend_file|auto_append_file|base64_decode|eval\(|include_path\s*=|\bpython\b|\bperl\b.*-e' <<<"$L"; then
    echo "dangerous"; return
  fi
  # 2. Must be preserved - otherwise PHP or the panel config breaks
  if grep -qiE '^\s*(AddHandler|AddType|FCGIWrapper|Action|SetHandler|php_value|php_admin_value|php_flag|php_admin_flag|suPHP)' <<<"$L"; then
    echo "php-handler"; return
  fi
  # Redirect to a foreign domain
  if grep -qiE '^\s*(RewriteRule|Redirect|RedirectMatch|RedirectPermanent)\b.*https?://' <<<"$L"; then
    echo "external-redirect"; return
  fi
  # Options directives need "AllowOverride Options" or "All". Panels usually
  # set a whitelist there without FollowSymLinks/ExecCGI/Includes. If such a
  # line sits in the old file it may have worked there - but after a vhost
  # change Apache answers with
  #     Option FollowSymLinks not allowed here
  # and returns 500 for everything below. So it is not carried over.
  if grep -qiE '^\s*Options\b' <<<"$L"; then
    if grep -qiE '^\s*Options\s+-Indexes\s*$' <<<"$L"; then
      echo "standard"; return
    fi
    echo "options-risk"; return
  fi
  # 3. Common, uncritical categories
  grep -qiE '^\s*(Redirect|RedirectMatch|RedirectPermanent|RedirectTemp)\b' <<<"$L" && { echo "redirect"; return; }
  grep -qiE '^\s*(RewriteEngine|RewriteBase|RewriteCond|RewriteRule|RewriteOptions)' <<<"$L" && { echo "rewrite"; return; }
  grep -qiE '^\s*(<Files|<FilesMatch|<Directory|<DirectoryMatch|<Limit|<LimitExcept|Require|Order|Allow|Deny|Auth|Satisfy)' <<<"$L" && { echo "access"; return; }
  grep -qiE '^\s*(Header|RequestHeader|ExpiresByType|ExpiresActive|ExpiresDefault|AddOutputFilter|AddEncoding|AddCharset|BrowserMatch|Options|AddDefaultCharset|ErrorDocument|DirectoryIndex|FileETag|<IfModule|<If|</)' <<<"$L" && { echo "standard"; return; }
  echo "unknown"
}

[[ $EUID -ne 0 ]] && { echo "Run as root."; exit 1; }

hr()   { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { printf '\033[32m  [ok] %s\033[0m\n' "$*"; }
warn() { printf '\033[33m  [!] %s\033[0m\n' "$*"; }
bad()  { printf '\033[31m  [FEHLER] %s\033[0m\n' "$*"; }
note() { printf '  %s\n' "$*"; }

mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"

# ---------------------------------------------------------------------------
# Templates
# ---------------------------------------------------------------------------
common_rules() {   # $1 = 1 if xmlrpc should be blocked
cat <<'HEAD'
# ---- hardening (generated by wp-harden-htaccess) ---------------------------
# Only -Indexes. Every Options directive needs "AllowOverride Options" or
# "All"; panels usually set a whitelist WITHOUT FollowSymLinks. Apache then
# answers a "+FollowSymLinks" with
#     Option FollowSymLinks not allowed here
# and returns 500 for everything below the directory - including CSS.
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
    # HSTS deliberately disabled - only enable once HTTPS runs on all
    # subdomains; there is no way back during max-age:
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
# ---- end hardening ---------------------------------------------------------
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
# ---- generated by wp-harden-htaccess ---------------------------------------
# No execution of uploaded scripts.
#
# IMPORTANT with mod_fcgid / suexec (Virtualmin, Plesk, cPanel):
# There PHP runs via "AddHandler fcgid-script .php" from the vhost. An
# "AddType text/plain .php" in this file overrides that mapping and breaks
# PHP processing for the whole directory tree - uploads then fail with
# "could not be moved". RemoveHandler is correct: it drops the mapping for
# this directory only.
<IfModule mod_mime.c>
    RemoveHandler .php .php3 .php4 .php5 .php7 .php8 .php8.0 .php8.1 .php8.2 .php8.3 .php8.4 .phtml .phps .phar .pht
</IfModule>

# Plus direct access protection. Script extensions only - images, PDFs and
# everything else stay reachable.
<FilesMatch "\.(php|php[0-9]|php[0-9]\.[0-9]|phtml|phps|pht|phar|shtml|cgi|pl|py|asp|aspx)$">
    Require all denied
</FilesMatch>

# Double extensions ("image.php.jpg") are still executed as PHP on some
# servers - so block any script extension ANYWHERE in the name.
<FilesMatch "\.(php|php[0-9]|phtml|phps|pht|phar|shtml|cgi|pl|py)\.">
    Require all denied
</FilesMatch>

# Deliberately only -Indexes: -ExecCGI/-Includes would need "AllowOverride
# Options", which many panels grant only through a whitelist.
Options -Indexes
UPL
}

# ---------------------------------------------------------------------------
# Restore
# ---------------------------------------------------------------------------
if [[ $RESTORE -eq 1 ]]; then
  hr "Restoring backups"
  FOUND=0
  while IFS= read -r META; do
    TARGET=$(head -1 "$META")
    DATA="${META%.meta}"
    [[ -f "$DATA" && -n "$TARGET" ]] || continue
    cp -p "$DATA" "$TARGET" && ok "restored: $TARGET" && FOUND=1
  done < <(find "$BACKUP_DIR" -name '*.meta' -newermt '-30 days' | sort | tail -50)
  [[ $FOUND -eq 0 ]] && warn "no backups found in ${BACKUP_DIR}"
  apachectl configtest 2>&1 | tail -1
  exit 0
fi

# ---------------------------------------------------------------------------
# Find installations
# ---------------------------------------------------------------------------
hr "Installations"
mapfile -t CONFIGS < <(
  ls -d /home/*/public_html/wordpress/wp-config.php \
        /home/*/public_html/wp-config.php 2>/dev/null | sort -u
)
[[ ${#CONFIGS[@]} -eq 0 ]] && { echo "No WordPress installations found."; exit 0; }

# ---------------------------------------------------------------------------
# Inventory mode: know what is there before deciding
# ---------------------------------------------------------------------------
if [[ $INVENTORY -eq 1 ]]; then
  hr "Inventory of existing .htaccess files"
  declare -A TOTAL=()
  for CONFIG in "${CONFIGS[@]}"; do
    WP_PATH=$(dirname "$CONFIG")
    SITE_USER=$(echo "$CONFIG" | sed -nE 's#^/home/([^/]+)/.*#\1#p')
    { [[ -z "$SITE_USER" ]] || ! getent passwd "$SITE_USER" >/dev/null; } \
      && SITE_USER=$(stat -c '%U' "$CONFIG")
    [[ -n "$ONLY" && "$SITE_USER" != "$ONLY" ]] && continue
    F="${WP_PATH}/.htaccess"
    printf '\n\033[1m%s\033[0m  (%s)\n' "$WP_PATH" "$SITE_USER"
    if [[ ! -f "$F" ]]; then
      printf '  no .htaccess present\n'
      TOTAL[fehlt]=$(( ${TOTAL[fehlt]:-0} + 1 ))
      continue
    fi
    printf '  %s lines, modified %s\n' "$(wc -l < "$F")" "$(stat -c '%y' "$F" | cut -c1-16)"
    RAW=$(awk '
      /# BEGIN WordPress/ { inwp=1 } /# END WordPress/ { inwp=0; next } inwp { next }
      /---- (Absicherung|hardening \(generated)/  { inown=1 }
      /---- (Ende Absicherung|end hardening)/     { inown=0; next }
      inown { next }
      { print }' "$F" | sed -E '/^[[:space:]]*$/d')
    if [[ -z "$RAW" ]]; then
      printf '  standard blocks only, nothing custom\n'
      TOTAL[standard]=$(( ${TOTAL[standard]:-0} + 1 ))
      continue
    fi
    while IFS= read -r L; do
      [[ -z "$L" ]] && continue
      C=$(classify_line "$L")
      TOTAL[$C]=$(( ${TOTAL[$C]:-0} + 1 ))
      case "$C" in
        comment) continue ;;
        php-handler)          printf '\033[33m  [PHP-HANDLER] %s\033[0m\n' "$L" ;;
        dangerous)          printf '\033[31m  [DANGEROUS] %s\033[0m\n' "$L" ;;
        external-redirect) printf '  [ext. redirect] %s\n' "$L" ;;
        unknown)            printf '\033[33m  [unknown]     %s\033[0m\n' "$L" ;;
        *)                    printf '  [%s] %s\n' "$C" "$L" ;;
      esac
    done <<< "$RAW"
  done

  hr "Totals across all sites"
  for K in "${!TOTAL[@]}"; do printf '  %-22s %s\n' "$K" "${TOTAL[$K]}"; done
  cat <<'NEXT'

  How to read this:
    PHP-HANDLER  sets the PHP version for this site (fcgid). If the line
                 disappears the site runs with the server default - or PHP
                 stops running at all. Always carried over.
                 Better long term: set the PHP version in the panel or vhost,
                 then .htaccess no longer depends on it.
    DANGEROUS    never carried over. After an incident, inspect the line
                 before reusing it anywhere.
    unknown      inspect manually - usually plugin blocks or handcrafted.

  Next:
    wp-harden-htaccess              dry run with classified carry-over
    wp-harden-htaccess --strict     carry over PHP handlers only
NEXT
  exit 0
fi

[[ $APPLY -eq 1 ]] && warn "APPLY MODE - files will be written" \
                   || ok "DRY RUN - nothing is changed"

STAMP=$(date +%F-%H%M%S)
CHANGED=0; SKIPPED=0; FAILED=0

for CONFIG in "${CONFIGS[@]}"; do
  WP_PATH=$(dirname "$CONFIG")
  # Derive from the PATH, not from wp-config.php - see wp-fix-ownership.
  SITE_USER=$(echo "$CONFIG" | sed -nE 's#^/home/([^/]+)/.*#\1#p')
  { [[ -z "$SITE_USER" ]] || ! getent passwd "$SITE_USER" >/dev/null; } \
    && SITE_USER=$(stat -c '%U' "$CONFIG")
  SITE_GROUP=$(stat -c '%G' "$CONFIG")
  [[ -n "$ONLY" && "$SITE_USER" != "$ONLY" ]] && continue

  hr "${WP_PATH}  (${SITE_USER})"

  # --- determine layout ----------------------------------------------------
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
  note "layout: ${LAYOUT}   RewriteBase: ${RBASE}"

  # --- public URL for the before/after test -------------------
  WPBIN=""
  for CAND in "/home/${SITE_USER}/wp" "/home/${SITE_USER}/.wp-cli.phar" /usr/local/bin/wp; do
    sudo -u "$SITE_USER" -H test -r "$CAND" 2>/dev/null && { WPBIN="$CAND"; break; }
  done
  SITE_URL=""
  [[ -n "$WPBIN" ]] && SITE_URL=$(sudo -u "$SITE_USER" -H "$WPBIN" --path="$WP_PATH" \
                                  --skip-plugins --skip-themes option get home 2>/dev/null)
  if [[ -n "$SITE_URL" ]]; then
    # For subdirectory installs the .htaccess written is NOT in the webroot.
    # Checking only the home page would miss a 500 in the core directory -
    # which is exactly where CSS and JS then go missing.
    CORE_URL="${SITE_URL%/}${SUB:+/$SUB}"
    BEFORE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "${SITE_URL}/?nocache=$RANDOM")
    BEFORE_CORE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "${CORE_URL}/wp-includes/js/jquery/jquery.min.js?nocache=$RANDOM")
    note "HTTP before: home ${BEFORE}, core asset ${BEFORE_CORE}  (${SITE_URL})"
  else
    BEFORE=""; BEFORE_CORE=""; CORE_URL=""
    warn "public URL not determinable - no before/after test possible"
  fi

  # --- AllowOverride -------------------------------------------------------
  if ! grep -rqs -- "$PARENT" /etc/apache2/sites-enabled /etc/httpd/conf.d 2>/dev/null; then
    warn "no vhost references ${PARENT} - please check AllowOverride yourself"
  else
    AO=$(grep -rhs -A5 -- "$PARENT" /etc/apache2/sites-enabled /etc/httpd/conf.d 2>/dev/null \
         | grep -m1 -i 'AllowOverride' | awk '{print $2}')
    case "${AO:-unset}" in
      All|all) ok "AllowOverride All" ;;
      *) warn "AllowOverride ${AO:-not found} - the file may be ignored" ;;
    esac
  fi

  # --- classify custom rules from the existing file --------------
  CUSTOM=""; DROPPED=""; KEPT_PHP=0
  if [[ -f "$TARGET" ]]; then
    RAW=$(awk '
      /# BEGIN WordPress/            { inwp=1 }
      /# END WordPress/              { inwp=0; next }
      inwp                           { next }
      /---- (Absicherung|hardening \(generated)/ { inown=1 }
      /---- (Ende Absicherung|end hardening)/    { inown=0; next }
      inown                          { next }
      { print }
    ' "$TARGET" | sed -E '/^[[:space:]]*$/d')

    declare -A CAT_COUNT=()
    while IFS= read -r L; do
      [[ -z "$L" ]] && continue
      C=$(classify_line "$L")
      CAT_COUNT[$C]=$(( ${CAT_COUNT[$C]:-0} + 1 ))
      case "$C" in
        dangerous)
          DROPPED+="[dangerous] $L"$'\n' ;;
        options-risk)
          # Never carried over: needs AllowOverride Options, otherwise 500
          DROPPED+="[Options needs AllowOverride Options] $L"$'\n' ;;
        php-handler)
          KEPT_PHP=1
          CUSTOM+="$L"$'\n' ;;
        external-redirect|unknown)
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
      note "existing custom lines by category:"
      for K in "${!CAT_COUNT[@]}"; do printf '      %-22s %s\n' "$K" "${CAT_COUNT[$K]}"; done
    else
      ok "no custom rules present"
    fi
    [[ $KEPT_PHP -eq 1 ]] && ok "PHP handler found - always carried over"
    if [[ -n "$DROPPED" ]]; then
      warn "these lines will NOT be carried over:"
      echo "$DROPPED" | sed -E '/^\s*$/d' | head -10 | sed 's/^/      /'
    fi
    if [[ -n "$CUSTOM" ]]; then
      CLINES=$(grep -c . <<<"$CUSTOM")
      note "carrying over ${CLINES} line(s):"
      echo "$CUSTOM" | head -12 | sed 's/^/      /'
      [[ "$CLINES" -gt 12 ]] && note "      ... and $((CLINES - 12)) more lines"
    fi
  else
    note "no .htaccess yet"
  fi

  # --- assemble content ------------------------------------------------
  NEW=$(mktemp)
  {
    if [[ -n "$CUSTOM" ]]; then
      echo "# ---- carried over from the previous .htaccess ----"
      echo "$CUSTOM"
      echo
    fi
    common_rules "$BLOCK_XMLRPC"
    echo
    wp_block "$RBASE" "$RIDX"
  } > "$NEW"

  if [[ $APPLY -eq 0 ]]; then
    note "would write: ${TARGET} ($(wc -l < "$NEW") lines)"
    note "would write: ${WP_PATH}/wp-content/uploads/.htaccess"
    rm -f "$NEW"
    continue
  fi

  # --- back up -------------------------------------------------------------
  if [[ -f "$TARGET" ]]; then
    B="${BACKUP_DIR}/$(echo "$TARGET" | tr '/' '_')-${STAMP}"
    cp -p "$TARGET" "$B"
    echo "$TARGET" > "${B}.meta"
    ok "backed up: ${B}"
  fi

  # --- write -----------------------------------------------------------
  install -m 644 -o "$SITE_USER" -g "$SITE_GROUP" "$NEW" "$TARGET"
  rm -f "$NEW"

  UPL_DIR="${WP_PATH}/wp-content/uploads"
  if [[ -d "$UPL_DIR" ]]; then
    [[ -f "${UPL_DIR}/.htaccess" ]] && cp -p "${UPL_DIR}/.htaccess" \
        "${BACKUP_DIR}/$(echo "${UPL_DIR}/.htaccess" | tr '/' '_')-${STAMP}"
    uploads_rules > "${UPL_DIR}/.htaccess"
    chown "$SITE_USER:$SITE_GROUP" "${UPL_DIR}/.htaccess"
    chmod 644 "${UPL_DIR}/.htaccess"
    ok "uploads/.htaccess written"
  else
    warn "uploads directory not found"
  fi

  # --- verify -------------------------------------------------------------
  if ! apachectl configtest >/dev/null 2>&1; then
    bad "apachectl configtest fails - rolling back"
    [[ -n "${B:-}" && -f "${B:-}" ]] && cp -p "$B" "$TARGET"
    FAILED=$((FAILED+1)); continue
  fi

  if [[ -n "$SITE_URL" && -n "$BEFORE" ]]; then
    sleep 1
    AFTER=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "${SITE_URL}/?nocache=$RANDOM")
    AFTER_CORE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "${CORE_URL}/wp-includes/js/jquery/jquery.min.js?nocache=$RANDOM")
    note "HTTP after: home ${AFTER}, core asset ${AFTER_CORE}"

    DEGRADED=0
    [[ "$BEFORE"      =~ ^(200|301|302)$ && ! "$AFTER"      =~ ^(200|301|302)$ ]] && DEGRADED=1
    [[ "$BEFORE_CORE" =~ ^(200|301|302)$ && ! "$AFTER_CORE" =~ ^(200|301|302)$ ]] && DEGRADED=1

    if [[ $DEGRADED -eq 1 ]]; then
      bad "site or assets respond worse after the change - rolling back"
      # The reason is in the Apache error log, typically an Options directive
      # that AllowOverride does not permit.
      ERRL=$(grep -h "$WP_PATH" /var/log/apache2/*error*.log /var/log/httpd/*error*.log 2>/dev/null | tail -2)
      [[ -n "$ERRL" ]] && { note "  Apache reports:"; echo "$ERRL" | sed 's/^/      /'; }
      if [[ -n "${B:-}" && -f "${B:-}" ]]; then
        cp -p "$B" "$TARGET"; ok "previous .htaccess restored"
      else
        rm -f "$TARGET"; ok ".htaccess removed (there was none before)"
      fi
      [[ -f "${UPL_DIR}/.htaccess" ]] && rm -f "${UPL_DIR}/.htaccess" && ok "uploads/.htaccess removed"
      FAILED=$((FAILED+1)); continue
    fi
  fi

  # --- effectiveness test: can PHP in uploads still run? -------
  if [[ -n "$SITE_URL" && -d "$UPL_DIR" ]]; then
    PROBE="hardening-probe-$RANDOM.php"
    printf '<?php echo "PHP-AUSFUEHRUNG-MOEGLICH"; ' > "${UPL_DIR}/${PROBE}"
    chown "$SITE_USER:$SITE_GROUP" "${UPL_DIR}/${PROBE}"
    URLPATH="${SITE_URL}${SUB:+/$SUB}/wp-content/uploads/${PROBE}"
    RESP=$(curl -s --max-time 15 "$URLPATH")
    if echo "$RESP" | grep -q 'PHP-AUSFUEHRUNG-MOEGLICH'; then
      bad "PHP in uploads is STILL executed - check AllowOverride!"
      note "  tested: ${URLPATH}"
    else
      ok "PHP in uploads is not executed"
    fi
    rm -f "${UPL_DIR}/${PROBE}"
  fi

  CHANGED=$((CHANGED+1))
done

hr "Result"
printf '  changed: %d   skipped: %d   rolled back: %d\n' "$CHANGED" "$SKIPPED" "$FAILED"
if [[ $APPLY -eq 1 ]]; then
  printf '  backups: %s\n' "$BACKUP_DIR"
  printf '  to undo: %s --restore\n' "$0"
  echo
  echo "  Still to do by hand:"
  echo "    - save permalinks once in wp-admin (Settings -> Permalinks)"
  echo "    - test login, media upload and the block editor"
  echo "    - if a caching plugin is active, have it rewrite its rules"
else
  printf '  Re-run with --apply to write the files.\n'
fi
