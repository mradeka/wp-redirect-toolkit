#!/usr/bin/env bash
#
# check-usrlocalbin-access.sh
#
# For every user that owns a WordPress install (or every /home/* account with
# --all), checks whether /usr/local/bin and the tools in it are actually
# usable under that account:
#
#   dir    - is /usr/local/bin traversable and readable for the user
#   exec   - can the user execute the binary at all
#   run    - does it actually produce output (open_basedir, PATH, PHP)
#   PATH   - is /usr/local/bin in the account's login PATH
#   jail   - is the account chrooted (jailkit): then a login shell sees a
#            different filesystem and /usr/local/bin may not exist inside it,
#            even though `sudo -u` works fine
#
# Read-only. Usage:
#   ./check-usrlocalbin-access.sh            # users owning a WP install
#   ./check-usrlocalbin-access.sh --all      # every /home/* account
#   ./check-usrlocalbin-access.sh --bin wp   # test a specific tool (default: wp)

set -uo pipefail

BIN="wp"
ALL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bin) BIN="$2"; shift 2 ;;
    --all) ALL=1; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done
[[ $EUID -ne 0 ]] && { echo "Run as root."; exit 1; }

TARGET="/usr/local/bin/${BIN}"
PROBLEMS=0

echo "== /usr/local/bin =="
stat -c '  %A %U:%G  %n' /usr/local/bin
[[ -e "$TARGET" ]] && stat -c '  %A %U:%G  %n' "$TARGET" || echo "  ${TARGET} existiert nicht"
PERM=$(stat -c '%A' /usr/local/bin)
# character 10 of drwxr-xr-x is the "other" execute bit - a glob like *x*x*x*
# matches the owner/group bits too and would pass on drwxrwx---
[[ "${PERM:9:1}" == "x" ]] || echo "  ACHTUNG: /usr/local/bin ist nicht fuer alle durchsuchbar (${PERM})"
if [[ -e "$TARGET" ]]; then
  TPERM=$(stat -c '%A' "$TARGET")
  [[ "${TPERM:9:1}" == "x" ]] || echo "  ACHTUNG: ${TARGET} ist nicht fuer alle ausfuehrbar (${TPERM})"
fi
echo

if [[ $ALL -eq 1 ]]; then
  mapfile -t USERS < <(awk -F: '$6 ~ /^\/home\// && $3>=1000 {print $1}' /etc/passwd | sort -u)
else
  mapfile -t USERS < <(find /home -maxdepth 4 -name wp-config.php \
                       -exec stat -c '%U' {} + 2>/dev/null | sort -u)
fi
if [[ ${#USERS[@]} -eq 0 ]]; then
  echo "Keine Benutzer mit WordPress-Installation gefunden (mit --all alle /home-Konten pruefen)."
fi

echo
echo "== Toolkit-Skripte =="
# Two classes: some scripts are meant to run AS the site user, the rest check
# for root themselves and would refuse anyway. Testing them all as a site user
# would produce false alarms, so they are checked separately.
USER_SCRIPTS=(wp-redirect-cleanup)
ROOT_SCRIPTS=(wp-cleanup-all wp-db-audit wp-cron-list wp-user-audit wp-rotate-db-passwords wp-move-to-subdir)

for S in "${ROOT_SCRIPTS[@]}"; do
  P="/usr/local/bin/${S}"
  if [[ ! -e "$P" ]]; then
    printf '  %-24s \033[33mnicht installiert\033[0m\n' "$S"
  elif [[ ! -x "$P" ]]; then
    printf '  %-24s \033[31mnicht ausfuehrbar (%s)\033[0m\n' "$S" "$(stat -c '%A' "$P")"
    PROBLEMS=$((PROBLEMS+1))
  elif ! bash -n "$P" 2>/dev/null; then
    printf '  %-24s \033[31mSyntaxfehler\033[0m\n' "$S"
    PROBLEMS=$((PROBLEMS+1))
  else
    printf '  %-24s ok (nur root)\n' "$S"
  fi
done
for S in "${USER_SCRIPTS[@]}"; do
  P="/usr/local/bin/${S}"
  [[ -e "$P" ]] && printf '  %-24s ok (als Seitenbenutzer aufrufbar - siehe Tabelle unten)\n' "$S" \
                || printf '  %-24s \033[33mnicht installiert\033[0m\n' "$S"
done

echo
printf '%-18s %-6s %-6s %-6s %-20s %-6s %-22s %s\n' \
       "user" "dir" "exec" "run" "wp-version" "jail" "cleanup-skript" "PATH"
printf '%s\n' "---------------------------------------------------------------------------------------------------------------------------"

for U in "${USERS[@]}"; do
  SHELL_U=$(getent passwd "$U" | cut -d: -f7)
  JAIL="nein"; [[ "$SHELL_U" == *jk_chrootsh* ]] && JAIL="JA"

  sudo -u "$U" -H test -x /usr/local/bin 2>/dev/null && DIR="ok" || DIR="NEIN"
  sudo -u "$U" -H test -x "$TARGET"      2>/dev/null && EXE="ok" || EXE="NEIN"

  OUT=$(sudo -u "$U" -H "$TARGET" --version 2>&1 | head -1)
  if [[ -n "$OUT" && "$OUT" != *"Permission denied"* && "$OUT" != *"not found"* && "$OUT" != *"Could not open"* ]]; then
    RUN="ok"; INFO="${OUT:0:22}"
  else
    RUN="NEIN"; INFO="${OUT:0:22}"
  fi

  # login PATH as the account would see it
  UPATH=$(sudo -u "$U" -H bash -lc 'echo $PATH' 2>/dev/null)
  case "$UPATH" in
    *"/usr/local/bin"*) INPATH="ja" ;;
    "")                 INPATH="? (kein Login-Shell-Test moeglich)" ;;
    *)                  INPATH="NEIN" ;;
  esac

  # Functional test of the script the site user actually has to run. --help
  # exits non-zero by design, so judge it by the output, not the exit code.
  CLEAN="/usr/local/bin/wp-redirect-cleanup"
  if [[ ! -e "$CLEAN" ]]; then
    SCR="nicht installiert"
  elif ! sudo -u "$U" -H test -x "$CLEAN" 2>/dev/null; then
    SCR="NEIN (nicht ausfuehrbar)"
  else
    HELP=$(sudo -u "$U" -H "$CLEAN" --help 2>&1 | head -40)
    if echo "$HELP" | grep -qi 'usage'; then
      SCR="ok"
    else
      SCR="NEIN ($(echo "$HELP" | head -1 | cut -c1-16))"
    fi
  fi

  [[ "$DIR" == "NEIN" || "$EXE" == "NEIN" || "$RUN" == "NEIN" || "$INPATH" == "NEIN" || "$SCR" == NEIN* ]] && PROBLEMS=$((PROBLEMS+1))

  printf '%-18s %-6s %-6s %-6s %-20s %-6s %-22s %s\n' \
         "$U" "$DIR" "$EXE" "$RUN" "${INFO:0:20}" "$JAIL" "$SCR" "$INPATH"
done

echo
if [[ $PROBLEMS -eq 0 ]]; then
  echo "Alle geprueften Konten koennen ${TARGET} nutzen."
else
  cat <<HINT
${PROBLEMS} Konto/Konten mit Einschraenkungen. Uebliche Ursachen und Abhilfe:

  dir/exec = NEIN
      chmod 755 /usr/local/bin ; chmod 755 ${TARGET}

  run = NEIN, aber exec = ok
      "Could not open input file" -> open_basedir in der PHP-CLI-Konfiguration:
        sudo -u USER php -i | grep open_basedir
      Abhilfe: Kopie ins Home des Benutzers legen und per --wp-bin nutzen:
        install -m 755 -o USER -g USER ${TARGET} /home/USER/${BIN}

  jail = JA
      Der Account ist chrootet. 'sudo -u' laeuft ausserhalb des Kaefigs und
      funktioniert, ein SSH-Login des Benutzers sieht /usr/local/bin aber
      nicht. Dann gehoert das Werkzeug in den Jail oder ins Home.

  PATH = NEIN
      /usr/local/bin fehlt in der Login-PATH des Kontos. Entweder immer den
      vollen Pfad angeben, oder in /etc/profile.d/ ergaenzen.

  cleanup-skript = NEIN
      Das Skript liegt an einer Stelle, die der Benutzer nicht betreten darf
      (etwa /root, Modus 700). Richtig ist:
        install -m 755 /root/wp-redirect-cleanup.sh /usr/local/bin/wp-redirect-cleanup
      Bei "nicht ausfuehrbar": chmod 755 /usr/local/bin/wp-redirect-cleanup
HINT
fi
