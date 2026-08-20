#!/usr/bin/env bash
#
# wp-health-check.sh
#
# Functional health check across every WordPress install under
# /home/<user>/public_html[/wordpress]. Complements the security tools:
# wp-db-audit and wp-asset-scan ask "is anything malicious here?", this one
# asks "does everything still work?".
#
# Each check exists because the corresponding failure actually happened, and
# because the symptom pointed somewhere else than the cause:
#
#   PHP identity     mod_php overriding fcgid -> PHP runs as www-data
#                    -> uploads fail, updates ask for FTP, debug.log missing
#   filesystem       root-owned files -> get_filesystem_method() = ftpext
#                    -> "please enter FTP credentials" on every update
#   ownership        uploads and updates break independently: uploads only
#                    need uploads/, updates need the whole core
#   permalinks       an empty permalink_structure means no rewrite rules at
#                    all -> /wp-json/ 404s -> block editor fails with
#                    "The response is not a valid JSON response"
#   REST API         tested both ways: pretty /wp-json/ and ?rest_route=.
#                    If only the second works, rewrite rules are the problem,
#                    not WordPress
#   uploads exec     PHP in uploads/ must not execute
#   assets           ... while images must still be served. A rule that
#                    blocks both is worse than no rule
#   home/siteurl     for a subdirectory layout they differ ON PURPOSE
#
# All URLs are built from siteurl, not home. With a subdirectory install the
# asset path contains the directory - testing against home yields a 404 that
# looks like protection but is just a wrong address.
#
# Read-only. --fix only performs two safe repairs, each with a prompt.
#
# Usage:
#   ./wp-health-check.sh                 # check every site
#   ./wp-health-check.sh --only siteuser
#   ./wp-health-check.sh --quiet         # failures only, for cron
#   ./wp-health-check.sh --fix           # offer to flush permalinks / clear theme cache

set -uo pipefail

ONLY=""
QUIET=0
FIX=0
FAILED_TOTAL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --only)  ONLY="$2"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    --fix)   FIX=1; shift ;;
    -h|--help) sed -n '2,42p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

[[ $EUID -ne 0 ]] && { echo "Run as root - it switches to each site user itself."; exit 1; }

hr()   { [[ $QUIET -eq 0 ]] && printf '\n\033[1m===== %s =====\033[0m\n' "$*"; return 0; }
pass() { [[ $QUIET -eq 0 ]] && printf '  \033[32m[ ok ]\033[0m %-22s %s\n' "$1" "${2:-}"; return 0; }
fail() { printf '  \033[31m[FAIL]\033[0m %-22s %s\n' "$1" "${2:-}"; SITE_FAIL=$((SITE_FAIL+1)); FAILED_TOTAL=$((FAILED_TOTAL+1)); }
warn() { [[ $QUIET -eq 0 ]] && printf '  \033[33m[warn]\033[0m %-22s %s\n' "$1" "${2:-}"; return 0; }
info() { [[ $QUIET -eq 0 ]] && printf '         %s\n' "$*"; return 0; }

mapfile -t CONFIGS < <(
  ls -d /home/*/public_html/wordpress/wp-config.php \
        /home/*/public_html/wp-config.php 2>/dev/null | sort -u
)
[[ ${#CONFIGS[@]} -eq 0 ]] && { echo "No WordPress installations found."; exit 0; }

SITES_OK=0; SITES_BAD=()

for CONFIG in "${CONFIGS[@]}"; do
  D=$(dirname "$CONFIG")
  U=$(echo "$CONFIG" | sed -nE 's#^/home/([^/]+)/.*#\1#p')
  { [[ -z "$U" ]] || ! getent passwd "$U" >/dev/null; } && U=$(stat -c '%U' "$CONFIG")
  [[ -n "$ONLY" && "$U" != "$ONLY" ]] && continue
  SITE_FAIL=0

  hr "${U}  (${D})"

  # --- WP-CLI usable for this account? -------------------------------------
  WPBIN=""
  for CAND in "/home/${U}/wp" "/home/${U}/.wp-cli.phar" "${D}/wp-cli.phar" /usr/local/bin/wp; do
    sudo -u "$U" -H test -r "$CAND" 2>/dev/null && { WPBIN="$CAND"; break; }
  done
  if [[ -z "$WPBIN" ]]; then
    fail "wp-cli" "no usable WP-CLI for ${U}"
    SITES_BAD+=("$U"); continue
  fi
  WP="sudo -u ${U} -H ${WPBIN} --path=${D} --skip-plugins --skip-themes"

  HOME_URL=$($WP option get home 2>/dev/null)
  SITE_URL=$($WP option get siteurl 2>/dev/null)
  if [[ -z "$HOME_URL" || -z "$SITE_URL" ]]; then
    fail "database" "cannot read home/siteurl - check DB credentials"
    SITES_BAD+=("$U"); continue
  fi

  # --- 1. home / siteurl ---------------------------------------------------
  HH=$(echo "$HOME_URL" | sed -E 's#^https?://##; s#/.*##')
  SH=$(echo "$SITE_URL" | sed -E 's#^https?://##; s#/.*##')
  if [[ "$HH" != "$SH" ]]; then
    fail "home/siteurl" "different hosts: ${HOME_URL} vs ${SITE_URL}"
  else
    SUBPATH=$(echo "$SITE_URL" | sed -E 's#^https?://[^/]+##')
    if [[ -n "$SUBPATH" ]]; then
      pass "home/siteurl" "subdirectory layout, core at ${SUBPATH}"
    else
      pass "home/siteurl" "$HOME_URL"
    fi
  fi

  # --- 2. which identity does PHP run under? -------------------------------
  PROBE="health-$RANDOM.php"
  cat > "${D}/${PROBE}" <<'PHPEOF'
<?php
$u = posix_getpwuid(posix_geteuid());
echo "user=".$u['name'];
$up = __DIR__.'/wp-content/uploads/'.date('Y/m');
echo "|uploads=".(is_dir($up) ? (is_writable($up)?'writable':'NOT-writable') : 'missing');
echo "|content=".(is_writable(__DIR__.'/wp-content')?'writable':'NOT-writable');
echo "|abspath=".(is_writable(__DIR__)?'writable':'NOT-writable');
PHPEOF
  chown "$U:$(id -gn "$U")" "${D}/${PROBE}" 2>/dev/null
  RESP=$(curl -s --max-time 15 "${SITE_URL}/${PROBE}")
  rm -f "${D}/${PROBE}"

  PHPUSER=$(sed -nE 's/.*user=([^|]*).*/\1/p' <<<"$RESP")
  if [[ -z "$PHPUSER" ]]; then
    warn "php identity" "probe not reachable at ${SITE_URL}/ - skipping web checks"
  elif [[ "$PHPUSER" == "$U" ]]; then
    pass "php identity" "runs as ${PHPUSER}"
  else
    fail "php identity" "runs as ${PHPUSER}, expected ${U}"
    info "mod_php active instead of fcgid? check: ls /etc/apache2/mods-enabled/ | grep php"
  fi
  for K in uploads content abspath; do
    V=$(sed -nE "s/.*${K}=([^|]*).*/\1/p" <<<"$RESP")
    case "$V" in
      writable)     pass "writable: ${K}" ;;
      NOT-writable) fail "writable: ${K}" "PHP cannot write here" ;;
      missing)      warn "writable: ${K}" "directory does not exist yet" ;;
    esac
  done

  # --- 3. filesystem method: does WordPress ask for FTP? -------------------
  FSM=$($WP eval 'require_once ABSPATH."wp-admin/includes/file.php"; echo get_filesystem_method();' 2>/dev/null)
  case "$FSM" in
    direct) pass "update method" "direct - no FTP prompt" ;;
    "")     warn "update method" "could not determine" ;;
    *)      fail "update method" "${FSM} - WordPress will ask for FTP credentials"
            info "usually root-owned files: wp-fix-ownership --only ${U}" ;;
  esac

  # --- 4. ownership --------------------------------------------------------
  NFOREIGN=$(find "$D" ! -user "$U" 2>/dev/null | wc -l)
  if [[ "$NFOREIGN" -eq 0 ]]; then
    pass "ownership" "all files owned by ${U}"
  else
    OWNERS=$(find "$D" ! -user "$U" -printf '%u\n' 2>/dev/null | sort -u | tr '\n' ' ')
    fail "ownership" "${NFOREIGN} file(s) owned by: ${OWNERS}"
    info "fix with: wp-fix-ownership --only ${U}"
  fi

  # --- 5. permalinks -------------------------------------------------------
  PERMA=$($WP option get permalink_structure 2>/dev/null)
  if [[ -n "$PERMA" ]]; then
    pass "permalinks" "$PERMA"
  else
    fail "permalinks" "empty - no rewrite rules, /wp-json/ will 404"
    info "the block editor then fails with 'response is not a valid JSON response'"
    info "fix: wp-admin -> Settings -> Permalinks -> Save, or --fix"
  fi

  # --- 6. REST API, both ways ---------------------------------------------
  R_PRETTY=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "${SITE_URL}/wp-json/wp/v2/types/post")
  R_QUERY=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "${HOME_URL}/?rest_route=/wp/v2/types/post")
  if [[ "$R_PRETTY" == "200" ]]; then
    pass "rest api" "/wp-json/ reachable"
  elif [[ "$R_QUERY" == "200" ]]; then
    fail "rest api" "/wp-json/ -> ${R_PRETTY}, but ?rest_route= -> 200"
    info "WordPress works; the rewrite rules do not. See 'permalinks' above."
  else
    fail "rest api" "/wp-json/ -> ${R_PRETTY}, ?rest_route= -> ${R_QUERY}"
    info "check a plugin or a security rule blocking the REST API"
  fi

  # --- 7. PHP execution in uploads must be blocked -------------------------
  UPD="${D}/wp-content/uploads"
  if [[ -d "$UPD" ]]; then
    UPROBE="health-$RANDOM.php"
    printf '<?php echo "EXECUTED";' > "${UPD}/${UPROBE}"
    chown "$U:$(id -gn "$U")" "${UPD}/${UPROBE}" 2>/dev/null
    # URL from siteurl - with a subdirectory layout the path contains it
    URESP=$(curl -s --max-time 15 -w '\n%{http_code}' "${SITE_URL}/wp-content/uploads/${UPROBE}")
    rm -f "${UPD}/${UPROBE}"
    UCODE=$(tail -1 <<<"$URESP")
    if grep -q 'EXECUTED' <<<"$URESP"; then
      fail "uploads exec" "PHP in uploads/ IS executed"
      info "check AllowOverride and wp-content/uploads/.htaccess"
    elif [[ "$UCODE" == "403" ]]; then
      pass "uploads exec" "blocked (403)"
    elif [[ "$UCODE" == "404" ]]; then
      warn "uploads exec" "404 - wrong path, test inconclusive"
    else
      pass "uploads exec" "not executed (${UCODE}, served as text)"
    fi
  fi

  # --- 8. ... while real uploads must still be served ----------------------
  IMG=$(find "$UPD" -type f \( -name '*.jpg' -o -name '*.png' -o -name '*.webp' -o -name '*.gif' \) 2>/dev/null | head -1)
  if [[ -n "$IMG" ]]; then
    REL=${IMG#"$UPD"/}
    ICODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "${SITE_URL}/wp-content/uploads/${REL}")
    if [[ "$ICODE" == "200" ]]; then
      pass "media delivery" "images served (200)"
    else
      fail "media delivery" "image returns ${ICODE} - a rule blocks too much"
      info "tested: ${SITE_URL}/wp-content/uploads/${REL}"
    fi
  else
    warn "media delivery" "no image found to test with"
  fi

  # --- 9. site itself ------------------------------------------------------
  HCODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "${HOME_URL}/?nocache=$RANDOM")
  case "$HCODE" in
    200|301|302) pass "home page" "$HCODE" ;;
    *)           fail "home page" "$HCODE" ;;
  esac

  # --- 10. cron ------------------------------------------------------------
  OVERDUE=$($WP cron event list --fields=hook,next_run_relative --format=csv 2>/dev/null \
            | grep -c 'ago' || true)
  if [[ "${OVERDUE:-0}" -gt 3 ]]; then
    warn "wp-cron" "${OVERDUE} overdue events - cron may not be running"
  else
    pass "wp-cron" "no backlog"
  fi

  # --- optional repairs ----------------------------------------------------
  if [[ $FIX -eq 1 && $SITE_FAIL -gt 0 ]]; then
    if [[ -z "$PERMA" ]]; then
      echo
      warn "fix available" "set a permalink structure for ${U}?"
      info "this changes every URL on the site - existing links may break"
      NPOSTS=$($WP post list --post_type=post,page --post_status=publish --format=count 2>/dev/null)
      info "published posts/pages: ${NPOSTS:-?}"
      read -r -p "         set '/%postname%/'? [y/N] " ANS
      if [[ "${ANS,,}" == "y" ]]; then
        $WP rewrite structure '/%postname%/' --hard >/dev/null 2>&1
        $WP rewrite flush --hard >/dev/null 2>&1
        NEW=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "${SITE_URL}/wp-json/wp/v2/types/post")
        [[ "$NEW" == "200" ]] && pass "fixed" "permalinks set, /wp-json/ now 200" \
                              || fail "fix" "/wp-json/ still ${NEW}"
      fi
    fi
    # theme cache written under a foreign identity - safe to discard
    for C in "${D}/wp-content/et-cache" "${D}/wp-content/uploads/dynamic_avia"; do
      [[ -d "$C" ]] || continue
      NF=$(find "$C" ! -user "$U" 2>/dev/null | wc -l)
      [[ "$NF" -eq 0 ]] && continue
      echo
      warn "fix available" "${NF} theme cache file(s) with a foreign owner in $(basename "$C")"
      read -r -p "         delete them? they are regenerated on the next request [y/N] " ANS
      [[ "${ANS,,}" == "y" ]] && { rm -rf "${C:?}"/* && pass "fixed" "cache cleared"; }
    done
  fi

  if [[ $SITE_FAIL -eq 0 ]]; then
    SITES_OK=$((SITES_OK+1))
    [[ $QUIET -eq 0 ]] && printf '  \033[32m=> healthy\033[0m\n'
  else
    printf '  \033[31m=> %d problem(s)\033[0m\n' "$SITE_FAIL"
    SITES_BAD+=("$U")
  fi
done

printf '\n\033[1m===== SUMMARY =====\033[0m\n'
printf '  healthy: %d\n' "$SITES_OK"
if [[ ${#SITES_BAD[@]} -gt 0 ]]; then
  printf '  problems: %d\n' "${#SITES_BAD[@]}"
  for s in "${SITES_BAD[@]}"; do printf '    %s\n' "$s"; done
  cat <<'NEXT'

  Common fixes:
    ownership / update method   wp-fix-ownership --only <user>
    permalinks / rest api       wp-admin -> Settings -> Permalinks -> Save
                                or: wp-health-check --fix
    php identity = www-data     a2dismod php8.3 && systemctl restart apache2
    uploads exec not blocked    wp-harden-htaccess --only <user> --apply
    media delivery blocked      check wp-content/uploads/.htaccess
NEXT
fi
exit $((FAILED_TOTAL > 0 ? 1 : 0))
