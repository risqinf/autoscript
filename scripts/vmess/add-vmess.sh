#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: Create VMESS account (SQLite + pure-JSON config)
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
ui_header "ADD VMESS ACCOUNT"

while true; do
  read -rp "Username       : " user
  if ! valid_username "$user"; then err "Username 3-32 chars: letters, numbers, underscore."; continue; fi
  if db_account_exists "vmess" "$user" || cfg_client_exists "$user"; then err "Username '$user' already exists."; continue; fi
  break
done

read -rp "Custom UUID    : (Enter to auto) " uuid
if [[ -z "$uuid" ]]; then uuid=$(gen_uuid)
elif ! valid_uuid "$uuid"; then err "Invalid UUID format."; exit 1; fi

while true; do read -rp "Quota (GB,0=unl): " quota; valid_number "$quota" && break; err "Number only."; done
while true; do read -rp "Limit IP (0=unl): " iplimit; valid_number "$iplimit" && break; err "Number only."; done
while true; do read -rp "Expired (30m/2h/1d): " duration; valid_duration "$duration" && break; err "Format: 30m, 2h, 1d."; done

secs=$(duration_to_seconds "$duration")
exp_epoch=$(( $(date +%s) + secs ))

if ! acc_xray_create "vmess" "$user" "$uuid" "$quota" "$iplimit" "$exp_epoch"; then
  err "Failed to create account."; exit 1
fi

exp_disp=$(date -d "@${exp_epoch}" +"%Y-%m-%d %H:%M:%S")
[[ "$quota" == "0" ]] && quota_disp="Unlimited" || quota_disp="${quota} GB"
[[ "$iplimit" == "0" ]] && ip_disp="Unlimited" || ip_disp="$iplimit"

vmess_ws_tls=$(vmess_link 443 tls ws "/" "-WS-TLS")
vmess_ws_ntls=$(vmess_link 80 none ws "/" "-WS-NTLS")
vmess_hu_tls=$(vmess_link 443 tls httpupgrade "/vmess-hu" "-HU-TLS")
vmess_hu_ntls=$(vmess_link 80 none httpupgrade "/vmess-hu" "-HU-NTLS")
vmess_xhttp_tls=$(vmess_link 443 tls xhttp "/vmess-xhttp" "-XHTTP-TLS")
vmess_xhttp_ntls=$(vmess_link 80 none xhttp "/vmess-xhttp" "-XHTTP-NTLS")
vmess_grpc_tls=$(vmess_link 443 tls grpc "vmess-grpc" "-gRPC")

# Telegram (HTML, properly escaped + delivery-checked via tg_send)
tg_send "$(xray_tg_text vmess "$user" "$uuid" "$domain" "$quota_disp" "$ip_disp" "$exp_disp")"

clear
ui_header "VMESS ACCOUNT CREATED"
echo -e " Remarks      : ${user}"
echo -e " Host/IP      : ${domain}"
echo -e " Port TLS     : 443"
echo -e " Port HTTP    : 80"
echo -e " UUID         : ${uuid}"
echo -e " AlterId      : 0"
echo -e " Transports   : WS, HTTPUpgrade, XHTTP, gRPC"
echo -e " Quota        : ${quota_disp}"
echo -e " Limit IP     : ${ip_disp}"
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
