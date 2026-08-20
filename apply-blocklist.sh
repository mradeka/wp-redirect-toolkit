#!/usr/bin/env bash
#
# apply-blocklist.sh
#
# Part of wp-redirect-toolkit 1.2.0
# https://github.com/mradeka/wp-redirect-toolkit
#
# Turns blocklist-domains.txt into blocking rules, or searches the
# WordPress installations for those domains.
#
# Output formats (print only, nothing applied - without --apply):
#   hosts      /etc/hosts lines
#   dnsmasq    address=/domain/0.0.0.0
#   unbound    local-zone entries
#   firewalld  rich rules for the currently resolved IPs
#   nftables   set definition for the currently resolved IPs
#   grep       search pattern for your own scripts
#
# Usage:
#   ./apply-blocklist.sh hosts
#   ./apply-blocklist.sh dnsmasq --apply       # writes /etc/dnsmasq.d/
#   ./apply-blocklist.sh hosts --apply         # appends to /etc/hosts
#   ./apply-blocklist.sh scan                  # searches /home/*/public_html
#
# IMPORTANT about IP-based rules (firewalld, nftables): the domains point at
# Cloudflare and shared hosting addresses that change and are shared with
# thousands of legitimate sites. An IP block therefore hits too much and only
# works briefly. DNS-based blocking is the right tool here.

set -uo pipefail

LIST="${LIST:-$(dirname "${BASH_SOURCE[0]}")/blocklist-domains.txt}"
MODE="${1:-}"
APPLY=0
[[ "${2:-}" == "--apply" ]] && APPLY=1

[[ -z "$MODE" || "$MODE" == "-h" || "$MODE" == "--help" ]] && { sed -n '2,28p' "$0"; exit 0; }
[[ -f "$LIST" ]] || { echo "List not found: ${LIST}"; exit 1; }

mapfile -t DOMAINS < <(grep -vE '^\s*#|^\s*$' "$LIST" | tr -d ' \t')
[[ ${#DOMAINS[@]} -eq 0 ]] && { echo "No domains in ${LIST}"; exit 1; }
echo "# ${#DOMAINS[@]} domains from ${LIST}" >&2

case "$MODE" in

  hosts)
    OUT=$(for D in "${DOMAINS[@]}"; do printf '0.0.0.0 %s\n0.0.0.0 www.%s\n' "$D" "$D"; done)
    if [[ $APPLY -eq 1 ]]; then
      [[ $EUID -ne 0 ]] && { echo "--apply requires root."; exit 1; }
      cp -p /etc/hosts "/etc/hosts.bak-$(date +%F-%H%M%S)"
      grep -q '# BEGIN ushort-blocklist' /etc/hosts \
        && sed -i '/# BEGIN ushort-blocklist/,/# END ushort-blocklist/d' /etc/hosts
      { echo "# BEGIN ushort-blocklist"; echo "$OUT"; echo "# END ushort-blocklist"; } >> /etc/hosts
      echo "Added to /etc/hosts (backup created)." >&2
    else
      echo "$OUT"
    fi
    ;;

  dnsmasq)
    OUT=$(for D in "${DOMAINS[@]}"; do printf 'address=/%s/0.0.0.0\n' "$D"; done)
    if [[ $APPLY -eq 1 ]]; then
      [[ $EUID -ne 0 ]] && { echo "--apply requires root."; exit 1; }
      [[ -d /etc/dnsmasq.d ]] || { echo "/etc/dnsmasq.d missing - is dnsmasq installed?"; exit 1; }
      echo "$OUT" > /etc/dnsmasq.d/blocklist-ushort.conf
      echo "Written: /etc/dnsmasq.d/blocklist-ushort.conf" >&2
      dnsmasq --test && echo "Config ok - now run: systemctl reload dnsmasq" >&2
    else
      echo "$OUT"
    fi
    ;;

  unbound)
    for D in "${DOMAINS[@]}"; do
      printf 'local-zone: "%s." refuse\n' "$D"
    done
    [[ $APPLY -eq 1 ]] && echo "# unbound: copy output to /etc/unbound/unbound.conf.d/, then unbound-checkconf" >&2
    ;;

  firewalld|nftables)
    echo "# Note: IP blocks also hit shared hosting addresses." >&2
    echo "# Addresses resolved at $(date '+%F %T'):" >&2
    IPS=()
    for D in "${DOMAINS[@]}"; do
      while read -r IP; do
        [[ -n "$IP" ]] && IPS+=("$IP") && printf '#   %-20s %s\n' "$D" "$IP" >&2
      done < <(getent ahostsv4 "$D" 2>/dev/null | awk '{print $1}' | sort -u)
    done
    mapfile -t IPS < <(printf '%s\n' "${IPS[@]:-}" | grep -E '^[0-9]' | sort -u)
    [[ ${#IPS[@]} -eq 0 ]] && { echo "# no addresses resolvable - domains are probably already offline" >&2; exit 0; }
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
    echo "Searching /home/*/public_html for ${#DOMAINS[@]} domains ..." >&2
    HITS=0
    while read -r F; do
      printf '\033[31m[HIT]\033[0m %s\n' "$F"; HITS=$((HITS+1))
    done < <(grep -rlE "$PAT" /home/*/public_html 2>/dev/null | head -50)
    echo >&2
    if [[ $HITS -eq 0 ]]; then
      echo "No file hits." >&2
    else
      echo "${HITS} file(s) with hits - inspect the content, do not delete blindly." >&2
    fi
    echo "Check the databases separately with wp-db-audit." >&2
    ;;

  *)
    echo "Unknown mode: ${MODE}"; sed -n '2,28p' "$0"; exit 1 ;;
esac
