#!/usr/bin/env bash
#
# wp-redirect-cleanup.sh   (v7)
#
# Scans and cleans a WordPress install infected with a database-injected
# redirect payload of the form:
#
#   <meta http-equiv="refresh" content="7; url=https://BADDOMAIN/xxxx" /><script>...</script>\r\n<real content>
#
# The payload is prepended to post_content across ALL rows by a direct SQL
# UPDATE, so post_modified is untouched and no PHP file is altered. The same
# attacker usually also rewrites the 'home' option, which is what actually
# breaks the layout (assets 404) and keeps redirecting after the posts are
# clean.
#
# Cleaning runs in four passes, narrowest first:
#   1. cut everything before the first \r\n   (the common case)
#   2. cut everything up to and including </script>, for rows where the
#      payload is the entire content and no line break follows
#   3. excise the block from mid-content by rejoining the text on both
#      sides of it, repeated for rows carrying it more than once
#   4. remove cached oEmbed markup (<blockquote class="wp-embedded-content"
#      data-secret="..."> … </iframe>) that was built while 'home' pointed at
#      the attacker's domain
# Rows left empty by those passes are trashed (posts/pages) or deleted
# (disposable types). Rows that afterwards only mention the domain as a bare
# URL inside real text are reported, never touched.
#
# v7: Abbruch statt Blindflug, wenn home UND siteurl dieselbe Domain tragen
# v6: fourth pass for cached oEmbed markup; empty posts/pages go to the trash
# v5: --domain/--url auto-detected; usable unattended from wp-cleanup-all.sh
# v4: third pass + automatic wp-config.php chmod + guid repair
# v3: second pass, empty-row cleanup
# v2: --wp-bin/--siteurl, home/siteurl repair, leftovers, webroot hygiene
#
# Default mode is DRY RUN. Nothing is changed until you pass --apply.
#
# Usage:
#   ./wp-redirect-cleanup.sh --path /home/SITE/public_html/wordpress \
#                            --domain ushort.company \
#                            --url https://www.example.de \
#                            [--siteurl https://www.example.de/wordpress] \
#                            [--wp-bin /home/SITE/wp] [--backup /home/SITE/tmp]
#   ...same line again with --apply
#
# --domain  the injected domain. OMIT IT: it is read out of the payload,
#           which matters because the target differs from site to site.
# --url     public home URL (option 'home'). Omit to derive it from whichever
#           of home/siteurl is not hijacked.
# --siteurl where WP core lives (option 'siteurl'); defaults to --url.
#           For a subdirectory install this differs, e.g. --url https://x.de
#           --siteurl https://www.x.de/wordpress
# --wp-bin  path to the wp binary/phar, if 'wp' is not usable for this user
#           (can also be given as the WP_BIN environment variable)
#
# Run as the SITE USER, not root.

set -uo pipefail

WP_PATH=""
BAD_DOMAIN=""
SITE_URL=""
SITE_URL_CORE=""
APPLY=0
BACKUP_DIR="${HOME}/tmp"
WP_BIN="${WP_BIN:-wp}"

usage() { sed -n '2,50p' "$0"; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --path)    WP_PATH="$2"; shift 2 ;;
    --domain)  BAD_DOMAIN="$2"; shift 2 ;;
    --url)     SITE_URL="$2"; shift 2 ;;
    --siteurl) SITE_URL_CORE="$2"; shift 2 ;;
    --wp-bin)  WP_BIN="$2"; shift 2 ;;
    --backup)  BACKUP_DIR="$2"; shift 2 ;;
    --apply)   APPLY=1; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

[[ -z "$WP_PATH" ]] && usage
[[ -z "$SITE_URL_CORE" ]] && SITE_URL_CORE="$SITE_URL"

hr()   { printf '\n\033[1m== %s\033[0m\n' "$*"; }
warn() { printf '\033[33m[!] %s\033[0m\n' "$*"; }
ok()   { printf '\033[32m[ok] %s\033[0m\n' "$*"; }
bad()  { printf '\033[31m[HIT] %s\033[0m\n' "$*"; }

WP="${WP_BIN} --path=${WP_PATH} --skip-plugins --skip-themes"

# ---------------------------------------------------------------------------
# 0. Preflight
# ---------------------------------------------------------------------------
hr "Preflight"
[[ -f "${WP_PATH}/wp-config.php" ]] || { echo "No wp-config.php in ${WP_PATH}"; exit 1; }
command -v "$WP_BIN" >/dev/null 2>&1 || [[ -x "$WP_BIN" ]] || {
  echo "WP-CLI not usable at '${WP_BIN}'. Pass --wp-bin /path/to/wp"; exit 1; }
[[ $EUID -eq 0 ]] && warn "Running as root. Prefer: sudo -u SITEUSER -H $0 ..."

PREFIX=$($WP config get table_prefix 2>&1) || {
  echo "WP-CLI cannot read this install. Raw error:"; echo "$PREFIX"; exit 1; }
echo "install : ${WP_PATH}"
echo "prefix  : ${PREFIX}"
echo "wp bin  : ${WP_BIN}"

# --- auto-detection -------------------------------------------------------
# The injected domain is read out of the payload itself, so the script can be
# pointed at a site whose target domain is not known yet (it differs per site).
if [[ -z "$BAD_DOMAIN" || "$BAD_DOMAIN" == "auto" ]]; then
  RAW=$($WP db query "SELECT SUBSTRING_INDEX(SUBSTRING_INDEX(post_content,'url=',-1),'\"',1)
                        FROM ${PREFIX}posts
                       WHERE post_content LIKE '<meta http-equiv=%refresh%' LIMIT 1;" \
        --skip-column-names 2>/dev/null)
  [[ -z "$RAW" ]] && RAW=$($WP option get home 2>/dev/null)
  CAND=$(echo "$RAW" | sed -E 's#^https?://##; s#/.*$##')
  HOMEHOST=$($WP option get home 2>/dev/null | sed -E 's#^https?://##; s#/.*$##')
  SITEHOST=$($WP option get siteurl 2>/dev/null | sed -E 's#^https?://##; s#/.*$##')
  if [[ -n "$CAND" && "$CAND" != "$SITEHOST" ]]; then
    BAD_DOMAIN="$CAND"
    ok "auto-detected injected domain: ${BAD_DOMAIN}"
  elif [[ -n "$CAND" && "$CAND" != "$HOMEHOST" ]]; then
    BAD_DOMAIN="$CAND"
    ok "auto-detected injected domain: ${BAD_DOMAIN}"
  else
    ok "no injected redirect domain found - this install looks clean"
    BAD_DOMAIN="${CAND:-__none__}"
  fi
fi
echo "domain  : ${BAD_DOMAIN}"

# Guard: if the detected domain is the site's own, detection went wrong and
# every later step would treat clean values as hijacked. Better to stop than
# to "repair" a correct siteurl into something broken.
S_CHK=$($WP option get siteurl 2>/dev/null); H_CHK=$($WP option get home 2>/dev/null)
SH_CHK=$(echo "$S_CHK" | sed -E 's#^https?://(www\.)?##; s#/.*##')
HH_CHK=$(echo "$H_CHK" | sed -E 's#^https?://(www\.)?##; s#/.*##')
if [[ -n "$BAD_DOMAIN" && "$BAD_DOMAIN" != "__none__" ]]; then
  BD_CHK=$(echo "$BAD_DOMAIN" | sed -E 's#^www\.##')
  if [[ "$SH_CHK" == *"$BD_CHK"* && "$HH_CHK" == *"$BD_CHK"* ]]; then
    if [[ -n "$SITE_URL" && -n "$SITE_URL_CORE" ]]; then
      # Werte wurden explizit uebergeben - dann ist nichts abzuleiten und der
      # Lauf kann weitergehen, egal wie die Erkennung ausgegangen ist.
      warn "home und siteurl enthalten beide '${BAD_DOMAIN}' - es wird mit den"
      warn "uebergebenen Werten gearbeitet (--url / --siteurl)."
    else
      bad "Selbsterkennung nicht verwertbar: '${BAD_DOMAIN}' steckt in home UND siteurl"
      echo "    home:    ${H_CHK}"
      echo "    siteurl: ${S_CHK}"
      echo
      echo "    Zwei moegliche Ursachen:"
      echo "      a) beide Optionen sind tatsaechlich gekapert - dann gibt es"
      echo "         keinen sauberen Wert zum Ableiten"
      echo "      b) erkannt wurde versehentlich die EIGENE Domain - dann waere"
      echo "         ein korrekter Wert als gekapert behandelt worden"
      echo
      echo "    In beiden Faellen die Werte explizit angeben:"
      echo "      --domain <schaddomain> --url https://DEINE-DOMAIN.TLD \\"
      echo "      --siteurl https://DEINE-DOMAIN.TLD[/$(basename "$WP_PATH")]"
      echo
      echo "    Schaddomain ermitteln:"
      echo "      ${WP_BIN} --path=${WP_PATH} db query \"SELECT DISTINCT SUBSTRING_INDEX(SUBSTRING_INDEX(post_content,'url=',-1),'\\\"',1) FROM ${PREFIX}posts WHERE post_content LIKE '<meta http-equiv=%' LIMIT 5;\""
      echo "    Oeffentliche Adresse ermitteln:"
      echo "      grep -rh ServerName /etc/apache2/sites-enabled/ | sort -u"
      exit 1
    fi
  fi
fi

# The clean one of home/siteurl tells us what the other should be. For a
# subdirectory install siteurl ends in the core directory name.
if [[ -z "$SITE_URL" ]]; then
  S=$($WP option get siteurl 2>/dev/null); H=$($WP option get home 2>/dev/null)
  if [[ "$H" != *"$BAD_DOMAIN"* && -n "$H" ]]; then
    SITE_URL="$H"
  elif [[ "$S" != *"$BAD_DOMAIN"* && -n "$S" ]]; then
    SITE_URL=$(echo "$S" | sed -E "s#/$(basename "$WP_PATH")\$##")
  fi
  [[ -n "$SITE_URL" ]] && ok "auto-detected home URL: ${SITE_URL}"
fi
if [[ -z "$SITE_URL_CORE" ]]; then
  S=$($WP option get siteurl 2>/dev/null)
  if [[ "$S" != *"$BAD_DOMAIN"* && -n "$S" ]]; then
    SITE_URL_CORE="$S"
  else
    SITE_URL_CORE="$SITE_URL"
  fi
  [[ -n "$SITE_URL_CORE" ]] && ok "auto-detected core URL: ${SITE_URL_CORE}"
fi
# --------------------------------------------------------------------------

[[ $APPLY -eq 1 ]] && warn "APPLY MODE - changes will be written" || ok "DRY RUN - no changes"

# ---------------------------------------------------------------------------
# 1. Backup (always, even in dry run)
# ---------------------------------------------------------------------------
hr "Backup"
mkdir -p "$BACKUP_DIR"
STAMP=$(date +%F-%H%M%S)
DUMP="${BACKUP_DIR}/$(basename "$(dirname "$WP_PATH")")-${STAMP}.sql"
if $WP db export "$DUMP" >/dev/null 2>&1; then
  ok "DB dumped to ${DUMP} ($(du -h "$DUMP" | cut -f1))"
  chmod 600 "$DUMP"
else
  echo "DB export failed - aborting."; exit 1
fi

# ---------------------------------------------------------------------------
# 2. Scan
# ---------------------------------------------------------------------------
hr "Scan: database"
for q in \
  "SELECT COUNT(*) FROM ${PREFIX}posts    WHERE post_content    LIKE '%${BAD_DOMAIN}%'" \
  "SELECT COUNT(*) FROM ${PREFIX}posts    WHERE guid            LIKE '%${BAD_DOMAIN}%'" \
  "SELECT COUNT(*) FROM ${PREFIX}postmeta WHERE meta_value      LIKE '%${BAD_DOMAIN}%'" \
  "SELECT COUNT(*) FROM ${PREFIX}options  WHERE option_value    LIKE '%${BAD_DOMAIN}%'" \
  "SELECT COUNT(*) FROM ${PREFIX}comments WHERE comment_content LIKE '%${BAD_DOMAIN}%'" \
  "SELECT COUNT(*) FROM ${PREFIX}usermeta WHERE meta_value      LIKE '%${BAD_DOMAIN}%'"
do
  printf '%-72s %s\n' "${q#SELECT COUNT(*) FROM }" "$($WP db query "$q;" --skip-column-names 2>/dev/null)"
done
echo "--- affected option rows ---"
$WP db query "SELECT option_name FROM ${PREFIX}options WHERE option_value LIKE '%${BAD_DOMAIN}%';" 2>/dev/null

hr "Scan: filesystem"
grep -ril "$BAD_DOMAIN" "$WP_PATH" 2>/dev/null | head -20 | while read -r f; do bad "$f"; done
[[ -f "${WP_PATH}/.htaccess" ]] && { echo "--- .htaccess ---"; cat "${WP_PATH}/.htaccess"; }
find "${WP_PATH}/wp-content/uploads" -name '*.php' 2>/dev/null | while read -r f; do bad "PHP in uploads: $f"; done
ls -la "${WP_PATH}/wp-content/mu-plugins" 2>/dev/null

hr "Scan: integrity and accounts"
$WP core verify-checksums 2>&1 | grep -v '^Success' | head -20
$WP plugin verify-checksums --all 2>&1 | grep -viE '^Success|Could not retrieve' | head -20
$WP user list --role=administrator --fields=ID,user_login,user_email,user_registered 2>/dev/null
$WP cron event list --fields=hook,next_run_relative 2>/dev/null | grep -viE 'wp_|akismet|action_scheduler' | head

# ---------------------------------------------------------------------------
# 3. Repair home / siteurl   (STEP 1 - do this before anything else)
#    A hijacked 'home' is what actually keeps the site redirecting and
#    unstyled: WordPress builds every link and asset URL from it.
# ---------------------------------------------------------------------------
hr "Repair: home / siteurl"
CUR_HOME=$($WP option get home 2>/dev/null)
CUR_SITEURL=$($WP option get siteurl 2>/dev/null)
echo "home    : ${CUR_HOME}"
echo "siteurl : ${CUR_SITEURL}"

fix_url_option() {           # $1 option name, $2 current value, $3 intended value
  local opt="$1" cur="$2" want="$3"
  case "$cur" in
    *"$BAD_DOMAIN"*)
      bad "${opt} hijacked"
      if [[ -z "$want" ]]; then
        warn "kein Sollwert bekannt - beide Optionen sind gekapert, es gibt"
        warn "nichts zum Ableiten. Werte explizit angeben:"
        echo  "        --url https://DEINE-DOMAIN.TLD \\"
        echo  "        --siteurl https://DEINE-DOMAIN.TLD[/wordpress]"
        echo  "    Die oeffentliche Adresse steht im vhost:"
        echo  "        grep -rh ServerName /etc/apache2/sites-enabled/ | sort -u"
        echo  "    Bei Unterverzeichnis-Installationen endet --siteurl auf den"
        echo  "    Verzeichnisnamen ($(basename "$WP_PATH")), --url nicht."
      elif [[ $APPLY -eq 1 ]]; then
        $WP option update "$opt" "$want" >/dev/null && ok "${opt} -> ${want}"
      else
        echo "    would run: wp option update ${opt} '${want}'"
        echo "    emergency override in wp-config.php (above /* That's all */):"
        echo "      define('WP_HOME','${SITE_URL}'); define('WP_SITEURL','${SITE_URL_CORE}');"
      fi
      ;;
    *) ok "${opt} looks clean" ;;
  esac
}
fix_url_option home    "$CUR_HOME"    "$SITE_URL"
fix_url_option siteurl "$CUR_SITEURL" "$SITE_URL_CORE"

# ---------------------------------------------------------------------------
# 4. Clean post_content   (STEP 2)
# ---------------------------------------------------------------------------
hr "Clean: post_content"
# The payload contains no line break of its own and is terminated by \r\n,
# so cutting everything before the FIRST \r\n removes exactly the payload.
CLEAN_SQL="UPDATE ${PREFIX}posts
   SET post_content = SUBSTRING(post_content FROM LOCATE('\r\n', post_content) + 2)
 WHERE post_content LIKE '<meta http-equiv=%${BAD_DOMAIN}%'
   AND LOCATE('\r\n', post_content) > 0;"

MATCHES=$($WP db query \
  "SELECT COUNT(*) FROM ${PREFIX}posts WHERE post_content LIKE '<meta http-equiv=%${BAD_DOMAIN}%' AND LOCATE('\r\n', post_content) > 0;" \
  --skip-column-names 2>/dev/null)
echo "rows matching the payload pattern: ${MATCHES}"

if [[ $APPLY -eq 1 && "${MATCHES:-0}" -gt 0 ]]; then
  ID=$($WP db query "SELECT ID FROM ${PREFIX}posts WHERE post_content LIKE '<meta http-equiv=%${BAD_DOMAIN}%' LIMIT 1;" --skip-column-names)
  echo "--- before (ID ${ID}) ---"; $WP post get "$ID" --field=content 2>/dev/null | head -c 300; echo
  $WP db query "$CLEAN_SQL"
  echo "--- after  (ID ${ID}) ---"; $WP post get "$ID" --field=content 2>/dev/null | head -c 300; echo
  ok "post_content cleaned"
else
  echo "(dry run - re-run with --apply to execute)"
  echo "$CLEAN_SQL"
fi

# ---------------------------------------------------------------------------
# 5. Leftovers   (STEP 3)
#    Rows containing the domain but NOT matching the payload pattern:
#    normally attacker-created auto-drafts plus cosmetic guid damage
#    caused by the hijacked 'home' option.
# ---------------------------------------------------------------------------
hr "Leftovers"
LEFT=$($WP db query "SELECT COUNT(*) FROM ${PREFIX}posts WHERE post_content LIKE '%${BAD_DOMAIN}%';" --skip-column-names 2>/dev/null)
GUIDS=$($WP db query "SELECT COUNT(*) FROM ${PREFIX}posts WHERE guid LIKE '%${BAD_DOMAIN}%';" --skip-column-names 2>/dev/null)
echo "post_content still containing the domain : ${LEFT}"
echo "guid containing the domain               : ${GUIDS}"

if [[ "${LEFT:-0}" -gt 0 ]]; then
  echo "--- breakdown by status/type ---"
  $WP db query "SELECT post_status, post_type, COUNT(*) FROM ${PREFIX}posts WHERE post_content LIKE '%${BAD_DOMAIN}%' GROUP BY post_status, post_type;" 2>/dev/null
  echo "--- sample rows ---"
  $WP db query "SELECT ID, post_status, post_type, LEFT(post_content,90) FROM ${PREFIX}posts WHERE post_content LIKE '%${BAD_DOMAIN}%' LIMIT 10;" 2>/dev/null
fi

if [[ $APPLY -eq 1 ]]; then
  # attacker-created auto-drafts: safe to delete, they hold no real content
  DRAFTS=$($WP db query "SELECT COUNT(*) FROM ${PREFIX}posts WHERE post_status='auto-draft' AND (guid LIKE '%${BAD_DOMAIN}%' OR post_content LIKE '%${BAD_DOMAIN}%');" --skip-column-names)
  $WP db query "DELETE FROM ${PREFIX}posts WHERE post_status='auto-draft' AND (guid LIKE '%${BAD_DOMAIN}%' OR post_content LIKE '%${BAD_DOMAIN}%');"
  ok "deleted ${DRAFTS} auto-draft rows"

  # Second pass: rows the \r\n cut missed, because the payload is the entire
  # content or is not followed by a line break. Cut after the closing
  # </script> tag instead, then strip a leading \r\n if one remains.
  # '</script>' is 9 characters.
  REST=$($WP db query "SELECT COUNT(*) FROM ${PREFIX}posts WHERE post_content LIKE '<meta http-equiv=%${BAD_DOMAIN}%' AND LOCATE('</script>', post_content) > 0;" --skip-column-names)
  if [[ "${REST:-0}" -gt 0 ]]; then
    $WP db query "UPDATE ${PREFIX}posts
       SET post_content = TRIM(LEADING '\r\n' FROM SUBSTRING(post_content FROM LOCATE('</script>', post_content) + 9))
     WHERE post_content LIKE '<meta http-equiv=%${BAD_DOMAIN}%'
       AND LOCATE('</script>', post_content) > 0;"
    ok "second pass: ${REST} further rows trimmed after </script>"
  fi

  # Rows that are now empty were pure payload and hold nothing worth keeping,
  # but only throw away the disposable post types - never real content.
  EMPTIED=$($WP db query "SELECT COUNT(*) FROM ${PREFIX}posts WHERE TRIM(post_content) = '' AND post_type IN ('oembed_cache','customize_changeset','request');" --skip-column-names)
  if [[ "${EMPTIED:-0}" -gt 0 ]]; then
    $WP db query "DELETE FROM ${PREFIX}posts WHERE TRIM(post_content) = '' AND post_type IN ('oembed_cache','customize_changeset','request');"
    ok "deleted ${EMPTIED} now-empty cache/changeset/request rows"
  fi

  # guid repair - cosmetic only, guids are identifiers and are never followed
  if [[ "${GUIDS:-0}" -gt 0 && -n "$SITE_URL" ]]; then
    BAD_BASE=$($WP db query "SELECT SUBSTRING_INDEX(SUBSTRING_INDEX(guid,'/?',1),'/',3) FROM ${PREFIX}posts WHERE guid LIKE '%${BAD_DOMAIN}%' LIMIT 1;" --skip-column-names)
    $WP db query "UPDATE ${PREFIX}posts SET guid = REPLACE(guid, '${BAD_BASE}', '${SITE_URL}') WHERE guid LIKE '%${BAD_DOMAIN}%';"
    ok "guid base '${BAD_BASE}' rewritten to '${SITE_URL}'"
  fi

  # Third pass: the block sits mid-content, not at the start. Cut out exactly
  # the injected span - from '<meta http-equiv=' up to and including the
  # closing '</script>' - and keep everything on both sides. Repeated until
  # no row matches, since a row can carry the block more than once.
  for _ in 1 2 3 4 5; do
    MID=$($WP db query "SELECT COUNT(*) FROM ${PREFIX}posts
       WHERE post_content LIKE '%<meta http-equiv=%${BAD_DOMAIN}%'
         AND LOCATE('</script>', post_content) > LOCATE('<meta http-equiv=', post_content);" --skip-column-names)
    [[ "${MID:-0}" -eq 0 ]] && break
    $WP db query "UPDATE ${PREFIX}posts
       SET post_content = CONCAT(
             SUBSTRING(post_content, 1, LOCATE('<meta http-equiv=', post_content) - 1),
             SUBSTRING(post_content FROM LOCATE('</script>', post_content) + 9))
     WHERE post_content LIKE '%<meta http-equiv=%${BAD_DOMAIN}%'
       AND LOCATE('</script>', post_content) > LOCATE('<meta http-equiv=', post_content);"
    ok "third pass: cut the injected block out of ${MID} rows"
  done

  # Fourth pass: cached oEmbed markup. WordPress caches the embed HTML for a
  # linked post, and while 'home' was hijacked those caches were built against
  # the attacker's domain. The markup is machine-generated and recognisable:
  #   <blockquote class="wp-embedded-content" data-secret="..."> … </blockquote>
  #   <iframe class="wp-embedded-content" style="… visibility: hidden;" …></iframe>
  # It carries no text of yours, so the whole span is cut out. Any surrounding
  # content the row may have is kept - the cut ends at the matching </iframe>.
  for _ in 1 2 3 4 5; do
    EMB=$($WP db query "SELECT COUNT(*) FROM ${PREFIX}posts
       WHERE post_content LIKE '%wp-embedded-content%${BAD_DOMAIN}%'
         AND LOCATE('</iframe>', post_content) > LOCATE('<blockquote class=\"wp-embedded-content\"', post_content);" --skip-column-names)
    [[ "${EMB:-0}" -eq 0 ]] && break
    $WP db query "UPDATE ${PREFIX}posts
       SET post_content = CONCAT(
             SUBSTRING(post_content, 1, LOCATE('<blockquote class=\"wp-embedded-content\"', post_content) - 1),
             SUBSTRING(post_content FROM LOCATE('</iframe>', post_content) + 9))
     WHERE post_content LIKE '%wp-embedded-content%${BAD_DOMAIN}%'
       AND LOCATE('</iframe>', post_content) > LOCATE('<blockquote class=\"wp-embedded-content\"', post_content);"
    ok "fourth pass: removed cached oEmbed markup from ${EMB} rows"
  done

  # Rows left empty by the passes above held nothing but the injected markup.
  # Real post types go to the trash rather than being destroyed, so you can
  # look at them in wp-admin before they are gone for good.
  EMPTY_POSTS=$($WP db query "SELECT COUNT(*) FROM ${PREFIX}posts WHERE TRIM(post_content) = '' AND post_type IN ('post','page') AND post_status != 'trash';" --skip-column-names)
  if [[ "${EMPTY_POSTS:-0}" -gt 0 ]]; then
    $WP db query "UPDATE ${PREFIX}posts SET post_status = 'trash' WHERE TRIM(post_content) = '' AND post_type IN ('post','page') AND post_status != 'trash';"
    warn "${EMPTY_POSTS} post/page rows are now empty and were moved to the trash - check wp-admin before emptying it"
  fi

  # Whatever still mentions the domain now has no injected block left - it is
  # a bare URL. Disposable post types get deleted; real content is reported.
  BARE=$($WP db query "SELECT COUNT(*) FROM ${PREFIX}posts WHERE post_content LIKE '%${BAD_DOMAIN}%' AND post_type IN ('oembed_cache','customize_changeset','request','revision');" --skip-column-names)
  if [[ "${BARE:-0}" -gt 0 ]]; then
    $WP db query "DELETE FROM ${PREFIX}posts WHERE post_content LIKE '%${BAD_DOMAIN}%' AND post_type IN ('oembed_cache','customize_changeset','request','revision');"
    ok "deleted ${BARE} disposable rows still mentioning the domain"
  fi

  FINAL=$($WP db query "SELECT COUNT(*) FROM ${PREFIX}posts WHERE post_content LIKE '%${BAD_DOMAIN}%' OR guid LIKE '%${BAD_DOMAIN}%';" --skip-column-names)
  if [[ "$FINAL" -eq 0 ]]; then
    ok "0 rows left in ${PREFIX}posts"
  else
    bad "${FINAL} rows still contain the domain - these need a human eye:"
    $WP db query "SELECT ID, post_status, post_type, LEFT(post_content,140) AS content FROM ${PREFIX}posts WHERE post_content LIKE '%${BAD_DOMAIN}%' LIMIT 20;" 2>/dev/null
    echo "These are real content rows carrying a bare link, not the injected"
    echo "block, so deleting them would destroy your own text. Edit each one:"
    echo "  ${WP_BIN} --path=${WP_PATH} post edit <ID>"
  fi
fi

warn "Hits in options/postmeta/comments other than home/siteurl must be reviewed"
warn "by hand. Serialized values: edit via 'wp option get/set', never raw SQL."

# ---------------------------------------------------------------------------
# 6. Webroot hygiene   (STEP 4)
#    Files that do not belong in a web-reachable directory.
# ---------------------------------------------------------------------------
hr "Webroot hygiene"
STRAY=$(find "$WP_PATH" -maxdepth 1 \( -name '*.phar' -o -name '*.sql' -o -name '*.sql.gz' -o -name '*.tar.gz' -o -name '*.zip' -o -name '*.bak' \) 2>/dev/null)
if [[ -n "$STRAY" ]]; then
  echo "$STRAY" | while read -r f; do bad "web-reachable: $f"; done
  if [[ $APPLY -eq 1 ]]; then
    echo "$STRAY" | while read -r f; do rm -f "$f" && ok "removed $f"; done
  else
    echo "(dry run - these would be deleted with --apply)"
  fi
else
  ok "no stray archives, dumps or phar files in the webroot"
fi
if [[ -f "${WP_PATH}/wp-config.php" ]]; then
  M=$(stat -c '%a' "${WP_PATH}/wp-config.php")
  if [[ "$M" == "640" || "$M" == "600" || "$M" == "440" || "$M" == "400" ]]; then
    ok "wp-config.php mode ${M}"
  elif [[ $APPLY -eq 1 ]]; then
    if chmod 640 "${WP_PATH}/wp-config.php" 2>/dev/null; then
      ok "wp-config.php ${M} -> 640"
      warn "If PHP now cannot read it, the web server is not in the file's group:"
      warn "  stat -c '%U:%G' ${WP_PATH}/wp-config.php   then chgrp to the PHP-FPM group"
    else
      warn "chmod failed (not the owner?) - run as the site user or as root"
    fi
  else
    warn "wp-config.php is mode ${M} - would be set to 640 with --apply"
  fi
fi

# ---------------------------------------------------------------------------
# 7. Flush every cache layer
# ---------------------------------------------------------------------------
hr "Cache flush"
if [[ $APPLY -eq 1 ]]; then
  $WP cache flush 2>/dev/null
  $WP transient delete --all 2>/dev/null
  rm -rf "${WP_PATH}/wp-content/cache/"* 2>/dev/null
  rm -f  "${WP_PATH}/wp-content/uploads/dynamic_avia/avia-merged-styles-"* 2>/dev/null
  rm -f  "${WP_PATH}/wp-content/uploads/dynamic_avia/avia-head-scripts-"* 2>/dev/null
  ok "object cache, transients, page cache, Enfold merged assets cleared"
  echo "Still to do by hand: systemctl reload php*-fpm (opcache), CDN purge,"
  echo "Enfold -> Performance -> 'Delete old CSS and JS files' + save General Styling."
fi

# ---------------------------------------------------------------------------
# 8. Verify from the outside
# ---------------------------------------------------------------------------
if [[ -n "$SITE_URL" ]]; then
  hr "Verify: ${SITE_URL}"
  echo -n "HTML (desktop UA) hits : "
  curl -s "${SITE_URL}/?nocache=$RANDOM" | grep -c "$BAD_DOMAIN"
  echo -n "HTML (mobile UA)  hits : "
  curl -s -A "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148 Safari/604.1" \
       "${SITE_URL}/?nocache=$RANDOM" | grep -c "$BAD_DOMAIN"
  echo -n "Location header        : "
  curl -sI "${SITE_URL}/" | grep -i '^location' || echo "(none)"

  echo "Linked CSS/JS assets:"
  curl -s "${SITE_URL}/" \
    | grep -oE '(src|href)="[^"]+\.(js|css)[^"]*"' | cut -d'"' -f2 | sort -u \
    | while read -r u; do
        case "$u" in //*) u="https:$u" ;; /*) u="${SITE_URL}${u}" ;; esac
        n=$(curl -s --max-time 10 "$u" | grep -c "$BAD_DOMAIN")
        [[ "$n" -gt 0 ]] && bad "$u"
      done
  ok "asset scan done (no HIT lines above = assets clean)"
  echo
  warn "If all counts are 0 but a browser still redirects: it is YOUR browser cache."
  warn "Test in a private window / another device, and check DevTools > Application"
  warn "> Service Workers for anything registered on the domain."
fi

# ---------------------------------------------------------------------------
# 9. Post-cleanup checklist
# ---------------------------------------------------------------------------
hr "Do not stop here"
cat <<'CHECKLIST'
The injection was written straight to MySQL: post_modified timestamps were
untouched, and rows WordPress never writes that way were hit. That means
DB-level access, not a PHP backdoor - cleaning rows fixes the symptom only.

  [ ] Webmin / phpMyAdmin must not be internet-facing.
      bind=127.0.0.1 in /etc/webmin/miniserv.conf ; /etc/webmin/restart
      tunnel: ssh -L 10000:127.0.0.1:10000 user@host   (127.0.0.1, not localhost)
      Hetzner cloud firewall: default-deny, so also allow 22/80/443/25 explicitly,
      each rule for 0.0.0.0/0 AND ::/0
  [ ] ss -tlnp | grep -E '3306|10000'  - and verify from OUTSIDE the box
  [ ] /var/webmin/webmin.log + miniserv.log - unfamiliar sessions?
      cat /etc/webmin/miniserv.users - unfamiliar accounts?
  [ ] Rotate: DB password (wp config set DB_PASSWORD), all admin passwords,
      wp config shuffle-salts, SSH keys, Webmin credentials
  [ ] last / lastb, /root/.ssh/authorized_keys, /home/*/.ssh/authorized_keys
  [ ] mailq | tail - a compromised host running Postfix gets used as a relay
  [ ] Run every OTHER site on this host with the generic query, since the
      target domain differs per site:
        wp db query "SELECT COUNT(*) FROM wp_posts WHERE post_content LIKE '<meta http-equiv=%';"
  [ ] Re-run this script in DRY RUN in 1h and again tomorrow. If the count
      goes 0 -> non-zero, someone still has access: take the vhost offline
      instead of cleaning again.
CHECKLIST
