#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: Create trial Trojan account
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
. /usr/local/sbin/lib/account.sh

require_root
db_init
domain=$(get_domain)

clear
ui_header "CREATE TROJAN TRIAL ACCOUNT"
while true; do read -rp "Expired (60m/1h/1d): " duration; valid_duration "$duration" && break; err "Format: 60m, 1h, 1d."; done

user="trial$(gen_pass 6)"
secret=$(gen_uuid)
secs=$(duration_to_seconds "$duration")
exp_epoch=$(( $(date +%s) + secs ))

if ! acc_xray_create "trojan" "$user" "$secret" 10 2 "$exp_epoch"; then err "Failed to create trial."; exit 1; fi

exp_disp=$(date -d "@${exp_epoch}" +"%Y-%m-%d %H:%M:%S")
trojan_ws_tls="trojan://${secret}@${domain}:443?type=ws&security=tls&host=${domain}&path=/trojan&sni=${domain}#${user}-WS-TLS"
trojan_hu_tls="trojan://${secret}@${domain}:443?type=httpupgrade&security=tls&host=${domain}&path=/trojan-hu&sni=${domain}#${user}-HU-TLS"
trojan_xhttp_tls="trojan://${secret}@${domain}:443?type=xhttp&security=tls&host=${domain}&path=/trojan-xhttp&mode=auto&sni=${domain}#${user}-XHTTP-TLS"
trojan_grpc_tls="trojan://${secret}@${domain}:443?type=grpc&security=tls&serviceName=trojan-grpc&sni=${domain}#${user}-gRPC"

tg_send "$(xray_tg_text trojan "$user" "$secret" "$domain" "10 GB" "2" "$exp_disp" "TROJAN TRIAL ACCOUNT")"

clear
ui_header "TROJAN TRIAL CREATED"
echo -e " Remarks      : ${user}"
echo -e " Host/IP      : ${domain}"
echo -e " Key/Password : ${secret}"
echo -e " Transports   : WS, HTTPUpgrade, XHTTP, gRPC"
echo -e " Quota        : 10 GB     Limit IP : 2"
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
