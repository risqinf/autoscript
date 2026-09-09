#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: View Trojan account details
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
. /usr/local/sbin/lib/db.sh

db_init
domain=$(get_domain)

clear
ui_header "TROJAN ACCOUNT DETAILS"
db_query "SELECT username, datetime(expired_at,'unixepoch','localtime')
          FROM accounts WHERE protocol='trojan' AND status!='deleted'
          ORDER BY username;" \
  | while IFS='|' read -r u e; do printf " %-20s %s\n" "$u" "$e"; done
ui_rule

read -rp "Enter username: " user
if ! valid_username "$user" || ! db_account_exists "trojan" "$user"; then
  err "User not found."; read -n1 -s -r -p "Press any key..."; menu; exit 1
fi

secret=$(db_get_field "trojan" "$user" "secret")
exp=$(db_query "SELECT datetime(expired_at,'unixepoch','localtime') FROM accounts WHERE protocol='trojan' AND username='$(sql_escape "$user")' AND status!='deleted';")
ip=$(db_get_field "trojan" "$user" "limit_ip"); [[ "$ip" == "0" ]] && ip="Unlimited"
qb=$(db_get_field "trojan" "$user" "quota_bytes")
[[ "$qb" == "0" ]] && quota="Unlimited" || quota="$(( qb / 1073741824 )) GB"

trojan_ws_tls="trojan://${secret}@${domain}:443?type=ws&security=tls&host=${domain}&path=/trojan&sni=${domain}#${user}-WS-TLS"
trojan_hu_tls="trojan://${secret}@${domain}:443?type=httpupgrade&security=tls&host=${domain}&path=/trojan-hu&sni=${domain}#${user}-HU-TLS"
trojan_xhttp_tls="trojan://${secret}@${domain}:443?type=xhttp&security=tls&host=${domain}&path=/trojan-xhttp&mode=auto&sni=${domain}#${user}-XHTTP-TLS"
trojan_grpc_tls="trojan://${secret}@${domain}:443?type=grpc&security=tls&serviceName=trojan-grpc&sni=${domain}#${user}-gRPC"

clear
ui_header "TROJAN ACCOUNT DETAILS"
echo -e " Remarks      : ${user}"
echo -e " Host/IP      : ${domain}"
echo -e " Port TLS     : 443"
echo -e " Key/Password : ${secret}"
echo -e " Transports   : WS, HTTPUpgrade, XHTTP, gRPC"
echo -e " Quota        : ${quota}     Limit IP : ${ip}"
echo -e " Expired      : ${exp}"
ui_rule
echo -e " ${WHITE}── Link WebSocket (TLS) ──${NC}"
echo -e " ${trojan_ws_tls}"
ui_rule
echo -e " ${WHITE}── Link HTTPUpgrade (TLS) ──${NC}"
echo -e " ${trojan_hu_tls}"
ui_rule
echo -e " ${WHITE}── Link XHTTP / SplitHTTP (TLS) ──${NC}"
echo -e " ${trojan_xhttp_tls}"
ui_rule
echo -e " ${WHITE}── Link gRPC (TLS) ──${NC}"
echo -e " ${trojan_grpc_tls}"
ui_rule
read -n 1 -s -r -p " Press any key to back to menu..."
menu
