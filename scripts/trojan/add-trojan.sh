#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: Create Trojan account (SQLite + pure-JSON config)
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
. /usr/local/sbin/lib/account.sh

require_root
db_init
domain=$(get_domain)

clear
ui_header "ADD TROJAN ACCOUNT"

while true; do
  read -rp "Username       : " user
  if ! valid_username "$user"; then err "Username 3-32 chars: letters, numbers, underscore."; continue; fi
  if db_account_exists "trojan" "$user" || cfg_client_exists "$user"; then err "Username '$user' already exists."; continue; fi
  break
done

read -rp "Custom Key     : (Enter to auto) " secret
if [[ -z "$secret" ]]; then secret=$(gen_uuid)
elif [[ "$secret" == *[$'\n\r\t ']* ]]; then err "Key must not contain whitespace."; exit 1; fi

while true; do read -rp "Quota (GB,0=unl): " quota; valid_number "$quota" && break; err "Number only."; done
while true; do read -rp "Limit IP (0=unl): " iplimit; valid_number "$iplimit" && break; err "Number only."; done
while true; do read -rp "Expired (30m/2h/1d): " duration; valid_duration "$duration" && break; err "Format: 30m, 2h, 1d."; done

secs=$(duration_to_seconds "$duration")
exp_epoch=$(( $(date +%s) + secs ))

if ! acc_xray_create "trojan" "$user" "$secret" "$quota" "$iplimit" "$exp_epoch"; then
  err "Failed to create account."; exit 1
fi

exp_disp=$(date -d "@${exp_epoch}" +"%Y-%m-%d %H:%M:%S")
[[ "$quota" == "0" ]] && quota_disp="Unlimited" || quota_disp="${quota} GB"
[[ "$iplimit" == "0" ]] && ip_disp="Unlimited" || ip_disp="$iplimit"

trojan_ws_tls="trojan://${secret}@${domain}:443?type=ws&security=tls&host=${domain}&path=/trojan&sni=${domain}#${user}-WS-TLS"
trojan_hu_tls="trojan://${secret}@${domain}:443?type=httpupgrade&security=tls&host=${domain}&path=/trojan-hu&sni=${domain}#${user}-HU-TLS"
trojan_xhttp_tls="trojan://${secret}@${domain}:443?type=xhttp&security=tls&host=${domain}&path=/trojan-xhttp&mode=auto&sni=${domain}#${user}-XHTTP-TLS"
trojan_grpc_tls="trojan://${secret}@${domain}:443?type=grpc&security=tls&serviceName=trojan-grpc&sni=${domain}#${user}-gRPC"

# Telegram (HTML, properly escaped + delivery-checked via tg_send)
tg_send "$(xray_tg_text trojan "$user" "$secret" "$domain" "$quota_disp" "$ip_disp" "$exp_disp")"

clear
ui_header "TROJAN ACCOUNT CREATED"
echo -e " Remarks      : ${user}"
echo -e " Host/IP      : ${domain}"
echo -e " Port TLS     : 443"
echo -e " Key/Password : ${secret}"
echo -e " Transports   : WS, HTTPUpgrade, XHTTP, gRPC"
echo -e " Quota        : ${quota_disp}"
echo -e " Limit IP     : ${ip_disp}"
echo -e " Expired      : ${exp_disp}"
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
