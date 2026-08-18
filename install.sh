#!/usr/bin/env bash
#
# install.sh - installs the wp-redirect-toolkit into /usr/local/bin
#
# Usage:  sudo ./install.sh  [--prefix /usr/local/bin]  [--uninstall]

set -uo pipefail

PREFIX="/usr/local/bin"
UNINSTALL=0
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)    PREFIX="$2"; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help)   sed -n '2,7p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

[[ $EUID -ne 0 ]] && { echo "Run as root."; exit 1; }

# name:mode - the password rotator is 700, it writes cleartext credentials
SCRIPTS=(
  "wp-db-audit:755"
  "wp-cron-list:755"
  "wp-user-audit:755"
  "wp-redirect-cleanup:755"
  "wp-cleanup-all:755"
  "wp-move-to-subdir:755"
  "check-usrlocalbin-access:755"
  "wp-asset-scan:755"
  "apply-blocklist:755"
  "wp-harden-htaccess:755"
  "wp-fix-ownership:755"
  "wp-rotate-db-passwords:700"
)

if [[ $UNINSTALL -eq 1 ]]; then
  for E in "${SCRIPTS[@]}"; do
    N="${E%%:*}"
    rm -f "${PREFIX}/${N}" && echo "  removed: ${PREFIX}/${N}"
  done
  echo "Done. /root/wp-db-credentials.txt and /root/wp-cleanup-logs are kept."
  exit 0
fi

# Vorgaengername aufraeumen: wp-cron-audit wurde zu wp-db-audit, sonst liegen
# beide parallel und der alte laeuft weiter.
if [[ -e "${PREFIX}/wp-cron-audit" ]]; then
  rm -f "${PREFIX}/wp-cron-audit" && echo "  removed: ${PREFIX}/wp-cron-audit (now named wp-db-audit)"
fi

echo "== Installing to ${PREFIX} =="
FAIL=0
mkdir -p "$PREFIX" || { echo "Cannot create target directory ${PREFIX}."; exit 1; }
for E in "${SCRIPTS[@]}"; do
  N="${E%%:*}"; M="${E##*:}"
  F="${SRC}/${N}.sh"
  if [[ ! -f "$F" ]]; then
    printf '  \033[31mmissing: %s\033[0m\n' "${N}.sh"; FAIL=1; continue
  fi
  if ! bash -n "$F" 2>/dev/null; then
    printf '  \033[31msyntax error: %s - not installed\033[0m\n' "${N}.sh"; FAIL=1; continue
  fi
  install -m "$M" "$F" "${PREFIX}/${N}" \
    && printf '  \033[32mok\033[0m  %-26s (Modus %s)\n' "${PREFIX}/${N}" "$M"
done

echo
if [[ -f "${SRC}/blocklist-domains.txt" ]]; then
  install -d -m 755 /usr/local/share/wp-redirect-toolkit
  install -m 644 "${SRC}/blocklist-domains.txt" /usr/local/share/wp-redirect-toolkit/
  printf '  \033[32mok\033[0m  %-26s\n' "/usr/local/share/wp-redirect-toolkit/blocklist-domains.txt"
  echo "        apply-blocklist findet sie ueber: LIST=/usr/local/share/wp-redirect-toolkit/blocklist-domains.txt"
fi

echo "== Prerequisites =="
check() { command -v "$1" >/dev/null 2>&1 && printf '  \033[32mok\033[0m  %-10s %s\n' "$1" "$(command -v "$1")" \
                                          || { printf '  \033[31mmissing\033[0m %s\n' "$1"; FAIL=1; }; }
check bash; check php; check mysql; check curl; check sudo

if command -v wp >/dev/null 2>&1; then
  V=$(wp --version --allow-root 2>/dev/null | awk '{print $2}')
  case "$V" in
    2.[0-6].*|1.*) printf '  \033[33mwarn\033[0m WP-CLI %s ist zu alt - 2.7+ empfohlen\033[0m\n' "$V" ;;
    "")            printf '  \033[33mwarn\033[0m WP-CLI version not determinable\n' ;;
    *)             printf '  \033[32mok\033[0m  WP-CLI    %s\n' "$V" ;;
  esac
else
  printf '  \033[31mfehlt\033[0m WP-CLI\n'
  echo "        curl -fL -o /tmp/wp-cli.phar https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar"
  echo "        install -m 755 /tmp/wp-cli.phar /usr/local/bin/wp"
  FAIL=1
fi

BV="${BASH_VERSINFO[0]}"
[[ "$BV" -lt 4 ]] && { printf '  \033[31mmissing\033[0m Bash 4+ (found: %s)\n' "$BV"; FAIL=1; }

echo
if [[ $FAIL -eq 0 ]]; then
  cat <<'NEXT'
Installation vollstaendig. Empfohlener Einstieg:

  check-usrlocalbin-access     # koennen alle Konten die Werkzeuge nutzen?
  wp-db-audit                # Bestandsaufnahme, aendert nichts
  wp-cleanup-all               # Trockenlauf ueber alle Seiten

Alles Weitere in README.md, der Vorfallshergang in INCIDENT.md.
NEXT
else
  echo "Installed with limitations - see messages above."
fi
