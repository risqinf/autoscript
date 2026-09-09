#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: Create trial SSH account
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
. /usr/local/sbin/lib/account.sh

require_root
db_init
domain=$(get_domain)
ip=$(get_ip)

clear
ui_header "CREATE SSH TRIAL ACCOUNT"
while true; do read -rp "Expired (60m/2h/1d): " duration; valid_duration "$duration" && break; err "Format: 60m, 2h, 1d."; done
while true; do read -rp "Limit IP           : " limit_ip; valid_number "$limit_ip" && break; err "Number only."; done

user="trial$(gen_pass 6)"
pass=$(gen_pass 10)
secs=$(duration_to_seconds "$duration")
exp_epoch=$(( $(date +%s) + secs ))
exp_system=$(date -d "@${exp_epoch}" +%Y-%m-%d)

if db_account_exists "ssh" "$user" || id "$user" &>/dev/null; then err "Username collision, retry."; exit 1; fi
nologin=$(ensure_nologin_shell); [[ -z "$nologin" ]] && nologin=/usr/sbin/nologin
useradd -e "$exp_system" -M -N -s "$nologin" "$user" || { err "useradd failed"; exit 1; }
echo "${user}:${pass}" | chpasswd || { userdel --force "$user" >/dev/null 2>&1; err "chpasswd failed"; exit 1; }
quota_bytes=$(( 10 * 1073741824 ))
quota_disp="10 GB"
db_insert_account "ssh" "$user" "$pass" "$quota_bytes" "$limit_ip" "$exp_epoch"
db_audit "create" "ssh" "$user" "trial ${duration} quota=10GB"

exp_disp=$(date -d "@${exp_epoch}" +"%Y-%m-%d %H:%M:%S")
[[ "$limit_ip" == "0" ]] && ip_disp="Unlimited" || ip_disp="$limit_ip"

tg_send "$(ssh_tg_text "$user" "$pass" "$ip_disp" "$exp_disp" "$quota_disp" "SSH TRIAL ACCOUNT")"

clear
ssh_print_cli "$user" "$pass" "$ip_disp" "$exp_disp" "$quota_disp" "SSH TRIAL CREATED"
read -n 1 -s -r -p " Press any key to back to menu..."
menu
