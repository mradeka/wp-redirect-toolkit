#!/usr/bin/env bash
#
# wp-user-audit.sh
#
# Lists the WordPress accounts of every install under
# /home/<user>/public_html/wordpress and flags the ones that look
# attacker-created.
#
# WHY NOT JUST "name != /home/<user>"?
#   A WordPress login has no relation to the Unix account. Editors, authors,
#   subscribers and shop customers never match the home directory name, and
#   `wp user delete` reassigns or destroys their posts. Matching on the name
#   alone would delete real people. This script scores several signals
#   instead and never deletes without asking.
#
# Signals used (each adds to the score):
#   +3  administrator whose login differs from the site's Unix user
#   +2  registered after the incident window (--since, default 2026-08-01)
#   +2  email domain differs from the site domain and from the other users
#   +1  zero posts and zero comments
#   +1  login looks machine-generated (random letters+digits)
#   -3  registered long before the incident and has authored content
#
# Score >= 4 is reported as suspicious. Nothing is ever deleted unless you
# pass --delete and confirm each account individually.
#
# Usage:
#   ./wp-user-audit.sh                        # report across all sites
#   ./wp-user-audit.sh --only siteuser         # one site
#   ./wp-user-audit.sh --since 2026-07-15     # widen the incident window
#   ./wp-user-audit.sh --delete               # ask per flagged account
#   ./wp-user-audit.sh --delete --reassign 1  # move their posts to user ID 1
#   ./wp-user-audit.sh --shuffle-salts        # new auth keys on every site
#   ./wp-user-audit.sh --shuffle-salts --yes  # ... without asking
#
# --shuffle-salts rewrites the AUTH_KEY/SALT constants in wp-config.php. Every
# existing login cookie becomes invalid, so anyone holding a stolen session -
# including you - is logged out and must sign in again. It does NOT change any
# password. Run it AFTER the way in is closed, otherwise the attacker simply
# logs back in.

set -uo pipefail

ONLY=""
SINCE="2026-08-01"
DELETE=0
REASSIGN=""
SHUFFLE=0
ASSUME_YES=0
FOUND=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --only)     ONLY="$2"; shift 2 ;;
    --since)    SINCE="$2"; shift 2 ;;
    --delete)   DELETE=1; shift ;;
    --reassign) REASSIGN="$2"; shift 2 ;;
    --shuffle-salts) SHUFFLE=1; shift ;;
    --yes)      ASSUME_YES=1; shift ;;
    -h|--help)  sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

[[ $EUID -ne 0 ]] && { echo "Run as root - it switches to each site user itself."; exit 1; }

RANDOM_RE='^[a-z]*[0-9]+[a-z0-9]*$'
SHUFFLE_TARGETS=()

mapfile -t CONFIGS < <(
  ls -d /home/*/public_html/wordpress/wp-config.php \
        /home/*/public_html/wp-config.php 2>/dev/null | sort -u
)
[[ ${#CONFIGS[@]} -eq 0 ]] && { echo "No WordPress installs found."; exit 0; }

for CONFIG in "${CONFIGS[@]}"; do
  WP_PATH=$(dirname "$CONFIG")
  SITE_USER=$(stat -c '%U' "$CONFIG")
  SITE_HOME=$(getent passwd "$SITE_USER" | cut -d: -f6)
  [[ -n "$ONLY" && "$SITE_USER" != "$ONLY" ]] && continue

  WPBIN=""
  for CAND in "${SITE_HOME}/wp" "${SITE_HOME}/.wp-cli.phar" "${WP_PATH}/wp-cli.phar" /usr/local/bin/wp; do
    sudo -u "$SITE_USER" -H test -r "$CAND" 2>/dev/null && { WPBIN="$CAND"; break; }
  done

  printf '\n\033[1m===== %s  (unix user: %s) =====\033[0m\n' "$WP_PATH" "$SITE_USER"
  [[ -z "$WPBIN" ]] && { printf '\033[31m  no usable WP-CLI - skipped\033[0m\n'; continue; }

  WP="sudo -u ${SITE_USER} -H ${WPBIN} --path=${WP_PATH} --skip-plugins --skip-themes"
  SHUFFLE_TARGETS+=("${SITE_USER}|${WPBIN}|${WP_PATH}")

  SITE_DOMAIN=$($WP option get home 2>/dev/null | sed -E 's#^https?://(www\.)?##; s#/.*##')

  # Do not swallow the error, and do not rely on --fields with --format=csv:
  # WP-CLI 2.6 and older return nothing for that combination.
  UERR=$($WP user list --fields=ID,user_login,user_email,roles,user_registered --format=csv 2>&1)
  USERS=$(echo "$UERR" | grep -vE '^(Error|Warning|Notice|PHP|Deprecated)' | tail -n +2)

  if [[ -z "$USERS" ]]; then
    # fall back to the default table and pull the columns out of it
    UERR2=$($WP user list 2>&1)
    USERS=$(echo "$UERR2" | awk -F'|' '/^\|/ && $2 !~ /ID/ {
        for (i=2; i<=NF; i++) gsub(/^[ \t]+|[ \t]+$/, "", $i);
        if ($2 != "") print $2 "," $3 "," $5 "," $7 "," $6
      }')
    [[ -n "$USERS" ]] && printf '\033[33m  (CSV-Ausgabe nicht verfuegbar - Tabelle ausgewertet; WP-CLI veraltet)\033[0m\n'
  fi

  if [[ -z "$USERS" ]]; then
    printf '\033[31m  could not read users: %s\033[0m\n' \
           "$(echo "$UERR" | grep -m2 -E '^(Error|Warning)' | tr '\n' ' ')"
    printf '  nachstellen mit: sudo -u %s -H %s --path=%s user list\n' \
           "$SITE_USER" "$WPBIN" "$WP_PATH"
    continue
  fi

  printf '  site domain: %s   incident window: from %s\n\n' "${SITE_DOMAIN:-?}" "$SINCE"
  printf '  %-5s %-22s %-30s %-15s %-12s %-6s\n' "ID" "login" "email" "role" "registered" "posts"
  printf '  %s\n' "--------------------------------------------------------------------------------------------------------"

  SUSPECT_IDS=(); SUSPECT_LOGINS=()

  while IFS=, read -r ID LOGIN EMAIL ROLES REG; do
    [[ -z "$ID" || "$ID" == "ID" ]] && continue
    REGDATE="${REG%% *}"
    POSTS=$($WP db query "SELECT COUNT(*) FROM $($WP config get table_prefix 2>/dev/null)posts WHERE post_author=${ID} AND post_type IN ('post','page');" --skip-column-names 2>/dev/null)
    POSTS="${POSTS:-0}"

    SCORE=0; WHY=""
    if [[ "$ROLES" == *administrator* && "$LOGIN" != "$SITE_USER" ]]; then
      SCORE=$((SCORE+3)); WHY="${WHY}admin≠unixuser "
    fi
    if [[ -n "$REGDATE" && "$REGDATE" > "$SINCE" ]]; then
      SCORE=$((SCORE+2)); WHY="${WHY}neu-registriert "
    fi
    EMDOM="${EMAIL##*@}"
    if [[ -n "$SITE_DOMAIN" && -n "$EMDOM" && "$EMDOM" != *"$SITE_DOMAIN"* ]]; then
      SCORE=$((SCORE+2)); WHY="${WHY}fremde-maildomain "
    fi
    if [[ "$POSTS" -eq 0 ]]; then
      SCORE=$((SCORE+1)); WHY="${WHY}keine-beitraege "
    fi
    if [[ "$LOGIN" =~ $RANDOM_RE && ${#LOGIN} -ge 8 ]]; then
      SCORE=$((SCORE+1)); WHY="${WHY}zufallsname "
    fi
    if [[ -n "$REGDATE" && "$REGDATE" < "$SINCE" && "$POSTS" -gt 0 ]]; then
      SCORE=$((SCORE-3)); WHY="${WHY}alt+aktiv "
    fi
    # A subscriber or shop customer cannot change the site. Registered before
    # the incident, such an account is almost always a real person, and the
    # "foreign mail domain / no posts" signals describe every one of them.
    if [[ "$ROLES" == *subscriber* || "$ROLES" == *customer* ]]; then
      if [[ -z "$REGDATE" || "$REGDATE" < "$SINCE" ]]; then
        SCORE=$((SCORE-3)); WHY="${WHY}nur-abonnent "
      fi
    fi

    if [[ $SCORE -ge 4 ]]; then
      printf '\033[31m  %-5s %-22s %-30s %-15s %-12s %-6s  <== VERDACHT (%d: %s)\033[0m\n' \
             "$ID" "$LOGIN" "$EMAIL" "$ROLES" "$REGDATE" "$POSTS" "$SCORE" "$WHY"
      SUSPECT_IDS+=("$ID"); SUSPECT_LOGINS+=("$LOGIN")
      FOUND=1
    else
      printf '  %-5s %-22s %-30s %-15s %-12s %-6s\n' "$ID" "$LOGIN" "$EMAIL" "$ROLES" "$REGDATE" "$POSTS"
    fi
  done <<< "$USERS"

  if [[ ${#SUSPECT_IDS[@]} -eq 0 ]]; then
    printf '\033[32m\n  => keine verdaechtigen Konten\033[0m\n'
    continue
  fi

  printf '\033[31m\n  => %d verdaechtige(s) Konto/Konten\033[0m\n' "${#SUSPECT_IDS[@]}"

  [[ $DELETE -eq 0 ]] && { printf '  (Nur Bericht. Loeschen mit --delete, dann wird je Konto gefragt.)\n'; continue; }

  for i in "${!SUSPECT_IDS[@]}"; do
    ID="${SUSPECT_IDS[$i]}"; LOGIN="${SUSPECT_LOGINS[$i]}"
    printf '\n  --- Konto %s (ID %s) ---\n' "$LOGIN" "$ID"
    $WP user get "$ID" --fields=ID,user_login,user_email,user_registered,roles 2>/dev/null
    PC=$($WP post list --author="$ID" --post_type=post,page --format=count 2>/dev/null)
    printf '  eigene Beitraege/Seiten: %s\n' "${PC:-0}"
    if [[ "${PC:-0}" -gt 0 && -z "$REASSIGN" ]]; then
      printf '\033[33m  Dieses Konto hat Inhalte. Ohne --reassign <ID> gingen sie verloren - uebersprungen.\033[0m\n'
      continue
    fi
    read -r -p "  Konto ${LOGIN} auf ${WP_PATH} loeschen? [y/N] " ANS
    if [[ "${ANS,,}" == "y" ]]; then
      if [[ -n "$REASSIGN" ]]; then
        $WP user delete "$ID" --reassign="$REASSIGN" --yes && printf '\033[32m    geloescht, Inhalte an ID %s uebertragen\033[0m\n' "$REASSIGN"
      else
        $WP user delete "$ID" --yes && printf '\033[32m    geloescht\033[0m\n'
      fi
    else
      printf '    uebersprungen\n'
    fi
  done
done

if [[ $SHUFFLE -eq 1 ]]; then
  printf '\n\033[1m===== AUTH-SALTS ERNEUERN =====\033[0m\n'
  printf 'Betrifft %d Installation(en). Alle angemeldeten Sitzungen werden ungueltig -\n' "${#SHUFFLE_TARGETS[@]}"
  printf 'auch deine eigenen. Passwoerter bleiben unveraendert.\n\n'
  for T in "${SHUFFLE_TARGETS[@]}"; do printf '  %s\n' "${T##*|}"; done

  DO=1
  if [[ $ASSUME_YES -eq 0 ]]; then
    read -r -p $'\nSalts auf allen genannten Installationen erneuern? [y/N] ' ANS
    [[ "${ANS,,}" == "y" ]] || DO=0
  fi

  if [[ $DO -eq 0 ]]; then
    printf '  abgebrochen\n'
  else
    OKC=0; FAILC=0
    for T in "${SHUFFLE_TARGETS[@]}"; do
      IFS='|' read -r U B P <<< "$T"
      # wp-config.php is rewritten in place - keep a copy first
      BK="${P}/wp-config.php.bak-$(date +%F-%H%M%S)"
      sudo -u "$U" -H cp -p "${P}/wp-config.php" "$BK" 2>/dev/null
      if sudo -u "$U" -H "$B" --path="$P" config shuffle-salts >/dev/null 2>&1; then
        printf '\033[32m  [ok] %s\033[0m\n' "$P"
        # the backup holds the OLD keys and sits in the webroot - remove it
        sudo -u "$U" -H rm -f "$BK"
        OKC=$((OKC+1))
      else
        printf '\033[31m  [fehlgeschlagen] %s (Sicherung: %s)\033[0m\n' "$P" "$BK"
        FAILC=$((FAILC+1))
      fi
    done
    printf '\n  %d erneuert, %d fehlgeschlagen\n' "$OKC" "$FAILC"
    printf '  Melde dich jetzt neu an. Bleiben Seiten unerreichbar, wp-config.php pruefen.\n'
  fi
fi

printf '\n\033[1m===== HINWEIS =====\033[0m\n'
cat <<'NOTE'
Konten zu loeschen behebt das Symptom, nicht die Ursache. Wer die Konten per
SQL anlegen konnte, legt sie erneut an. Vor dem Loeschen:
  - Zugang schliessen (Webmin nicht oeffentlich, Passwoerter wechseln)
  - wp config shuffle-salts  -> wirft alle bestehenden Sitzungen raus
  - danach erneut pruefen: tauchen die Konten wieder auf, besteht der Zugang
NOTE
exit $FOUND
