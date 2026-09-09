#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: Create trial NoobzVPN account
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
. /usr/local/sbin/lib/account.sh

require_root
db_init
domain=$(get_domain)
ip=$(get_ip)

clear
ui_header "CREATE NOOBZVPN TRIAL ACCOUNT"
while true; do read -rp "Expired (60m/2h/1d): " duration; valid_duration "$duration" && break; err "Format: 60m, 2h, 1d."; done
while true; do read -rp "Limit Device       : " limit_dev; valid_number "$limit_dev" && break; err "Number only."; done

user="trial$(gen_pass 6)"
pass=$(gen_pass 10)
secs=$(duration_to_seconds "$duration")
days=$(( (secs + 86399) / 86400 ))
(( days < 1 )) && days=1

if db_account_exists "noobz" "$user"; then err "Username collision, retry."; exit 1; fi

quota_gb=10
if ! acc_noobz_create "$user" "$pass" "$limit_dev" "$days" "$quota_gb"; then
  err "Failed to create trial account."; exit 1
fi

exp_epoch=$(( $(date +%s) + secs ))
db_set_expired "noobz" "$user" "$exp_epoch"

exp_disp=$(date -d "@${exp_epoch}" +"%Y-%m-%d %H:%M:%S")
[[ "$limit_dev" == "0" ]] && dev_disp="Unlimited" || dev_disp="$limit_dev"
quota_disp="10 GB"

tg_send "$(noobz_tg_text "$user" "$pass" "$dev_disp" "$exp_disp" "$quota_disp" "NOOBZVPN TRIAL ACCOUNT")"

clear
noobz_print_cli "$user" "$pass" "$dev_disp" "$exp_disp" "$quota_disp" "NOOBZVPN TRIAL CREATED"
read -n 1 -s -r -p " Press any key to back to menu..."
menu
