#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: Create SSH account (SQLite-backed)
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
. /usr/local/sbin/lib/account.sh

require_root
db_init
domain=$(get_domain)
ip=$(get_ip)

clear
ui_header "CREATE SSH ACCOUNT"

while true; do
  read -rp "Username       : " user
  if ! valid_username "$user"; then err "Username 3-32 chars: letters, numbers, underscore."; continue; fi
  if db_account_exists "ssh" "$user" || id "$user" &>/dev/null; then err "Username '$user' already exists."; continue; fi
  break
done

while true; do
  read -rp "Password       : " pass
  valid_password "$pass" && break
  err "Password must be non-empty, no spaces/tabs/newlines/colons."
done

while true; do read -rp "Quota (GB,0=unl): " quota; valid_number "$quota" && break; err "Number only."; done
while true; do read -rp "Limit IP       : " limit_ip; valid_number "$limit_ip" && break; err "Number only."; done
while true; do read -rp "Expired (days) : " days; valid_days "$days" && break; err "Days must be 1-3650."; done

if ! acc_ssh_create "$user" "$pass" "$limit_ip" "$days" "$quota"; then
  err "Failed to create SSH account."; exit 1
fi

exp_epoch=$(db_get_field "ssh" "$user" "expired_at")
exp_disp=$(date -d "@${exp_epoch}" +"%Y-%m-%d %H:%M:%S")
[[ "$limit_ip" == "0" ]] && ip_disp="Unlimited" || ip_disp="$limit_ip"
[[ "$quota" == "0" ]] && quota_disp="Unlimited" || quota_disp="${quota} GB"

tg_send "$(ssh_tg_text "$user" "$pass" "$ip_disp" "$exp_disp" "$quota_disp" "SSH ACCOUNT")"

clear
ssh_print_cli "$user" "$pass" "$ip_disp" "$exp_disp" "$quota_disp" "SSH ACCOUNT CREATED"
read -n 1 -s -r -p " Press any key to back to menu..."
menu
