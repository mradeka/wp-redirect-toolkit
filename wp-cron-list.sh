#!/usr/bin/env bash
#
# wp-cron-list.sh
#
# Runs `wp cron event list` against every WordPress install under
# /home/<user>/public_html/wordpress (and /home/<user>/public_html) and prints
# one table per site. Read-only - changes nothing.
#
# Hooks with random-looking names are highlighted: no plugin names its hooks
# that way, and in this incident they were written straight into the
# wp_options 'cron' value by SQL, with no code registering them.
#
# Usage:
#   ./wp-cron-list.sh                 # every site, full table
#   ./wp-cron-list.sh --suspicious    # only the flagged hooks
#   ./wp-cron-list.sh --only siteuser  # a single site user
#   ./wp-cron-list.sh --delete        # remove flagged hooks (asks first)
#
# Exit code 0 = nothing flagged, 1 = at least one site has a flagged hook.

set -uo pipefail

ONLY=""
SUSPICIOUS_ONLY=0
DELETE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --only)       ONLY="$2"; shift 2 ;;
    --suspicious) SUSPICIOUS_ONLY=1; shift ;;
    --delete)     DELETE=1; shift ;;
    -h|--help)    sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

[[ $EUID -ne 0 ]] && { echo "Run as root - it switches to each site user itself."; exit 1; }

# Hooks that legitimately exist: WordPress core plus common plugin prefixes.
KNOWN_RE='^(wp_|_wp_|do_pings|publish_future_post|akismet|jetpack|woocommerce|wc_|action_scheduler|aioseo|wpseo|rank_math|elementor|updraft|wordfence|litespeed|autoptimize|redirection|contact_form|cf7|mailpoet|backwpup|duplicator|wpforms|nf_|gform|edd_|learndash|tribe_|astra|ocean|divi|et_|avia|enfold|recovery_mode_clean_expired_keys|delete_expired_transients)'
# Random-looking: 12+ chars, lowercase letters and digits, no separators.
RANDOM_RE='^[a-z0-9]{12,}$'

FOUND=0
SUMMARY=()

mapfile -t CONFIGS < <(
  ls -d /home/*/public_html/wordpress/wp-config.php \
        /home/*/public_html/wp-config.php 2>/dev/null | sort -u
)
[[ ${#CONFIGS[@]} -eq 0 ]] && { echo "No WordPress installs found under /home/*/public_html"; exit 0; }

for CONFIG in "${CONFIGS[@]}"; do
  WP_PATH=$(dirname "$CONFIG")
  SITE_USER=$(stat -c '%U' "$CONFIG")
  SITE_HOME=$(getent passwd "$SITE_USER" | cut -d: -f6)
  [[ -n "$ONLY" && "$SITE_USER" != "$ONLY" ]] && continue

  # find a wp binary this user can actually read (open_basedir may block
  # /usr/local/bin, so the user's own home is tried first)
  WPBIN=""
  for CAND in "${SITE_HOME}/wp" "${SITE_HOME}/.wp-cli.phar" "${WP_PATH}/wp-cli.phar" /usr/local/bin/wp; do
    if sudo -u "$SITE_USER" -H test -r "$CAND" 2>/dev/null; then WPBIN="$CAND"; break; fi
  done

  printf '\n\033[1m===== %s  (%s) =====\033[0m\n' "$WP_PATH" "$SITE_USER"
  if [[ -z "$WPBIN" ]]; then
    printf '\033[31m  no usable WP-CLI for this user - skipped\033[0m\n'
    SUMMARY+=("?? ${WP_PATH} (no WP-CLI)")
    continue
  fi

  WP="sudo -u ${SITE_USER} -H ${WPBIN} --path=${WP_PATH} --skip-plugins --skip-themes"
  WPVER=$(sudo -u "$SITE_USER" -H "$WPBIN" --version 2>/dev/null | awk '{print $2}')
  case "$WPVER" in
    2.[0-6].*|1.*) printf '\033[33m  WP-CLI %s is old - some output formats are unsupported\033[0m\n' "$WPVER" ;;
  esac

  # Do not swallow the error: "could not read cron events" on its own tells
  # you nothing. WP-CLI 2.6 and older also choke on --fields with --format=csv,
  # so fall back to the plain table and parse that.
  ERR=$($WP cron event list --fields=hook,next_run_relative,recurrence --format=csv 2>&1)
  ROWS=$(echo "$ERR" | grep -vE '^(Error|Warning|Notice|PHP|Deprecated)' | tail -n +2)

  if [[ -z "$ROWS" ]]; then
    ERR2=$($WP cron event list 2>&1)
    ROWS=$(echo "$ERR2" \
           | awk -F'|' '/^\|/ && $2 !~ /hook/ {
               gsub(/^[ \t]+|[ \t]+$/, "", $2);
               gsub(/^[ \t]+|[ \t]+$/, "", $4);
               gsub(/^[ \t]+|[ \t]+$/, "", $5);
               if ($2 != "") print $2 "," $4 "," $5
             }')
    [[ -n "$ROWS" ]] && printf '\033[33m  (CSV output unavailable - parsed the table instead; consider updating WP-CLI)\033[0m\n'
  fi

  if [[ -z "$ROWS" ]]; then
    printf '\033[31m  could not read cron events: %s\033[0m\n' \
           "$(echo "$ERR" | grep -m2 -E '^(Error|Warning)' | tr '\n' ' ')"
    printf '  reproduce with: sudo -u %s -H %s --path=%s cron event list\n' \
           "$SITE_USER" "$WPBIN" "$WP_PATH"
    SUMMARY+=("?? ${WP_PATH} (cron unreadable)")
    continue
  fi

  SUSPECT_HOOKS=()
  printf '  %-38s %-22s %s\n' "hook" "next_run_relative" "recurrence"
  printf '  %-38s %-22s %s\n' "--------------------------------------" "----------------------" "----------"
  while IFS=, read -r HOOK NEXT REC; do
    [[ -z "$HOOK" ]] && continue
    if [[ ! "$HOOK" =~ $KNOWN_RE ]] && [[ "$HOOK" =~ $RANDOM_RE ]]; then
      printf '\033[31m  %-38s %-22s %s   <== SUSPICIOUS\033[0m\n' "$HOOK" "$NEXT" "$REC"
      SUSPECT_HOOKS+=("$HOOK")
      FOUND=1
    elif [[ $SUSPICIOUS_ONLY -eq 0 ]]; then
      if [[ "$HOOK" =~ $KNOWN_RE ]]; then
        printf '  %-38s %-22s %s\n' "$HOOK" "$NEXT" "$REC"
      else
        printf '\033[33m  %-38s %-22s %s   (unrecognised, readable - likely a plugin)\033[0m\n' "$HOOK" "$NEXT" "$REC"
      fi
    fi
  done <<< "$ROWS"

  if [[ ${#SUSPECT_HOOKS[@]} -eq 0 ]]; then
    printf '\033[32m  => no suspicious hooks\033[0m\n'
    SUMMARY+=("OK ${WP_PATH}")
  else
    printf '\033[31m  => %d suspicious hook(s)\033[0m\n' "${#SUSPECT_HOOKS[@]}"
    SUMMARY+=("!! ${WP_PATH} (${SUSPECT_HOOKS[*]})")

    if [[ $DELETE -eq 1 ]]; then
      # A cron entry is only a trigger. If code registered these hooks they
      # come back within the hour - so check for a backdoor before trusting
      # the deletion.
      printf '  Registering code (should be empty):\n'
      for H in "${SUSPECT_HOOKS[@]}"; do
        HIT=$(grep -rl "$H" "${WP_PATH}/wp-content" "${WP_PATH}"/*.php 2>/dev/null | head -3)
        [[ -n "$HIT" ]] && printf '\033[31m    %s -> %s\033[0m\n' "$H" "$(echo "$HIT" | tr '\n' ' ')" \
                        || printf '    %s -> none found\n' "$H"
      done
      read -r -p "  Delete these hooks on ${WP_PATH}? [y/N] " ANS
      if [[ "${ANS,,}" == "y" ]]; then
        for H in "${SUSPECT_HOOKS[@]}"; do
          $WP cron event delete "$H" && printf '\033[32m    deleted %s\033[0m\n' "$H"
        done
        printf '  Re-check in an hour: if they return, code is recreating them.\n'
      else
        printf '  skipped\n'
      fi
    fi
  fi
done

printf '\n\033[1m===== SUMMARY =====\033[0m\n'
for s in "${SUMMARY[@]}"; do printf '  %s\n' "$s"; done
if [[ $FOUND -eq 0 ]]; then
  printf '\n\033[32mNo suspicious cron hooks on any site.\033[0m\n'
else
  printf '\n\033[31mSuspicious hooks found.\033[0m Remove them with --delete,\n'
  printf 'then re-run in an hour - hooks that come back mean live access.\n'
fi
exit $FOUND
