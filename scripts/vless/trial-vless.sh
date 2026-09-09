#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: Create trial VLESS account
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
. /usr/local/sbin/lib/account.sh

require_root
db_init
domain=$(get_domain)

clear
ui_header "CREATE VLESS TRIAL ACCOUNT"
while true; do read -rp "Expired (60m/1h/1d): " duration; valid_duration "$duration" && break; err "Format: 60m, 1h, 1d."; done

user="trial$(gen_pass 6)"
uuid=$(gen_uuid)
secs=$(duration_to_seconds "$duration")
exp_epoch=$(( $(date +%s) + secs ))

if ! acc_xray_create "vless" "$user" "$uuid" 10 2 "$exp_epoch"; then err "Failed to create trial."; exit 1; fi

exp_disp=$(date -d "@${exp_epoch}" +"%Y-%m-%d %H:%M:%S")
vless_ws_tls="vless://${uuid}@${domain}:443?path=/vless&security=tls&encryption=none&type=ws&host=${domain}&sni=${domain}#${user}-WS-TLS"
vless_ws_ntls="vless://${uuid}@${domain}:80?path=/vless&encryption=none&type=ws&host=${domain}#${user}-WS-NTLS"
vless_hu_tls="vless://${uuid}@${domain}:443?path=/vless-hu&security=tls&encryption=none&type=httpupgrade&host=${domain}&sni=${domain}#${user}-HU-TLS"
vless_hu_ntls="vless://${uuid}@${domain}:80?path=/vless-hu&encryption=none&type=httpupgrade&host=${domain}#${user}-HU-NTLS"
vless_xhttp_tls="vless://${uuid}@${domain}:443?mode=auto&path=/vless-xhttp&security=tls&encryption=none&type=xhttp&host=${domain}&sni=${domain}#${user}-XHTTP-TLS"
vless_xhttp_ntls="vless://${uuid}@${domain}:80?mode=auto&path=/vless-xhttp&security=none&encryption=none&type=xhttp&host=${domain}#${user}-XHTTP-NTLS"
vless_grpc_tls="vless://${uuid}@${domain}:443?serviceName=vless-grpc&security=tls&encryption=none&type=grpc&sni=${domain}#${user}-gRPC"

tg_send "$(xray_tg_text vless "$user" "$uuid" "$domain" "10 GB" "2" "$exp_disp" "VLESS TRIAL ACCOUNT")"

clear
ui_header "VLESS TRIAL CREATED"
echo -e " Remarks      : ${user}"
echo -e " Host/IP      : ${domain}"
echo -e " UUID         : ${uuid}"
echo -e " Transports   : WS, HTTPUpgrade, XHTTP, gRPC"
echo -e " Quota        : 10 GB     Limit IP : 2"
echo -e " Expired      : ${exp_disp}"
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
