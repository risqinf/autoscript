#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: View VLESS account details
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
. /usr/local/sbin/lib/db.sh

db_init
domain=$(get_domain)

clear
ui_header "VLESS ACCOUNT DETAILS"
db_query "SELECT username, datetime(expired_at,'unixepoch','localtime')
          FROM accounts WHERE protocol='vless' AND status!='deleted'
          ORDER BY username;" \
  | while IFS='|' read -r u e; do printf " %-20s %s\n" "$u" "$e"; done
ui_rule

read -rp "Enter username: " user
if ! valid_username "$user" || ! db_account_exists "vless" "$user"; then
  err "User not found."; read -n1 -s -r -p "Press any key..."; menu; exit 1
fi

uuid=$(db_get_field "vless" "$user" "secret")
exp=$(db_query "SELECT datetime(expired_at,'unixepoch','localtime') FROM accounts WHERE protocol='vless' AND username='$(sql_escape "$user")' AND status!='deleted';")
ip=$(db_get_field "vless" "$user" "limit_ip"); [[ "$ip" == "0" ]] && ip="Unlimited"
qb=$(db_get_field "vless" "$user" "quota_bytes")
[[ "$qb" == "0" ]] && quota="Unlimited" || quota="$(( qb / 1073741824 )) GB"

vless_ws_tls="vless://${uuid}@${domain}:443?path=/vless&security=tls&encryption=none&type=ws&host=${domain}&sni=${domain}#${user}-WS-TLS"
vless_ws_ntls="vless://${uuid}@${domain}:80?path=/vless&encryption=none&type=ws&host=${domain}#${user}-WS-NTLS"
vless_hu_tls="vless://${uuid}@${domain}:443?path=/vless-hu&security=tls&encryption=none&type=httpupgrade&host=${domain}&sni=${domain}#${user}-HU-TLS"
vless_hu_ntls="vless://${uuid}@${domain}:80?path=/vless-hu&encryption=none&type=httpupgrade&host=${domain}#${user}-HU-NTLS"
vless_xhttp_tls="vless://${uuid}@${domain}:443?mode=auto&path=/vless-xhttp&security=tls&encryption=none&type=xhttp&host=${domain}&sni=${domain}#${user}-XHTTP-TLS"
vless_xhttp_ntls="vless://${uuid}@${domain}:80?mode=auto&path=/vless-xhttp&security=none&encryption=none&type=xhttp&host=${domain}#${user}-XHTTP-NTLS"
vless_grpc_tls="vless://${uuid}@${domain}:443?serviceName=vless-grpc&security=tls&encryption=none&type=grpc&sni=${domain}#${user}-gRPC"

clear
ui_header "VLESS ACCOUNT DETAILS"
echo -e " Remarks      : ${user}"
echo -e " Host/IP      : ${domain}"
echo -e " Port TLS     : 443      Port HTTP : 80"
echo -e " UUID         : ${uuid}"
echo -e " Transports   : WS, HTTPUpgrade, XHTTP, gRPC"
echo -e " Quota        : ${quota}     Limit IP : ${ip}"
echo -e " Expired      : ${exp}"
ui_rule
echo -e " ${WHITE}── Link WebSocket ──${NC}"
echo -e " TLS  : ${vless_ws_tls}"
echo -e " NTLS : ${vless_ws_ntls}"
ui_rule
echo -e " ${WHITE}── Link HTTPUpgrade ──${NC}"
echo -e " TLS  : ${vless_hu_tls}"
echo -e " NTLS : ${vless_hu_ntls}"
ui_rule
echo -e " ${WHITE}── Link XHTTP (SplitHTTP) ──${NC}"
echo -e " TLS  : ${vless_xhttp_tls}"
echo -e " NTLS : ${vless_xhttp_ntls}"
ui_rule
echo -e " ${WHITE}── Link gRPC ──${NC}"
echo -e " TLS  : ${vless_grpc_tls}"
ui_rule
read -n 1 -s -r -p " Press any key to back to menu..."
menu
