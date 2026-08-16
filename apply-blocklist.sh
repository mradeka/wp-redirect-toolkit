#!/usr/bin/env bash
#
# apply-blocklist.sh
#
# Wandelt blocklist-domains.txt in Sperrregeln um oder durchsucht die
# WordPress-Installationen nach den Domains.
#
# Ausgabeformate (nur ausgeben, nichts anwenden - ohne --apply):
#   hosts      /etc/hosts-Zeilen
#   dnsmasq    address=/domain/0.0.0.0
#   unbound    local-zone-Eintraege
#   firewalld  rich rules auf die aktuell aufgeloesten IPs
#   nftables   set-Definition auf die aktuell aufgeloesten IPs
#   grep       Suchmuster fuer eigene Skripte
#
# Usage:
#   ./apply-blocklist.sh hosts
#   ./apply-blocklist.sh dnsmasq --apply       # schreibt /etc/dnsmasq.d/
#   ./apply-blocklist.sh hosts --apply         # ergaenzt /etc/hosts
#   ./apply-blocklist.sh scan                  # durchsucht /home/*/public_html
#
# WICHTIG zu IP-basierten Regeln (firewalld, nftables): Die Domains zeigen auf
# Cloudflare- und Hosting-Adressen, die sich aendern und mit tausenden
# legitimen Seiten geteilt werden. Eine IP-Sperre trifft daher zu viel und
# wirkt nur kurz. DNS-basiertes Sperren ist hier das richtige Mittel.

set -uo pipefail

LIST="${LIST:-$(dirname "${BASH_SOURCE[0]}")/blocklist-domains.txt}"
MODE="${1:-}"
APPLY=0
[[ "${2:-}" == "--apply" ]] && APPLY=1

[[ -z "$MODE" || "$MODE" == "-h" || "$MODE" == "--help" ]] && { sed -n '2,28p' "$0"; exit 0; }
[[ -f "$LIST" ]] || { echo "Liste nicht gefunden: ${LIST}"; exit 1; }

mapfile -t DOMAINS < <(grep -vE '^\s*#|^\s*$' "$LIST" | tr -d ' \t')
[[ ${#DOMAINS[@]} -eq 0 ]] && { echo "Keine Domains in ${LIST}"; exit 1; }
echo "# ${#DOMAINS[@]} Domains aus ${LIST}" >&2

case "$MODE" in

  hosts)
    OUT=$(for D in "${DOMAINS[@]}"; do printf '0.0.0.0 %s\n0.0.0.0 www.%s\n' "$D" "$D"; done)
    if [[ $APPLY -eq 1 ]]; then
      [[ $EUID -ne 0 ]] && { echo "Fuer --apply root noetig."; exit 1; }
      cp -p /etc/hosts "/etc/hosts.bak-$(date +%F-%H%M%S)"
      grep -q '# BEGIN ushort-blocklist' /etc/hosts \
        && sed -i '/# BEGIN ushort-blocklist/,/# END ushort-blocklist/d' /etc/hosts
      { echo "# BEGIN ushort-blocklist"; echo "$OUT"; echo "# END ushort-blocklist"; } >> /etc/hosts
      echo "In /etc/hosts eingetragen (Sicherung angelegt)." >&2
    else
      echo "$OUT"
    fi
    ;;

  dnsmasq)
    OUT=$(for D in "${DOMAINS[@]}"; do printf 'address=/%s/0.0.0.0\n' "$D"; done)
    if [[ $APPLY -eq 1 ]]; then
      [[ $EUID -ne 0 ]] && { echo "Fuer --apply root noetig."; exit 1; }
      [[ -d /etc/dnsmasq.d ]] || { echo "/etc/dnsmasq.d fehlt - dnsmasq installiert?"; exit 1; }
      echo "$OUT" > /etc/dnsmasq.d/blocklist-ushort.conf
      echo "Geschrieben: /etc/dnsmasq.d/blocklist-ushort.conf" >&2
      dnsmasq --test && echo "Konfiguration ok - jetzt: systemctl reload dnsmasq" >&2
    else
      echo "$OUT"
    fi
    ;;

  unbound)
    for D in "${DOMAINS[@]}"; do
      printf 'local-zone: "%s." refuse\n' "$D"
    done
    [[ $APPLY -eq 1 ]] && echo "# unbound: Ausgabe nach /etc/unbound/unbound.conf.d/ kopieren, dann unbound-checkconf" >&2
    ;;

  firewalld|nftables)
    echo "# Achtung: IP-Sperren treffen geteilte Hosting-Adressen mit." >&2
    echo "# Aufgeloeste Adressen zum Zeitpunkt $(date '+%F %T'):" >&2
    IPS=()
    for D in "${DOMAINS[@]}"; do
      while read -r IP; do
        [[ -n "$IP" ]] && IPS+=("$IP") && printf '#   %-20s %s\n' "$D" "$IP" >&2
      done < <(getent ahostsv4 "$D" 2>/dev/null | awk '{print $1}' | sort -u)
    done
    mapfile -t IPS < <(printf '%s\n' "${IPS[@]:-}" | grep -E '^[0-9]' | sort -u)
    [[ ${#IPS[@]} -eq 0 ]] && { echo "# keine Adressen aufloesbar - Domains vermutlich bereits abgeschaltet" >&2; exit 0; }
    if [[ "$MODE" == "firewalld" ]]; then
      for IP in "${IPS[@]}"; do
        echo "firewall-cmd --permanent --add-rich-rule=\"rule family=ipv4 destination address=${IP} drop\""
      done
      echo "firewall-cmd --reload"
    else
      echo "table inet filter {"
      echo "  set ushort_blocklist {"
      echo "    type ipv4_addr"
      echo "    elements = { $(IFS=,; echo "${IPS[*]}") }"
      echo "  }"
      echo "  chain output {"
      echo "    type filter hook output priority 0;"
      echo "    ip daddr @ushort_blocklist drop"
      echo "  }"
      echo "}"
    fi
    ;;

  grep)
    printf '%s' "$(IFS='|'; echo "${DOMAINS[*]}")" | sed 's/\./\\./g'
    echo
    ;;

  scan)
    PAT=$(IFS='|'; echo "${DOMAINS[*]}" | sed 's/\./\\./g')
    echo "Durchsuche /home/*/public_html nach ${#DOMAINS[@]} Domains ..." >&2
    HITS=0
    while read -r F; do
      printf '\033[31m[TREFFER]\033[0m %s\n' "$F"; HITS=$((HITS+1))
    done < <(grep -rlE "$PAT" /home/*/public_html 2>/dev/null | head -50)
    echo >&2
    if [[ $HITS -eq 0 ]]; then
      echo "Keine Dateitreffer." >&2
    else
      echo "${HITS} Datei(en) mit Treffern - Inhalt pruefen, nicht blind loeschen." >&2
    fi
    echo "Datenbanken zusaetzlich mit wp-cron-audit pruefen." >&2
    ;;

  *)
    echo "Unbekannter Modus: ${MODE}"; sed -n '2,28p' "$0"; exit 1 ;;
esac
