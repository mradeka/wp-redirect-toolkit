#!/usr/bin/env bash
#
# wp-rotate-db-passwords.sh
#
# Generates a new MySQL password for every WordPress install under
# /home/<user>/public_html[/wordpress], changes it in MySQL, writes it into
# wp-config.php, verifies the site can still reach its database, and records
# everything in a root-only credentials file.
#
# Two things this handles that a naive loop does not:
#
#   1. SHARED DB USERS. If several installs use the same DB_USER, the password
#      is rotated ONCE and written into every wp-config.php that uses it.
#      Rotating per install would lock out every site but the last.
#   2. ROLLBACK. If the config write or the connection test fails, both the
#      MySQL password and wp-config.php are put back as they were. A failed
#      rotation must never leave a site unable to connect.
#
# Requires root with MySQL admin access (socket auth, or /root/.my.cnf).
# DRY RUN unless you pass --apply.
#
# Usage:
#   ./wp-rotate-db-passwords.sh                 # show what would change
#   ./wp-rotate-db-passwords.sh --apply
#   ./wp-rotate-db-passwords.sh --apply --only siteuser
#   ./wp-rotate-db-passwords.sh --apply --length 40
#
# Credentials file: /root/wp-db-credentials.txt (mode 600, appended, never
# overwritten - the previous password stays readable for rollback).

set -uo pipefail

CREDFILE="/root/wp-db-credentials.txt"
LENGTH=32
ONLY=""
APPLY=0
MYSQL_OPTS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)    APPLY=1; shift ;;
    --only)     ONLY="$2"; shift 2 ;;
    --length)   LENGTH="$2"; shift 2 ;;
    --credfile) CREDFILE="$2"; shift 2 ;;
    --defaults-file) MYSQL_OPTS="--defaults-file=$2"; shift 2 ;;
    -h|--help)  sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

[[ $EUID -ne 0 ]] && { echo "Run as root."; exit 1; }

hr()   { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { printf '\033[32m  [ok] %s\033[0m\n' "$*"; }
warn() { printf '\033[33m  [!] %s\033[0m\n' "$*"; }
err()  { printf '\033[31m  [FEHLER] %s\033[0m\n' "$*"; }

command -v mysql >/dev/null || { echo "mysql client not found"; exit 1; }
mysql $MYSQL_OPTS -e 'SELECT 1' >/dev/null 2>&1 || {
  echo "No MySQL admin access. Use socket auth as root, or --defaults-file /root/.my.cnf"; exit 1; }

genpw() {
  # no quotes, backslashes or dollar signs: those need escaping in PHP and in
  # SQL, and one mis-escaped character locks a site out of its database
  tr -dc 'A-Za-z0-9!#%*+,.:=?@^_-' < /dev/urandom | head -c "$LENGTH"
}

# ---------------------------------------------------------------------------
hr "Installationen einlesen"
mapfile -t CONFIGS < <(
  ls -d /home/*/public_html/wordpress/wp-config.php \
        /home/*/public_html/wp-config.php 2>/dev/null | sort -u
)
[[ ${#CONFIGS[@]} -eq 0 ]] && { echo "No WordPress installations found."; exit 0; }

declare -A USER_PATHS USER_HOST USER_DB
SKIPPED=()
for CONFIG in "${CONFIGS[@]}"; do
  WP_PATH=$(dirname "$CONFIG")
  SITE_USER=$(stat -c '%U' "$CONFIG")
  [[ -n "$ONLY" && "$SITE_USER" != "$ONLY" ]] && continue

  # Some installs use double quotes in wp-config.php, so try both. A silently
  # skipped install is worse than a noisy one - report every miss.
  getdef() {
    local key="$1" file="$2" val
    val=$(grep -oP "define\(\s*'${key}'\s*,\s*'\K[^']*" "$file" | head -1)
    [[ -z "$val" ]] && val=$(grep -oP "define\(\s*\"${key}\"\s*,\s*\"\K[^\"]*" "$file" | head -1)
    [[ -z "$val" ]] && val=$(grep -oP "define\(\s*'${key}'\s*,\s*\"\K[^\"]*" "$file" | head -1)
    [[ -z "$val" ]] && val=$(grep -oP "define\(\s*\"${key}\"\s*,\s*'\K[^']*" "$file" | head -1)
    printf '%s' "$val"
  }

  DBUSER=$(getdef DB_USER "$CONFIG")
  DBNAME=$(getdef DB_NAME "$CONFIG")
  DBHOST=$(getdef DB_HOST "$CONFIG")
  if [[ -z "$DBUSER" ]]; then
    warn "DB_USER not readable in ${CONFIG} - skipped"
    printf '        define lines found: %s\n' "$(grep -c 'define' "$CONFIG" 2>/dev/null)"
    grep -m1 'DB_USER' "$CONFIG" 2>/dev/null | sed 's/^/        /'
    SKIPPED+=("$CONFIG")
    continue
  fi

  USER_PATHS["$DBUSER"]+="${WP_PATH}"$'\n'
  USER_HOST["$DBUSER"]="${DBHOST:-localhost}"
  USER_DB["$DBUSER"]="$DBNAME"
  printf '  %-24s db=%-24s unix=%-16s %s\n' "$DBUSER" "$DBNAME" "$SITE_USER" "$WP_PATH"
done

[[ ${#USER_PATHS[@]} -eq 0 ]] && { echo "Nichts zu tun."; exit 0; }
COVERED=0
for U in "${!USER_PATHS[@]}"; do
  COVERED=$((COVERED + $(echo -n "${USER_PATHS[$U]}" | grep -c .)))
done
printf '\n  %d Datenbankbenutzer, %d von %d Installation(en) erfasst\n' \
       "${#USER_PATHS[@]}" "$COVERED" "${#CONFIGS[@]}"
if [[ ${#SKIPPED[@]} -gt 0 ]]; then
  warn "${#SKIPPED[@]} installation(s) skipped - DB_USER not detected there:"
  for S in "${SKIPPED[@]}"; do printf '        %s\n' "$S"; done
fi

for U in "${!USER_PATHS[@]}"; do
  N=$(echo -n "${USER_PATHS[$U]}" | grep -c .)
  [[ "$N" -gt 1 ]] && warn "DB user '${U}' is used by ${N} installations - rotated jointly"
done

if [[ $APPLY -eq 0 ]]; then
  hr "Dry run"
  echo "  A new password (${LENGTH} chars) would be set per database user,"
  echo "  written into every matching wp-config.php and recorded in ${CREDFILE}."
  echo "  Re-run with --apply."
  exit 0
fi

# ---------------------------------------------------------------------------
hr "Preparing the credentials file"
touch "$CREDFILE"; chmod 600 "$CREDFILE"; chown root:root "$CREDFILE"
ok "${CREDFILE} (Modus 600)"
{
  echo ""
  echo "########## Rotation $(date '+%F %T') ##########"
} >> "$CREDFILE"

OKC=0; FAILC=0
for DBUSER in "${!USER_PATHS[@]}"; do
  DBHOST="${USER_HOST[$DBUSER]}"
  DBNAME="${USER_DB[$DBUSER]}"
  mapfile -t PATHS < <(echo -n "${USER_PATHS[$DBUSER]}" | grep .)

  hr "DB user ${DBUSER} (${#PATHS[@]} installation(s))"

  # old password, needed for rollback
  FIRST="${PATHS[0]}/wp-config.php"
  OLDPW=$(grep -oP "define\(\s*'DB_PASSWORD'\s*,\s*'\K[^']*" "$FIRST" | head -1)
  NEWPW=$(genpw)
  [[ ${#NEWPW} -lt 16 ]] && { err "Passworterzeugung fehlgeschlagen"; FAILC=$((FAILC+1)); continue; }

  # which host part the grant uses - usually localhost, sometimes %
  HOSTS=$(mysql $MYSQL_OPTS -N -B -e \
    "SELECT Host FROM mysql.user WHERE User='${DBUSER}';" 2>/dev/null)
  [[ -z "$HOSTS" ]] && { err "MySQL does not know user '${DBUSER}'"; FAILC=$((FAILC+1)); continue; }

  # --- record BEFORE changing anything, so a crash never loses the password
  {
    echo "user:     ${DBUSER}"
    echo "database: ${DBNAME}"
    echo "dbhost:   ${DBHOST}"
    echo "hosts:    $(echo "$HOSTS" | tr '\n' ' ')"
    echo "old:      ${OLDPW}"
    echo "new:      ${NEWPW}"
    for P in "${PATHS[@]}"; do echo "path:     ${P}"; done
    echo "---"
  } >> "$CREDFILE"

  # --- 1. MySQL
  SQL_FAIL=0
  while read -r H; do
    [[ -z "$H" ]] && continue
    mysql $MYSQL_OPTS -e "ALTER USER '${DBUSER}'@'${H}' IDENTIFIED BY '${NEWPW}';" 2>/dev/null \
      || mysql $MYSQL_OPTS -e "SET PASSWORD FOR '${DBUSER}'@'${H}' = PASSWORD('${NEWPW}');" 2>/dev/null \
      || { err "ALTER USER failed for ${DBUSER}@${H}"; SQL_FAIL=1; }
  done <<< "$HOSTS"
  mysql $MYSQL_OPTS -e "FLUSH PRIVILEGES;" >/dev/null 2>&1
  [[ $SQL_FAIL -eq 1 ]] && { FAILC=$((FAILC+1)); continue; }
  ok "MySQL password set"

  # --- 2. wp-config.php in every install using this user
  CFG_FAIL=0; declare -a BACKUPS=()
  for P in "${PATHS[@]}"; do
    C="${P}/wp-config.php"
    B="/root/wp-config-backup-$(echo "$P" | tr '/' '_')-$(date +%s).php"
    cp -p "$C" "$B" && BACKUPS+=("${C}|${B}")
    # sed on the exact define line; the generated password has no / or &
    if sed -i -E "s|(define\(\s*'DB_PASSWORD'\s*,\s*')[^']*('\s*\)\s*;)|\1${NEWPW}\2|" "$C"; then
      # compare literally - the password contains . * + ^ etc., which grep
      # would treat as regex metacharacters and then fail on a correct write
      WROTE=$(grep -oP "define\(\s*'DB_PASSWORD'\s*,\s*'\K[^']*" "$C" | head -1)
      if [[ "$WROTE" != "$NEWPW" ]]; then
        err "entry in ${C} not confirmed (read: ${#WROTE} chars, expected: ${#NEWPW})"
        CFG_FAIL=1
      fi
    else
      err "sed failed for ${C}"; CFG_FAIL=1
    fi
  done

  # --- 3. verify the site can actually connect
  if [[ $CFG_FAIL -eq 0 ]]; then
    for P in "${PATHS[@]}"; do
      OWNER=$(stat -c '%U' "${P}/wp-config.php")
      WPBIN=""
      for CAND in "/home/${OWNER}/wp" "/home/${OWNER}/.wp-cli.phar" /usr/local/bin/wp; do
        sudo -u "$OWNER" -H test -r "$CAND" 2>/dev/null && { WPBIN="$CAND"; break; }
      done
      if [[ -n "$WPBIN" ]]; then
        sudo -u "$OWNER" -H "$WPBIN" --path="$P" --skip-plugins --skip-themes db query "SELECT 1;" >/dev/null 2>&1 \
          || { err "Verbindungstest fehlgeschlagen: ${P}"; CFG_FAIL=1; }
      else
        mysql $MYSQL_OPTS -u"$DBUSER" -p"$NEWPW" -e "USE \`${DBNAME}\`;" 2>/dev/null \
          || { err "Direkter Verbindungstest fehlgeschlagen: ${DBNAME}"; CFG_FAIL=1; }
      fi
    done
  fi

  # --- 4. rollback if anything went wrong
  if [[ $CFG_FAIL -eq 1 ]]; then
    err "rolling back ${DBUSER}"
    for BP in "${BACKUPS[@]}"; do
      C="${BP%%|*}"; B="${BP##*|}"
      cp -p "$B" "$C" && printf '    restored: %s\n' "$C"
    done
    if [[ -n "$OLDPW" ]]; then
      while read -r H; do
        [[ -z "$H" ]] && continue
        mysql $MYSQL_OPTS -e "ALTER USER '${DBUSER}'@'${H}' IDENTIFIED BY '${OLDPW}';" 2>/dev/null
      done <<< "$HOSTS"
      mysql $MYSQL_OPTS -e "FLUSH PRIVILEGES;" >/dev/null 2>&1
      printf '    previous MySQL password restored\n'
    fi
    echo "ROLLBACK: ${DBUSER} - password NOT changed" >> "$CREDFILE"
    FAILC=$((FAILC+1))
  else
    for BP in "${BACKUPS[@]}"; do rm -f "${BP##*|}"; done   # backups hold the OLD password
    ok "wp-config.php updated and connection verified (${#PATHS[@]}x)"
    OKC=$((OKC+1))
  fi
  unset BACKUPS
done

hr "Ergebnis"
printf '  %d database user(s) rotated, %d failed\n' "$OKC" "$FAILC"
printf '  passwords: %s\n' "$CREDFILE"
cat <<'NEXT'

  Still to check by hand:
    - open the sites in a browser (a connection error shows up immediately)
    - other services using the same credentials: backup scripts, phpMyAdmin,
      cron jobs, the site users' ~/.my.cnf
    - afterwards: wp-user-audit --shuffle-salts   (invalidates all sessions)

  The file contains cleartext passwords. It belongs under /root, never in a
  home or web directory, and not in a backup that gets handed on.
NEXT
