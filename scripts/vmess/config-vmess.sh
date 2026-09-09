#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: View VMESS account details
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
. /usr/local/sbin/lib/db.sh

db_init
domain=$(get_domain)

vmess_link() {
  local port="$1" tls="$2" net="${3:-ws}" path="${4:-/}" tag="${5:-}"
  local ps="${user}${tag}"
  jq -nc --arg ps "$ps" --arg add "$domain" --arg port "$port" \
        --arg id "$uuid" --arg host "$domain" --arg tls "$tls" \
        --arg net "$net" --arg path "$path" \
        '{v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:"0",net:$net,path:$path,type:"none",host:$host,tls:$tls,sni:$add}' \
    | base64 -w 0 | sed 's/^/vmess:\/\//'
}

clear
ui_header "VMESS ACCOUNT DETAILS"
db_query "SELECT username, datetime(expired_at,'unixepoch','localtime')
          FROM accounts WHERE protocol='vmess' AND status!='deleted'
          ORDER BY username;" \
  | while IFS='|' read -r u e; do printf " %-20s %s\n" "$u" "$e"; done
ui_rule

read -rp "Enter username: " user
if ! valid_username "$user" || ! db_account_exists "vmess" "$user"; then
  err "User not found."; read -n1 -s -r -p "Press any key..."; menu; exit 1
fi

uuid=$(db_get_field "vmess" "$user" "secret")
exp=$(db_query "SELECT datetime(expired_at,'unixepoch','localtime') FROM accounts WHERE protocol='vmess' AND username='$(sql_escape "$user")' AND status!='deleted';")
ip=$(db_get_field "vmess" "$user" "limit_ip"); [[ "$ip" == "0" ]] && ip="Unlimited"
qb=$(db_get_field "vmess" "$user" "quota_bytes")
[[ "$qb" == "0" ]] && quota="Unlimited" || quota="$(( qb / 1073741824 )) GB"

vmess_ws_tls=$(vmess_link 443 tls ws "/" "-WS-TLS")
vmess_ws_ntls=$(vmess_link 80 none ws "/" "-WS-NTLS")
vmess_hu_tls=$(vmess_link 443 tls httpupgrade "/vmess-hu" "-HU-TLS")
vmess_hu_ntls=$(vmess_link 80 none httpupgrade "/vmess-hu" "-HU-NTLS")
vmess_xhttp_tls=$(vmess_link 443 tls xhttp "/vmess-xhttp" "-XHTTP-TLS")
vmess_xhttp_ntls=$(vmess_link 80 none xhttp "/vmess-xhttp" "-XHTTP-NTLS")
vmess_grpc_tls=$(vmess_link 443 tls grpc "vmess-grpc" "-gRPC")

clear
ui_header "VMESS ACCOUNT DETAILS"
echo -e " Remarks      : ${user}"
echo -e " Host/IP      : ${domain}"
echo -e " Port TLS     : 443      Port HTTP : 80"
echo -e " UUID         : ${uuid}"
echo -e " AlterId      : 0"
echo -e " Transports   : WS, HTTPUpgrade, XHTTP, gRPC"
echo -e " Quota        : ${quota}     Limit IP : ${ip}"
echo -e " Expired      : ${exp}"
ui_rule
echo -e " ${WHITE}── Link WebSocket ──${NC}"
echo -e " TLS  : ${vmess_ws_tls}"
echo -e " NTLS : ${vmess_ws_ntls}"
ui_rule
echo -e " ${WHITE}── Link HTTPUpgrade ──${NC}"
echo -e " TLS  : ${vmess_hu_tls}"
echo -e " NTLS : ${vmess_hu_ntls}"
ui_rule
echo -e " ${WHITE}── Link XHTTP (SplitHTTP) ──${NC}"
echo -e " TLS  : ${vmess_xhttp_tls}"
echo -e " NTLS : ${vmess_xhttp_ntls}"
ui_rule
echo -e " ${WHITE}── Link gRPC ──${NC}"
echo -e " TLS  : ${vmess_grpc_tls}"
ui_rule
read -n 1 -s -r -p " Press any key to back to menu..."
menu
