#!/usr/bin/env bash
#
# wp-db-audit.sh
#
# Read-only audit of what lives in the DATABASE and in the WordPress
# configuration of every install under /home/*/public_html.
#
#   - WP-Cron hooks with random-looking names (written straight into
#     wp_options 'cron'; no code registers them)
#   - the redirect payload in wp_posts
#   - home and siteurl pointing at different hosts
#   - administrator accounts
#
# Everything file-based - checksums, JS injections, landing pages, PHP in
# uploads, obfuscation, dumps in the webroot - is the job of wp-asset-scan.
# The split follows the data source: this script asks the database, that one
# looks at files.
#
# Exit code is 0 when everything is clean, 1 when any site has findings, so
# it can be dropped into cron and will only mail you when it matters.
#
# Usage:
#   ./wp-db-audit.sh                    # audit every site
#   ./wp-db-audit.sh --only siteuser    # a single site user
#   ./wp-db-audit.sh --quiet            # findings only, no per-site headers
#
# This script used to be called wp-cron-audit. The name promised cron and
# delivered everything - hence the rename and the split. install.sh removes
# the old name when installing.

set -uo pipefail

ONLY=""
QUIET=0
FOUND_ANY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --only)  ONLY="$2"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
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
  printf '\nNext: wp-redirect-cleanup --path <site> --wp-bin <wp> --backup <dir>\nCheck the filesystem separately: wp-asset-scan\n'
fi
exit $FOUND_ANY
