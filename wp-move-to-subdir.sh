#!/usr/bin/env bash
#
# wp-move-to-subdir.sh
#
# Moves a WordPress install from /home/SITE/public_html into
# /home/SITE/public_html/wordpress, using WordPress's own supported
# "Giving WordPress its own directory" layout:
#
#   public_html/wordpress/   <- core, wp-admin, wp-includes, wp-content
#   public_html/index.php    <- loader, points at wordpress/wp-blog-header.php
#   public_html/.htaccess    <- rewrite rules, root stays the public URL
#
#   siteurl -> https://domain/wordpress   (where core lives)
#   home    -> https://domain             (what visitors type) - UNCHANGED
#
# THIS IS NOT PART OF MALWARE CLEANUP. It is a layout change, it touches
# every file of a live site, and a half-finished move takes the site down.
# Run it on one site at a time, when you can watch the result.
#
# DRY RUN unless you pass --apply. A file backup and a DB dump are written
# first in either mode.
#
# Usage:
#   ./wp-move-to-subdir.sh --path /home/SITE/public_html [--dir wordpress]
#   ./wp-move-to-subdir.sh --path /home/SITE/public_html --apply

set -uo pipefail

SRC=""
SUBDIR="wordpress"
APPLY=0
SKIP_APACHE=0
WP_BIN="${WP_BIN:-wp}"

usage() { sed -n '2,28p' "$0"; exit "${1:-1}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --path)   SRC="${2%/}"; shift 2 ;;
    --dir)    SUBDIR="$2"; shift 2 ;;
    --wp-bin) WP_BIN="$2"; shift 2 ;;
    --apply)  APPLY=1; shift ;;
    --skip-apache-check) SKIP_APACHE=1; shift ;;
    -h|--help) usage 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done
[[ -z "$SRC" ]] && usage

hr()   { printf '\n\033[1m== %s\033[0m\n' "$*"; }
warn() { printf '\033[33m[!] %s\033[0m\n' "$*"; }
ok()   { printf '\033[32m[ok] %s\033[0m\n' "$*"; }
die()  { printf '\033[31m[abort] %s\033[0m\n' "$*"; exit 1; }

DST="${SRC}/${SUBDIR}"
WP="${WP_BIN} --path=${SRC} --skip-plugins --skip-themes"

# ---------------------------------------------------------------------------
hr "Preflight"
[[ -f "${SRC}/wp-config.php" ]] || die "No wp-config.php in ${SRC} - nothing to move (already a subdir install?)"
[[ -e "$DST" ]] && die "${DST} already exists - refusing to merge into it"
# Derive from the PATH, not from wp-config.php - if that file is owned by root
# the move would recreate everything as root.
SITE_USER=$(echo "$SRC" | sed -nE 's#^/home/([^/]+)/.*#\1#p')
{ [[ -z "$SITE_USER" ]] || ! getent passwd "$SITE_USER" >/dev/null; } \
  && SITE_USER=$(stat -c '%U' "${SRC}/wp-config.php")
SITE_GROUP=$(stat -c '%G' "${SRC}/wp-config.php")
[[ $EUID -ne 0 && "$(id -un)" != "$SITE_USER" ]] && die "Run as root or as ${SITE_USER}"

HOME_URL=$($WP option get home 2>/dev/null)   || die "WP-CLI cannot read this install"
SITE_URL=$($WP option get siteurl 2>/dev/null)
echo "source  : ${SRC}"
echo "target  : ${DST}"
echo "owner   : ${SITE_USER}:${SITE_GROUP}"
echo "home    : ${HOME_URL}"
echo "siteurl : ${SITE_URL}"
NEW_SITEURL="${HOME_URL%/}/${SUBDIR}"
echo "siteurl will become: ${NEW_SITEURL}"
[[ $APPLY -eq 1 ]] && warn "APPLY MODE" || ok "DRY RUN - no changes"

# ---------------------------------------------------------------------------
# AllowOverride: without it the root .htaccess is silently ignored and the
# whole move ends in a 404 or a directory listing. Check before touching
# anything, because this is the single most common cause of a failed move.
# ---------------------------------------------------------------------------
hr "Apache: AllowOverride for ${SRC}"
AO_OK=0
if [[ $SKIP_APACHE -eq 1 ]]; then
  warn "--skip-apache-check given - not verifying AllowOverride"
  AO_OK=1
  VHOSTS=""
else
VHOSTS=$(grep -rl -- "$SRC" /etc/apache2/sites-enabled /etc/apache2/conf-enabled \
                            /etc/httpd/conf.d /etc/httpd/conf/httpd.conf 2>/dev/null | sort -u)
if [[ -z "$VHOSTS" ]]; then
  warn "no vhost file references ${SRC} - check your web server config by hand"
else
  for V in $VHOSTS; do
    echo "  vhost: ${V}"
    # the AllowOverride that applies to this docroot, last one wins
    AO=$(awk -v d="$SRC" '
      /<Directory/           { indir = index($0, d) > 0 }
      /<\/Directory>/        { indir = 0 }
      indir && /AllowOverride/ { val = $2 }
      END { print val }' "$V")
    # a parent <Directory /home> or /var/www block can also grant it
    [[ -z "$AO" ]] && AO=$(grep -hs 'AllowOverride' "$V" | tail -1 | awk '{print $2}')
    case "${AO:-unset}" in
      All|all|FileInfo*|Options*Indexes*) ok "  AllowOverride ${AO}"; AO_OK=1 ;;
      None|none) warn "  AllowOverride None - the root .htaccess will be IGNORED" ;;
      unset)     warn "  no AllowOverride found for this path - Apache defaults to None" ;;
      *)         warn "  AllowOverride ${AO} - may be too narrow; 'All' is what WP expects" ;;
    esac
  done
fi
fi
if [[ $AO_OK -eq 0 ]]; then
  cat <<AOFIX
  Add this to the vhost (then: apachectl configtest && systemctl reload apache2):

      <Directory ${SRC}>
          AllowOverride All
          Require all granted
      </Directory>

AOFIX
  if [[ $APPLY -eq 1 ]]; then
    die "refusing to move while the root .htaccess would be ignored - fix AllowOverride first, or re-run with --skip-apache-check"
  fi
fi


# Anything in public_html that is NOT WordPress stays put. List it so you can
# see what the move leaves behind at the root.
hr "Non-WordPress items at the root (these stay where they are)"
find "$SRC" -maxdepth 1 -mindepth 1 \
     ! -name 'wp-*' ! -name 'index.php' ! -name 'xmlrpc.php' \
     ! -name 'license.txt' ! -name 'readme.html' ! -name '.htaccess' \
     ! -name "$SUBDIR" -printf '  %f\n' 2>/dev/null || echo "  (none)"

# ---------------------------------------------------------------------------
# Existing .htaccess: WordPress regenerates its own block, but hand-written
# rules must survive - except the ones that point at directories which do not
# exist. Those are leftovers from a template (the classic '/my_subdir/') and
# they either do nothing or misroute requests after the move.
# ---------------------------------------------------------------------------
hr "Existing .htaccess"
STALE_RE=""
if [[ -f "${SRC}/.htaccess" ]]; then
  # collect RewriteRule targets that look like local paths
  while read -r TGT; do
    [[ -z "$TGT" ]] && continue
    case "$TGT" in
      -|/index.php|index.php|*'%{'*|http*|'-'*) continue ;;
    esac
    BASE=$(echo "$TGT" | sed -E 's#^/##; s#\$[0-9].*$##; s#/.*$##')
    [[ -z "$BASE" ]] && continue
    if [[ ! -e "${SRC}/${BASE}" && "$BASE" != "$SUBDIR" ]]; then
      warn "stale rule: target /${BASE}/ does not exist"
      STALE_RE="${STALE_RE}${STALE_RE:+|}${BASE}"
    fi
  done < <(awk '/^[[:space:]]*RewriteRule/ {print $3}' "${SRC}/.htaccess")

  # everything that is neither the WP block nor a stale rule group is custom
  CUSTOM=$(awk -v stale="$STALE_RE" -v coredir="$SUBDIR" '
    BEGIN { drop = (stale != "") }
    /# BEGIN WordPress/ { inwp = 1 }
    /# END WordPress/   { inwp = 0; next }
    inwp { next }
    # buffer RewriteCond lines: they belong to the RewriteRule that follows
    /^[[:space:]]*RewriteCond/ { cond = cond $0 "\n"; next }
    /^[[:space:]]*RewriteRule/ {
        if (drop && $3 ~ ("^/?(" stale ")(/|$)")) { cond = ""; next }
        # hand-written routing into the core dir is superseded by the new
        # root index.php loader, so it would only fight with it
        if ($3 ~ ("^/?" coredir "/(index\\.php)?$")) { cond = ""; next }
        printf "%s%s\n", cond, $0; cond = ""; next
    }
    { printf "%s%s\n", cond, $0; cond = "" }
    END { printf "%s", cond }
  ' "${SRC}/.htaccess" | sed -E '/^[[:space:]]*$/d')

  if [[ -n "$STALE_RE" ]]; then
    warn "these rules will be dropped: ${STALE_RE//|/, }"
  else
    ok "no stale rewrite targets found"
  fi
  if [[ -n "$CUSTOM" ]]; then
    echo "--- custom rules that will be carried over ---"
    echo "$CUSTOM" | sed 's/^/  /'
  else
    ok "no custom rules to carry over"
  fi
else
  ok "no .htaccess at the root yet"
  CUSTOM=""
fi


# ---------------------------------------------------------------------------
hr "Backup"
STAMP=$(date +%F-%H%M%S)
BDIR=$(getent passwd "$SITE_USER" | cut -d: -f6)/tmp
mkdir -p "$BDIR"; chmod 700 "$BDIR"
DUMP="${BDIR}/premove-db-${STAMP}.sql"
TARBALL="${BDIR}/premove-files-${STAMP}.tar.gz"
$WP db export "$DUMP" >/dev/null 2>&1 && ok "DB dump: ${DUMP}" || die "DB export failed"
tar czf "$TARBALL" -C "$(dirname "$SRC")" "$(basename "$SRC")" 2>/dev/null \
  && ok "file backup: ${TARBALL} ($(du -h "$TARBALL" | cut -f1))" \
  || warn "file backup incomplete - check free disk space before continuing"

if [[ $APPLY -eq 0 ]]; then
  hr "Planned actions"
  cat <<PLAN
  mkdir ${DST}
  move into it: wp-admin/ wp-includes/ wp-content/ wp-*.php xmlrpc.php
                license.txt readme.html
  write ${SRC}/index.php     -> require wp-blog-header.php from ${SUBDIR}/
  write ${SRC}/.htaccess     -> carried-over custom rules + fresh WP block
                                dropped stale targets: ${STALE_RE//|/, }
  move  ${SRC}/.htaccess     -> ${DST}/.htaccess (kept as a copy)
  wp option update siteurl '${NEW_SITEURL}'      (home stays '${HOME_URL}')
  chown -R ${SITE_USER}:${SITE_GROUP} ${DST}
  flush rewrite rules
PLAN
  echo
  ok "Dry run complete. Re-run with --apply to perform the move."
  exit 0
fi

# ---------------------------------------------------------------------------
hr "Moving files"
mkdir -p "$DST" || die "cannot create ${DST}"
shopt -s nullglob
for item in "${SRC}"/wp-admin "${SRC}"/wp-includes "${SRC}"/wp-content \
            "${SRC}"/wp-*.php "${SRC}"/xmlrpc.php \
            "${SRC}"/license.txt "${SRC}"/readme.html; do
  [[ -e "$item" ]] || continue
  mv "$item" "$DST/" && echo "  moved $(basename "$item")"
done
[[ -f "${SRC}/.htaccess" ]] && cp -p "${SRC}/.htaccess" "${DST}/.htaccess"
[[ -f "${SRC}/index.php" ]] && mv "${SRC}/index.php" "${DST}/index.php"
shopt -u nullglob
ok "files moved into ${SUBDIR}/"

hr "Writing root loader"
cat > "${SRC}/index.php" <<LOADER
<?php
/**
 * Front to the WordPress application.
 * Core lives in ./${SUBDIR}/ - see "Giving WordPress its own directory".
 */
define( 'WP_USE_THEMES', true );
require __DIR__ . '/${SUBDIR}/wp-blog-header.php';
LOADER
ok "${SRC}/index.php written"

hr "Writing root .htaccess"
{
  if [[ -n "${CUSTOM:-}" ]]; then
    echo "# --- rules carried over from the previous .htaccess ---"
    echo "<IfModule mod_rewrite.c>"
    echo "RewriteEngine On"
    echo "$CUSTOM" | grep -vE '^[[:space:]]*(RewriteEngine|RewriteBase|<IfModule|</IfModule>)'
    echo "</IfModule>"
    echo
  fi
  cat <<'HTA'
# BEGIN WordPress
<IfModule mod_rewrite.c>
RewriteEngine On
RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]
RewriteBase /
RewriteRule ^index\.php$ - [L]
RewriteCond %{REQUEST_FILENAME} !-f
RewriteCond %{REQUEST_FILENAME} !-d
RewriteRule . /index.php [L]
</IfModule>
# END WordPress
HTA
} > "${SRC}/.htaccess"
ok "${SRC}/.htaccess written (previous version kept at ${DST}/.htaccess)"
[[ -n "$STALE_RE" ]] && ok "dropped stale rules: ${STALE_RE//|/, }"

hr "Hardening the new core directory"
cat > "${DST}/wp-content/uploads/.htaccess" <<'UPL' 2>/dev/null
# no PHP execution in uploads
<FilesMatch "\.(php|phtml|php[0-9])$">
  Require all denied
</FilesMatch>
UPL
[[ -f "${DST}/wp-content/uploads/.htaccess" ]] && ok "PHP execution blocked in uploads/"

hr "Ownership and permissions"
chown -R "${SITE_USER}:${SITE_GROUP}" "$DST" "${SRC}/index.php" "${SRC}/.htaccess"
find "$DST" -type d -exec chmod 755 {} \;
find "$DST" -type f -exec chmod 644 {} \;
chmod 640 "${DST}/wp-config.php"
ok "owner ${SITE_USER}:${SITE_GROUP}, dirs 755, files 644, wp-config.php 640"

hr "Updating the database"
WP2="${WP_BIN} --path=${DST} --skip-plugins --skip-themes"
$WP2 option update siteurl "$NEW_SITEURL" >/dev/null && ok "siteurl -> ${NEW_SITEURL}"
$WP2 option get home | grep -q . && ok "home unchanged: $($WP2 option get home)"
$WP2 rewrite flush --hard >/dev/null 2>&1 && ok "rewrite rules flushed"

hr "Verify"
echo -n "HTTP status at ${HOME_URL}: "
curl -s -o /dev/null -w '%{http_code}\n' "${HOME_URL}/"
echo -n "wp-admin reachable: "
curl -s -o /dev/null -w '%{http_code}\n' "${NEW_SITEURL}/wp-admin/"
cat <<'NEXT'

If the site 500s or shows a directory listing:
  - AllowOverride must be All for this vhost, or the root .htaccess is ignored
  - permalinks: wp-admin -> Settings -> Permalinks -> Save (regenerates rules)
  - a cached page or opcache can mask success: systemctl reload php*-fpm

Rollback: the tarball and DB dump in the site's tmp/ restore the old layout.
NEXT
