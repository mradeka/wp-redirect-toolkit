#!/usr/bin/env bash
#
# wp-cron-audit.sh
#
# Read-only audit of every WordPress install under /home/*/public_html.
# Changes NOTHING. Looks for the traces this incident left behind:
#
#   - WP-Cron hooks with random-looking names (no code registers them; they
#     are written straight into the wp_options 'cron' value)
#   - mu-plugins, PHP inside uploads/, obfuscated code
#   - core/plugin checksum mismatches
#   - unexpected administrator accounts
#   - the redirect payload itself, and a hijacked home/siteurl
#   - database dumps or archives left inside the webroot
#
# Exit code is 0 when everything is clean, 1 when any site has findings, so
# it can be dropped into cron and will only mail you when it matters.
#
# Usage:
#   ./wp-cron-audit.sh                  # audit every site
#   ./wp-cron-audit.sh --only siteuser   # a single site user
#   ./wp-cron-audit.sh --quiet          # findings only, no per-site headers

set -uo pipefail

ONLY=""
QUIET=0
FOUND_ANY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --only)  ONLY="$2"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

[[ $EUID -ne 0 ]] && { echo "Run as root - it switches to each site user itself."; exit 1; }

hr()   { [[ $QUIET -eq 0 ]] && printf '\n\033[1m===== %s =====\033[0m\n' "$*"; return 0; }
sec()  { [[ $QUIET -eq 0 ]] && printf '\033[1m-- %s\033[0m\n' "$*"; return 0; }
ok()   { [[ $QUIET -eq 0 ]] && printf '\033[32m  [ok] %s\033[0m\n' "$*"; return 0; }
bad()  { printf '\033[31m  [FINDING] %s\033[0m\n' "$*"; FOUND_ANY=1; SITE_FINDINGS=$((SITE_FINDINGS+1)); }
note() { [[ $QUIET -eq 0 ]] && printf '  %s\n' "$*"; return 0; }

# Hooks that legitimately exist. Anything not matching these AND looking like
# a random string is reported. Core hooks all start with wp_ / _wp_; plugins
# use readable, usually underscore- or hyphen-separated names.
KNOWN_RE='^(wp_|_wp_|do_pings|publish_future_post|akismet|jetpack|woocommerce|wc_|action_scheduler|aioseo|wpseo|rank_math|elementor|updraft|wordfence|litespeed|autoptimize|redirection|contact_form|cf7|mailpoet|backwpup|duplicator|wpforms|nf_|gform|edd_|learndash|tribe_|astra|ocean|divi|et_|avia|enfold|recovery_mode_clean_expired_keys|delete_expired_transients)'
# a random-looking hook: 12+ chars, letters+digits mixed, no separators
RANDOM_RE='^[a-z0-9]{12,}$'

mapfile -t CONFIGS < <(find /home -mindepth 3 -maxdepth 5 -name wp-config.php 2>/dev/null | sort)
[[ ${#CONFIGS[@]} -eq 0 ]] && { echo "No WordPress installs found."; exit 0; }

printf 'Auditing %d install(s) at %s\n' "${#CONFIGS[@]}" "$(date '+%F %T')"

DIRTY_SITES=()

for CONFIG in "${CONFIGS[@]}"; do
  WP_PATH=$(dirname "$CONFIG")
  SITE_USER=$(stat -c '%U' "$CONFIG")
  SITE_HOME=$(getent passwd "$SITE_USER" | cut -d: -f6)
  SITE_FINDINGS=0

  [[ -n "$ONLY" && "$SITE_USER" != "$ONLY" ]] && continue
  hr "${WP_PATH}  (user: ${SITE_USER})"

  # locate a wp binary this user can actually execute
  WPBIN=""
  for CAND in "${SITE_HOME}/wp" "${SITE_HOME}/.wp-cli.phar" "${WP_PATH}/wp-cli.phar" /usr/local/bin/wp; do
    if sudo -u "$SITE_USER" -H test -r "$CAND" 2>/dev/null; then WPBIN="$CAND"; break; fi
  done
  if [[ -z "$WPBIN" ]]; then
    bad "no usable WP-CLI for ${SITE_USER} - database checks skipped"
  else
    WP="sudo -u ${SITE_USER} -H ${WPBIN} --path=${WP_PATH} --skip-plugins --skip-themes"

    # ---- 1. cron hooks -----------------------------------------------------
    sec "WP-Cron hooks"
    HOOKS=$($WP cron event list --fields=hook,next_run_relative,recurrence --format=csv 2>/dev/null | tail -n +2)
    if [[ -z "$HOOKS" ]]; then
      note "(could not read cron events)"
    else
      SUSPECT=0
      while IFS=, read -r HOOK REST; do
        [[ -z "$HOOK" ]] && continue
        if [[ ! "$HOOK" =~ $KNOWN_RE ]]; then
          if [[ "$HOOK" =~ $RANDOM_RE ]]; then
            bad "random-looking cron hook: ${HOOK}  (${REST})"
            SUSPECT=1
          else
            note "  unrecognised but readable hook: ${HOOK} - probably a plugin"
          fi
        fi
      done <<< "$HOOKS"
      [[ $SUSPECT -eq 0 ]] && ok "no random-looking hooks"
    fi

    # ---- 2. redirect payload and URL options -------------------------------
    sec "Redirect payload / site URLs"
    PREFIX=$($WP config get table_prefix 2>/dev/null)
    if [[ -n "$PREFIX" ]]; then
      N=$($WP db query "SELECT COUNT(*) FROM ${PREFIX}posts WHERE post_content LIKE '<meta http-equiv=%';" --skip-column-names 2>/dev/null)
      if [[ "${N:-0}" -gt 0 ]]; then
        TARGET=$($WP db query "SELECT SUBSTRING_INDEX(SUBSTRING_INDEX(post_content,'url=',-1),'\"',1) FROM ${PREFIX}posts WHERE post_content LIKE '<meta http-equiv=%' LIMIT 1;" --skip-column-names 2>/dev/null)
        bad "${N} rows carry a meta-refresh payload -> ${TARGET}"
      else
        ok "no meta-refresh payload in ${PREFIX}posts"
      fi
      H=$($WP option get home 2>/dev/null); S=$($WP option get siteurl 2>/dev/null)
      HH=$(echo "$H" | sed -E 's#^https?://##; s#/.*##'); SH=$(echo "$S" | sed -E 's#^https?://##; s#/.*##')
      if [[ -n "$HH" && -n "$SH" && "$HH" != "$SH" ]]; then
        bad "home and siteurl point at different hosts: ${H}  vs  ${S}"
      else
        ok "home/siteurl consistent (${H})"
      fi
    fi

    # ---- 3. accounts -------------------------------------------------------
    sec "Administrators"
    ADMINS=$($WP user list --role=administrator --field=user_login 2>/dev/null | tr '\n' ' ')
    NADM=$(echo "$ADMINS" | wc -w)
    note "  ${NADM}: ${ADMINS}"
    [[ "$NADM" -gt 3 ]] && bad "unusually many administrator accounts (${NADM}) - verify each one"

    # ---- 4. integrity ------------------------------------------------------
    sec "Core integrity"
    CK=$($WP core verify-checksums 2>&1 | grep -v '^Success')
    if [[ -z "$CK" ]]; then
      ok "core verifies"
    else
      # a modified root index.php is EXPECTED when core lives in a subdirectory
      if echo "$CK" | grep -q "index.php" && [[ -f "$(dirname "$WP_PATH")/index.php" || "$(basename "$WP_PATH")" != "public_html" ]]; then
        note "  index.php differs - normal for a subdirectory install (loader path)"
        REST_CK=$(echo "$CK" | grep -v 'index.php' | grep -v "doesn't verify against checksums")
        [[ -n "$REST_CK" ]] && bad "core files modified: $(echo "$REST_CK" | tr '\n' ' ')"
      else
        bad "core checksum mismatch: $(echo "$CK" | head -3 | tr '\n' ' ')"
      fi
    fi
  fi

  # ---- 5. filesystem (does not need WP-CLI) --------------------------------
  sec "Filesystem"
  if [[ -d "${WP_PATH}/wp-content/mu-plugins" ]]; then
    MU=$(find "${WP_PATH}/wp-content/mu-plugins" -name '*.php' | head -5)
    [[ -n "$MU" ]] && bad "mu-plugins present (loaded unconditionally): $(echo "$MU" | tr '\n' ' ')" \
                   || ok "mu-plugins directory empty"
  else
    ok "no mu-plugins directory"
  fi

  UPHP=$(find "${WP_PATH}/wp-content/uploads" -name '*.php' 2>/dev/null | head -5)
  [[ -n "$UPHP" ]] && bad "PHP inside uploads/: $(echo "$UPHP" | tr '\n' ' ')" || ok "no PHP in uploads/"

  OBF=$(grep -rlE 'eval\(|base64_decode|gzinflate|str_rot13|assert\(|\bcreate_function\b' \
        "${WP_PATH}/wp-content" --include='*.php' 2>/dev/null | head -5)
  [[ -n "$OBF" ]] && bad "obfuscation markers: $(echo "$OBF" | tr '\n' ' ')" || ok "no obfuscation markers in wp-content"

  PREP=$(grep -rn 'auto_prepend_file\|auto_append_file' "${WP_PATH}/.htaccess" \
         "${WP_PATH}/.user.ini" "${WP_PATH}/php.ini" 2>/dev/null | head -3)
  [[ -n "$PREP" ]] && bad "auto_prepend/append directive: $(echo "$PREP" | tr '\n' ' ')" || ok "no auto_prepend directives"

  # The same campaign also appends redirects to the END of JS files and drops
  # fake "coming soon" landing pages. A grep for one domain misses both, so
  # look for the structural markers instead. '//http' inside a quoted string
  # is the strongest single one - no developer writes a URL that way.
  JSHIT=$(find "$WP_PATH" -name '*.js' -type f -exec sh -c \
          'tail -c 800 "$1" | grep -qE "[\"'"'"']//https?:" && echo "$1"' _ {} \; 2>/dev/null | head -5)
  [[ -n "$JSHIT" ]] && bad "JS with appended redirect: $(echo "$JSHIT" | tr '\n' ' ')" \
                    || ok "no redirect appended to JS files"

  LAND=$(find "$WP_PATH" -maxdepth 2 -type f \( -name '*.htm' -o -name '*.html' \) \
         ! -name 'readme.html' ! -name 'license.html' 2>/dev/null \
         | xargs -r grep -lieE 'http-equiv=["'"'"']?refresh|location\.(replace|href)' 2>/dev/null | head -5)
  [[ -n "$LAND" ]] && bad "HTML page with redirect: $(echo "$LAND" | tr '\n' ' ')" \
                   || ok "no redirecting HTML pages"

  COMING=$(find "$WP_PATH" -type f -iname '*coming*soon*' 2>/dev/null | head -3)
  [[ -n "$COMING" ]] && bad "fake landing page: $(echo "$COMING" | tr '\n' ' ')"

  DUMPS=$(find "$WP_PATH" "$(dirname "$WP_PATH")" -maxdepth 2 \
          \( -name '*.sql' -o -name '*.sql.gz' -o -name '*.tar.gz' -o -name '*.zip' -o -name '*.phar' \) \
          2>/dev/null | head -5)
  [[ -n "$DUMPS" ]] && bad "web-reachable dumps/archives (contain password hashes): $(echo "$DUMPS" | tr '\n' ' ')" \
                    || ok "no dumps or archives in the webroot"

  RECENT=$(find "$WP_PATH" -name '*.php' -mtime -7 -newer "${WP_PATH}/wp-config.php" 2>/dev/null | head -10)
  if [[ -n "$RECENT" ]]; then
    note "  PHP files changed in the last 7 days (check against your own work):"
    echo "$RECENT" | while read -r f; do note "    $(stat -c '%y %n' "$f" | cut -c1-19,21-)"; done
  else
    ok "no PHP files changed in the last 7 days"
  fi

  if [[ $SITE_FINDINGS -eq 0 ]]; then
    [[ $QUIET -eq 0 ]] && printf '\033[32m  => clean\033[0m\n'
  else
    printf '\033[31m  => %d finding(s)\033[0m\n' "$SITE_FINDINGS"
    DIRTY_SITES+=("$WP_PATH")
  fi
done

printf '\n\033[1m===== RESULT =====\033[0m\n'
if [[ ${#DIRTY_SITES[@]} -eq 0 ]]; then
  printf '\033[32mAll audited sites clean.\033[0m\n'
else
  printf '\033[31mSites with findings:\033[0m\n'
  for d in "${DIRTY_SITES[@]}"; do printf '  %s\n' "$d"; done
  printf '\nNext: wp-redirect-cleanup --path <site> --wp-bin <wp> --backup <dir>\n'
fi
exit $FOUND_ANY
