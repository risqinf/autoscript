#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: Create NoobzVPN account
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
. /usr/local/sbin/lib/account.sh

require_root
db_init
domain=$(get_domain)
ip=$(get_ip)

clear
ui_header "CREATE NOOBZVPN ACCOUNT"

while true; do
  read -rp "Username       : " user
  if ! valid_username "$user"; then err "Username 3-32 chars: letters, numbers, underscore."; continue; fi
  if db_account_exists "noobz" "$user"; then err "Username '$user' already exists."; continue; fi
  break
done

while true; do
  read -rp "Password       : " pass
  valid_password "$pass" && break
  err "Password must be non-empty, no spaces/tabs/newlines/colons."
done

while true; do read -rp "Quota (GB,0=unl): " quota; valid_number "$quota" && break; err "Number only."; done
while true; do read -rp "Limit Device   : " limit_dev; valid_number "$limit_dev" && break; err "Number only."; done
while true; do read -rp "Expired (days) : " days; valid_days "$days" && break; err "Days must be 1-3650."; done

if ! acc_noobz_create "$user" "$pass" "$limit_dev" "$days" "$quota"; then
  err "Failed to create NoobzVPN account."; exit 1
fi

exp_epoch=$(db_get_field "noobz" "$user" "expired_at")
exp_disp=$(date -d "@${exp_epoch}" +"%Y-%m-%d %H:%M:%S")
[[ "$limit_dev" == "0" ]] && dev_disp="Unlimited" || dev_disp="$limit_dev"
[[ "$quota" == "0" ]] && quota_disp="Unlimited" || quota_disp="${quota} GB"

tg_send "$(noobz_tg_text "$user" "$pass" "$dev_disp" "$exp_disp" "$quota_disp" "NOOBZVPN ACCOUNT")"

clear
noobz_print_cli "$user" "$pass" "$dev_disp" "$exp_disp" "$quota_disp" "NOOBZVPN ACCOUNT CREATED"
read -n 1 -s -r -p " Press any key to back to menu..."
menu
