#!/usr/bin/env bash
#
# wp-cleanup-all.sh
#
# Part of wp-redirect-toolkit 1.2.0
# https://github.com/mradeka/wp-redirect-toolkit
#
# Discovers every WordPress install under /home/*/public_html (both the
# .../public_html and .../public_html/wordpress layouts) and runs
# wp-redirect-cleanup against each one, as that site's own user.
#
# The injected domain is auto-detected per site by the cleanup script, which
# matters: the target domain differs from site to site, and running with the
# wrong --domain silently reports a clean install.
#
# Run as root. DRY RUN unless you pass --apply.
#
# Usage:
#   ./wp-cleanup-all.sh                 # scan everything, change nothing
#   ./wp-cleanup-all.sh --apply         # clean everything
#   ./wp-cleanup-all.sh --only siteuser  # just one site user
#   ./wp-cleanup-all.sh --summary       # one line per site, no detail

set -uo pipefail

CLEANUP="${CLEANUP:-/usr/local/bin/wp-redirect-cleanup}"
APPLY=""
ONLY=""
SUMMARY=0
LOGDIR="/root/wp-cleanup-logs"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)   APPLY="--apply"; shift ;;
    --only)    ONLY="$2"; shift 2 ;;
    --summary) SUMMARY=1; shift ;;
    --logdir)  LOGDIR="$2"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

[[ $EUID -ne 0 ]] && { echo "Run as root - it switches to each site user itself."; exit 1; }
[[ -x "$CLEANUP" ]] || { echo "Cleanup script not found at ${CLEANUP}"; exit 1; }

mkdir -p "$LOGDIR"; chmod 700 "$LOGDIR"
STAMP=$(date +%F-%H%M%S)
echo "mode: ${APPLY:-DRY RUN}   logs: ${LOGDIR}"

# --- discover -------------------------------------------------------------
# maxdepth 2 catches both public_html/wp-config.php and
# public_html/wordpress/wp-config.php without descending into wp-content.
mapfile -t INSTALLS < <(find /home -mindepth 3 -maxdepth 4 -name wp-config.php 2>/dev/null | sort)

[[ ${#INSTALLS[@]} -eq 0 ]] && { echo "No WordPress installs found under /home/*/public_html"; exit 0; }

printf '\nFound %d install(s):\n' "${#INSTALLS[@]}"
for c in "${INSTALLS[@]}"; do printf '  %s\n' "$(dirname "$c")"; done

FAILED=(); CLEAN=(); DIRTY=()

for CONFIG in "${INSTALLS[@]}"; do
  WP_PATH=$(dirname "$CONFIG")
  # Derive the site user from the PATH, not from wp-config.php: if that file
  # is owned by root, so would the derived user be - and everything would run
  # as root, creating root-owned files.
  SITE_USER=$(echo "$CONFIG" | sed -nE 's#^/home/([^/]+)/.*#\1#p')
  { [[ -z "$SITE_USER" ]] || ! getent passwd "$SITE_USER" >/dev/null; } \
    && SITE_USER=$(stat -c '%U' "$CONFIG")
  SITE_HOME=$(getent passwd "$SITE_USER" | cut -d: -f6)

  [[ -n "$ONLY" && "$SITE_USER" != "$ONLY" ]] && continue

  printf '\n\033[1m########## %s  (user: %s) ##########\033[0m\n' "$WP_PATH" "$SITE_USER"

  if [[ -z "$SITE_HOME" || ! -d "$SITE_HOME" ]]; then
    echo "  no valid home directory for ${SITE_USER} - skipping"
    FAILED+=("$WP_PATH"); continue
  fi

  # Each site user needs a wp it can actually execute. Copy the phar into the
  # user's own home: open_basedir restrictions commonly block /usr/local/bin.
  SITE_WP="${SITE_HOME}/.wp-cli.phar"
  if [[ ! -x "$SITE_WP" ]]; then
    if [[ -f /usr/local/bin/wp ]]; then
      install -m 755 -o "$SITE_USER" -g "$(id -gn "$SITE_USER")" /usr/local/bin/wp "$SITE_WP"
    else
      echo "  /usr/local/bin/wp missing - install WP-CLI first"; FAILED+=("$WP_PATH"); continue
    fi
  fi

  BACKUP="${SITE_HOME}/tmp"
  install -d -m 700 -o "$SITE_USER" -g "$(id -gn "$SITE_USER")" "$BACKUP"

  LOG="${LOGDIR}/$(echo "${WP_PATH}" | tr '/' '_')-${STAMP}.log"

  # Redirect outside of sudo: the log file belongs to root, not the site
  # user - otherwise that user could tamper with it later.
  { sudo -u "$SITE_USER" -H "$CLEANUP" \
      --path "$WP_PATH" \
      --wp-bin "$SITE_WP" \
      --backup "$BACKUP" \
      $APPLY 2>&1; RC=$?; } > "$LOG"

  if [[ $RC -ne 0 ]]; then
    echo "  FAILED (exit ${RC}) - see ${LOG}"
    FAILED+=("$WP_PATH")
  else
    HITS=$(grep -c '^\[HIT\]' "$LOG")
    DOM=$(grep -m1 'auto-detected injected domain' "$LOG" | sed 's/.*: //')
    if [[ "$HITS" -eq 0 ]]; then
      echo "  clean"
      CLEAN+=("$WP_PATH")
    else
      echo "  ${HITS} finding(s)${DOM:+, domain: ${DOM}}"
      DIRTY+=("$WP_PATH")
    fi
    [[ $SUMMARY -eq 0 ]] && cat "$LOG"
  fi
done

# --- summary --------------------------------------------------------------
printf '\n\033[1m===== SUMMARY (%s) =====\033[0m\n' "${APPLY:-DRY RUN}"
printf 'clean   : %d\n' "${#CLEAN[@]}"
printf 'findings: %d\n' "${#DIRTY[@]}"; for d in "${DIRTY[@]:-}"; do [[ -n "$d" ]] && printf '   %s\n' "$d"; done
printf 'failed  : %d\n' "${#FAILED[@]}"; for f in "${FAILED[@]:-}"; do [[ -n "$f" ]] && printf '   %s\n' "$f"; done
printf '\nFull logs in %s\n' "$LOGDIR"
[[ -z "$APPLY" ]] && printf 'This was a dry run. Re-run with --apply to write changes.\n'
