#!/usr/bin/env bash
#
# wp-fix-ownership.sh
#
# Part of wp-redirect-toolkit 1.2.0
# https://github.com/mradeka/wp-redirect-toolkit
#
# Checks ownership and permissions of every WordPress install under
# /home/<user>/public_html[/wordpress], then lets you select which sites
# to fix.
#
# Background: if a "wp core download", an update or a script accidentally
# runs as root, the files end up owned by root. Symptoms:
#
#   - WordPress asks for FTP credentials when updating
#     (the PHP process is not the owner -> get_filesystem_method()
#      returns 'ftpext' instead of 'direct')
#   - media uploads fail when uploads/ is affected
#   - themes cannot write their generated stylesheets
#     (e.g. uploads/dynamic_avia/) - the site loses its styling
#
# Uploads and updates break independently: uploads only need write access to
# uploads/, while updates require the whole core to be owned by the site
# user.
#
# Changes nothing without selection and confirmation.
#
# Usage:
#   ./wp-fix-ownership.sh              # check, then select interactively
#   ./wp-fix-ownership.sh --report     # check only, no selection
#   ./wp-fix-ownership.sh --all --yes  # all affected, no prompt
#   ./wp-fix-ownership.sh --only siteuser
#   ./wp-fix-ownership.sh --no-chmod   # ownership only, leave permissions

set -uo pipefail

ONLY=""
REPORT=0
ALL=0
ASSUME_YES=0
DO_CHMOD=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --report)   REPORT=1; shift ;;
    --all)      ALL=1; shift ;;
    --yes)      ASSUME_YES=1; shift ;;
    --only)     ONLY="$2"; shift 2 ;;
    --no-chmod) DO_CHMOD=0; shift ;;
    -h|--help)  sed -n '2,33p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

[[ $EUID -ne 0 ]] && { echo "Run as root."; exit 1; }

hr()   { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { printf '\033[32m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*"; }
bad()  { printf '\033[31m%s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. Check
# ---------------------------------------------------------------------------
hr "Checking installations"

mapfile -t CONFIGS < <(
  ls -d /home/*/public_html/wordpress/wp-config.php \
        /home/*/public_html/wp-config.php 2>/dev/null | sort -u
)
[[ ${#CONFIGS[@]} -eq 0 ]] && { echo "No WordPress installations found."; exit 0; }

declare -a PATHS=() USERS=() SITE_GROUPS=() COUNTS=() DETAILS=()
IDX=0

printf '\n  %-3s %-20s %8s  %-9s %s\n' "No" "user" "foreign" "area" "path"
printf '  %s\n' "---------------------------------------------------------------------------------------"

for CONFIG in "${CONFIGS[@]}"; do
  D=$(dirname "$CONFIG")
  # Derive the expected owner from the PATH, not from wp-config.php.
  # Deriving it from the file itself is circular: if wp-config.php is owned by
  # root, U becomes root and "find ! -user root" reports zero foreign files -
  # precisely in the case this script is meant to detect.
  U=$(echo "$CONFIG" | sed -nE 's#^/home/([^/]+)/.*#\1#p')
  if [[ -z "$U" ]] || ! getent passwd "$U" >/dev/null; then
    # not a /home/<user>/ layout, or no such account - fall back to the file
    U=$(stat -c '%U' "$CONFIG")
    warn "could not derive the site user from the path, using the owner of wp-config.php (${U})"
  fi
  G=$(id -gn "$U" 2>/dev/null || stat -c '%G' "$CONFIG")

  # Point it out when wp-config.php itself has the wrong owner - that is what
  # made the old detection fail.
  # Note: use if/fi, not "[[ ... ]] && warn". A false test returns exit code 1,
  # and as the last statement before the loop continues that can abort the
  # whole loop - which silently reduced the report to a single site.
  CONF_OWNER=$(stat -c '%U' "$CONFIG")
  if [[ "$CONF_OWNER" != "$U" ]]; then
    warn "wp-config.php is owned by ${CONF_OWNER}, expected ${U}"
  fi
  [[ -n "$ONLY" && "$U" != "$ONLY" ]] && continue

  N=$(find "$D" ! -user "$U" 2>/dev/null | wc -l)

  # Where exactly does it sit? That decides which symptom appears.
  N_CORE=$(find "$D" -maxdepth 1 ! -user "$U" 2>/dev/null | wc -l)
  N_ADMIN=$(find "$D/wp-admin" "$D/wp-includes" ! -user "$U" 2>/dev/null | wc -l)
  N_UP=$(find "$D/wp-content/uploads" ! -user "$U" 2>/dev/null | wc -l)
  N_CONT=$(find "$D/wp-content" -maxdepth 1 ! -user "$U" 2>/dev/null | wc -l)

  BEREICH=""
  [[ "$N_ADMIN" -gt 0 || "$N_CORE" -gt 0 ]] && BEREICH="core"
  [[ "$N_UP"    -gt 0 ]] && BEREICH="${BEREICH:+$BEREICH+}uploads"
  [[ "$N_CONT"  -gt 0 && -z "$BEREICH" ]] && BEREICH="content"
  [[ -z "$BEREICH" && "$N" -gt 0 ]] && BEREICH="other"
  [[ "$N" -eq 0 ]] && BEREICH="-"

  # foreign owners by name - often tells you who did it
  OWNERS=$(find "$D" ! -user "$U" -printf '%u\n' 2>/dev/null | sort -u | tr '\n' ' ')

  IDX=$((IDX+1))
  PATHS+=("$D"); USERS+=("$U"); SITE_GROUPS+=("$G"); COUNTS+=("$N")
  DETAILS+=("core:${N_ADMIN} uploads:${N_UP} content:${N_CONT} owners:${OWNERS:-–}")

  if [[ "$N" -eq 0 ]]; then
    printf '  %-3s %-20s \033[32m%8s\033[0m  %-9s %s\n' "$IDX" "$U" "$N" "$BEREICH" "$D"
  else
    printf '  %-3s %-20s \033[31m%8s\033[0m  %-9s %s\n' "$IDX" "$U" "$N" "$BEREICH" "$D"
    printf '      %s\n' "${DETAILS[$((IDX-1))]}"
  fi
done

BETROFFEN=()
for i in "${!COUNTS[@]}"; do
  [[ "${COUNTS[$i]}" -gt 0 ]] && BETROFFEN+=("$i")
done

hr "Result"
if [[ ${#BETROFFEN[@]} -eq 0 ]]; then
  ok "  All ${IDX} installation(s) are owned by their site user."
  echo "  Uploads and updates should work without the FTP prompt."
  exit 0
fi

bad "  ${#BETROFFEN[@]} of ${IDX} installation(s) have foreign owners."
cat <<'ERKL'

  How to read this:
    core affected      -> updates will ask for FTP credentials
    uploads affected   -> media uploads fail
    both possible      -> they break independently, depending on the area
ERKL

[[ $REPORT -eq 1 ]] && { echo; echo "  (--report: nothing changed)"; exit 1; }

# ---------------------------------------------------------------------------
# 2. Select
# ---------------------------------------------------------------------------
AUSWAHL=()
if [[ $ALL -eq 1 ]]; then
  AUSWAHL=("${BETROFFEN[@]}")
  warn "  --all: every affected installation selected"
else
  hr "Selection"
  echo "  Enter the numbers to fix:"
  echo "    single     2 5 7"
  echo "    range      2-5"
  echo "    all        a"
  echo "    abort      q  (or empty)"
  echo
  printf '  affected: '
  for i in "${BETROFFEN[@]}"; do printf '%s ' "$((i+1))"; done; echo
  echo
  read -r -p "  Selection: " EINGABE

  [[ -z "$EINGABE" || "${EINGABE,,}" == "q" ]] && { echo "  aborted"; exit 0; }

  if [[ "${EINGABE,,}" == "a" ]]; then
    AUSWAHL=("${BETROFFEN[@]}")
  else
    for TOKEN in $EINGABE; do
      if [[ "$TOKEN" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        for ((n=${BASH_REMATCH[1]}; n<=${BASH_REMATCH[2]}; n++)); do
          [[ "$n" -ge 1 && "$n" -le "$IDX" ]] && AUSWAHL+=("$((n-1))")
        done
      elif [[ "$TOKEN" =~ ^[0-9]+$ ]]; then
        if [[ "$TOKEN" -ge 1 && "$TOKEN" -le "$IDX" ]]; then
          AUSWAHL+=("$((TOKEN-1))")
        else
          warn "  ignored: ${TOKEN} (outside 1-${IDX})"
        fi
      else
        warn "  ignored: ${TOKEN}"
      fi
    done
  fi
fi

# remove duplicates
mapfile -t AUSWAHL < <(printf '%s\n' "${AUSWAHL[@]:-}" | grep -E '^[0-9]+$' | sort -un)
[[ ${#AUSWAHL[@]} -eq 0 ]] && { echo "  nothing selected"; exit 0; }

# ---------------------------------------------------------------------------
# 3. Confirm
# ---------------------------------------------------------------------------
hr "About to fix"
for i in "${AUSWAHL[@]}"; do
  printf '  %-20s %6s file(s)  %s\n' "${USERS[$i]}" "${COUNTS[$i]}" "${PATHS[$i]}"
done
echo
echo "  chown -R <user>:<group> on the installation directory"
if [[ $DO_CHMOD -eq 1 ]]; then
  echo "  chmod 755 for directories, 644 for files, 640 for wp-config.php"
  warn "  Note: custom scripts lose their executable bit."
  warn "  Use --no-chmod to set ownership only."
else
  echo "  Permissions left unchanged (--no-chmod)"
fi

if [[ $ASSUME_YES -eq 0 ]]; then
  echo
  read -r -p "  Proceed? [y/N] " ANS
  [[ "${ANS,,}" == "y" ]] || { echo "  aborted"; exit 0; }
fi

# ---------------------------------------------------------------------------
# 4. Fix
# ---------------------------------------------------------------------------
hr "Fixing"
FEHLER=0
for i in "${AUSWAHL[@]}"; do
  D="${PATHS[$i]}"; U="${USERS[$i]}"; G="${SITE_GROUPS[$i]}"
  printf '  %s ... ' "$D"

  # Record executable files first so they can be traced if chmod
  # flattens something
  EXECS=$(find "$D" -type f -perm -u+x 2>/dev/null | head -50)
  [[ -n "$EXECS" ]] && {
    LOG="/root/wp-fix-ownership-execs-$(basename "$(dirname "$D")")-$(date +%F-%H%M%S).txt"
    echo "$EXECS" > "$LOG"
  }

  if ! chown -R "$U:$G" "$D" 2>/dev/null; then
    bad "chown failed"; FEHLER=$((FEHLER+1)); continue
  fi

  if [[ $DO_CHMOD -eq 1 ]]; then
    find "$D" -type d -exec chmod 755 {} + 2>/dev/null
    find "$D" -type f -exec chmod 644 {} + 2>/dev/null
    [[ -f "$D/wp-config.php" ]] && chmod 640 "$D/wp-config.php"
  fi

  REST=$(find "$D" ! -user "$U" 2>/dev/null | wc -l)
  if [[ "$REST" -eq 0 ]]; then
    ok "ok"
    [[ -n "${LOG:-}" ]] && printf '      previously executable files noted in %s\n' "$LOG"
  else
    bad "${REST} file(s) still foreign - check manually"
    FEHLER=$((FEHLER+1))
  fi
  unset LOG
done

# ---------------------------------------------------------------------------
# 5. Verify
# ---------------------------------------------------------------------------
hr "Verification"
for i in "${AUSWAHL[@]}"; do
  D="${PATHS[$i]}"; U="${USERS[$i]}"
  WPBIN=""
  for CAND in "/home/${U}/wp" "/home/${U}/.wp-cli.phar" /usr/local/bin/wp; do
    sudo -u "$U" -H test -r "$CAND" 2>/dev/null && { WPBIN="$CAND"; break; }
  done
  [[ -z "$WPBIN" ]] && continue
  M=$(sudo -u "$U" -H "$WPBIN" --path="$D" --skip-plugins --skip-themes eval \
        'require_once ABSPATH."wp-admin/includes/file.php"; echo get_filesystem_method();' 2>/dev/null)
  case "$M" in
    direct) printf '  %-20s \033[32mdirect\033[0m - updates work without the FTP prompt\n' "$U" ;;
    "")     printf '  %-20s (could not determine)\n' "$U" ;;
    *)      printf '  %-20s \033[31m%s\033[0m - still prompts for credentials\n' "$U" "$M" ;;
  esac
done

cat <<'NEXT'

  Still to check:
    - trigger an update in wp-admin (must not ask for FTP credentials)
    - test a media upload
    - Enfold/Divi: regenerate the merged stylesheets
      (Enfold -> Performance -> "Delete old CSS and JS files", then save)

  If foreign owners reappear after the next update, that update itself ran as
  root - the cause is then a cron job or a panel task, not manual work.
NEXT

exit $FEHLER
