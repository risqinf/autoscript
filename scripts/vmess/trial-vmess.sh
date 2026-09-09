#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: Create trial VMESS account
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
. /usr/local/sbin/lib/account.sh

require_root
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
ui_header "CREATE VMESS TRIAL ACCOUNT"
while true; do read -rp "Expired (60m/1h/1d): " duration; valid_duration "$duration" && break; err "Format: 60m, 1h, 1d."; done

user="trial$(gen_pass 6)"
uuid=$(gen_uuid)
secs=$(duration_to_seconds "$duration")
exp_epoch=$(( $(date +%s) + secs ))

if ! acc_xray_create "vmess" "$user" "$uuid" 10 2 "$exp_epoch"; then err "Failed to create trial."; exit 1; fi

exp_disp=$(date -d "@${exp_epoch}" +"%Y-%m-%d %H:%M:%S")
vmess_ws_tls=$(vmess_link 443 tls ws "/" "-WS-TLS")
vmess_ws_ntls=$(vmess_link 80 none ws "/" "-WS-NTLS")
vmess_hu_tls=$(vmess_link 443 tls httpupgrade "/vmess-hu" "-HU-TLS")
vmess_hu_ntls=$(vmess_link 80 none httpupgrade "/vmess-hu" "-HU-NTLS")
vmess_xhttp_tls=$(vmess_link 443 tls xhttp "/vmess-xhttp" "-XHTTP-TLS")
vmess_xhttp_ntls=$(vmess_link 80 none xhttp "/vmess-xhttp" "-XHTTP-NTLS")
vmess_grpc_tls=$(vmess_link 443 tls grpc "vmess-grpc" "-gRPC")

tg_send "$(xray_tg_text vmess "$user" "$uuid" "$domain" "10 GB" "2" "$exp_disp" "VMESS TRIAL ACCOUNT")"

clear
ui_header "VMESS TRIAL CREATED"
echo -e " Remarks      : ${user}"
echo -e " Host/IP      : ${domain}"
echo -e " UUID         : ${uuid}"
echo -e " Transports   : WS, HTTPUpgrade, XHTTP, gRPC"
echo -e " Quota        : 10 GB     Limit IP : 2"
echo -e " Expired      : ${exp_disp}"
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
