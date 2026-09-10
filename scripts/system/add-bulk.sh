#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: Bulk account generator (DB-driven, all protocols)
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
. /usr/local/sbin/lib/account.sh

require_root
db_init
domain=$(get_domain)
ip=$(get_ip)

clear
line
echo -e "${WHITE}  AUTO BULK ACCOUNT GENERATOR${NC}"
line
echo "1. SSH    2. VLESS    3. VMESS    4. TROJAN    5. NOOBZ"
line
read -rp "Select Protocol (1-5): " sel
case "$sel" in
  1) proto="ssh" ;;
  2) proto="vless" ;;
  3) proto="vmess" ;;
  4) proto="trojan" ;;
  5) proto="noobz" ;;
  *) err "Invalid selection."; exit 1 ;;
esac

read -rp "Account Prefix (e.g. user): " prefix
valid_prefix "$prefix" || { err "Prefix 1-16 chars: letters, numbers, underscore."; exit 1; }
read -rp "Number of Accounts: " count
valid_number "$count" || { err "Count must be a number."; exit 1; }
(( count >= 1 )) || { err "Count must be >= 1."; exit 1; }
read -rp "Expired (days): " days
valid_days "$days" || { err "Days must be 1-3650."; exit 1; }
if [[ "$proto" == "noobz" ]]; then
  read -rp "Limit Device (0=unlimited): " limit_ip
else
  read -rp "Limit IP (0=unlimited): " limit_ip
fi
valid_number "$limit_ip" || { err "Limit must be a number."; exit 1; }

quota=0
if [[ "$proto" != "ssh" ]]; then
  read -rp "Quota (GB, 0=unlimited): " quota
  valid_number "$quota" || { err "Quota must be a number."; exit 1; }
fi

exp_epoch=$(( $(date +%s) + days * 86400 ))
exp_disp=$(date -d "@${exp_epoch}" +"%Y-%m-%d %H:%M:%S")
[[ "$limit_ip" == "0" ]] && ip_disp="Unlimited" || ip_disp="$limit_ip"
[[ "$quota" == "0" ]] && quota_disp="Unlimited" || quota_disp="${quota} GB"
success=0
sent=0

for (( i=1; i<=count; i++ )); do
  user="${prefix}$(gen_pass 4 | tr 'A-Z' 'a-z')"
  if [[ "$proto" == "ssh" ]]; then
    pass=$(gen_pass 10)
    if acc_ssh_create "$user" "$pass" "$limit_ip" "$days" >/dev/null 2>&1; then
      success=$((success+1)); echo "SSH  $user / $pass"
      # One Telegram message per account.
      if tg_send "$(ssh_tg_text "$user" "$pass" "$ip_disp" "$exp_disp" "SSH ACCOUNT (BULK)")"; then
        sent=$((sent+1))
      fi
    fi
  elif [[ "$proto" == "noobz" ]]; then
    pass=$(gen_pass 10)
    if acc_noobz_create "$user" "$pass" "$limit_ip" "$days" "$quota" >/dev/null 2>&1; then
      success=$((success+1)); echo "NOOBZ  $user / $pass"
      # One Telegram message per account.
      if tg_send "$(noobz_tg_text "$user" "$pass" "$ip_disp" "$exp_disp" "$quota_disp" "NOOBZVPN ACCOUNT (BULK)")"; then
        sent=$((sent+1))
      fi
    fi
  else
    secret=$(gen_uuid)
    if acc_xray_create "$proto" "$user" "$secret" "$quota" "$limit_ip" "$exp_epoch" >/dev/null 2>&1; then
      success=$((success+1)); echo "${proto^^}  $user / $secret"
      # One Telegram message per account.
      if tg_send "$(xray_tg_text "$proto" "$user" "$secret" "$domain" "$quota_disp" "$ip_disp" "$exp_disp" "${proto^^} ACCOUNT (BULK)")"; then
        sent=$((sent+1))
      fi
    fi
  fi
done

line
ok "Created ${success}/${count} ${proto} accounts."
if tg_is_configured; then
  ok "Telegram: ${sent}/${success} per-account messages sent."
else
  warn "Telegram not configured (set it via System > Telegram); no messages sent."
fi
line
read -n 1 -s -r -p "Press any key to menu..."
menu
