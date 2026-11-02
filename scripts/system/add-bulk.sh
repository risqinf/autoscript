#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: High-Speed Flash-Sale Bulk Account Generator (All Protocols)
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
. /usr/local/sbin/lib/account.sh

require_root
db_init
domain=$(get_domain)
ip=$(get_ip)

clear
ui_header "FLASH-SALE BULK ACCOUNT GENERATOR"
echo " 1. SSH    2. VLESS    3. VMESS    4. TROJAN    5. NOOBZ"
ui_rule
read -rp "Select Protocol (1-5): " sel
case "$sel" in
  1) proto="ssh" ;;
  2) proto="vless" ;;
  3) proto="vmess" ;;
  4) proto="trojan" ;;
  5) proto="noobz" ;;
  *) err "Invalid selection."; exit 1 ;;
esac

read -rp "Account Prefix (e.g. flash): " prefix
valid_prefix "$prefix" || { err "Prefix 1-16 chars: letters, numbers, underscore."; exit 1; }
read -rp "Number of Accounts (1-1000): " count
valid_number "$count" || { err "Count must be a number."; exit 1; }
(( count >= 1 && count <= 1000 )) || { err "Count must be 1-1000."; exit 1; }
read -rp "Expired (days): " days
valid_days "$days" || { err "Days must be 1-3650."; exit 1; }
if [[ "$proto" == "noobz" ]]; then
  read -rp "Limit Device (0=unlimited): " limit_ip
else
  read -rp "Limit IP (0=unlimited): " limit_ip
fi
valid_number "$limit_ip" || { err "Limit must be a number."; exit 1; }

read -rp "Quota (GB, 0=unlimited): " quota
valid_number "$quota" || { err "Quota must be a number."; exit 1; }

exp_epoch=$(( $(date +%s) + days * 86400 ))
exp_system=$(date -d "@${exp_epoch}" +%Y-%m-%d)
exp_disp=$(date -d "@${exp_epoch}" +"%Y-%m-%d %H:%M:%S")
quota_bytes=$(( quota * 1073741824 ))
[[ "$limit_ip" == "0" ]] && ip_disp="Unlimited" || ip_disp="$limit_ip"
[[ "$quota" == "0" ]] && quota_disp="Unlimited" || quota_disp="${quota} GB"

success=0
sent=0
declare -a CREATED_USERS=() CREATED_SECRETS=()

if [[ "$proto" == "vless" || "$proto" == "vmess" || "$proto" == "trojan" ]]; then
  clients_ndjson=""
  sql_tx="BEGIN TRANSACTION;"$'\n'
  for (( i=1; i<=count; i++ )); do
    user="${prefix}$(printf '%03d' "$i")_$(gen_pass 4 | tr 'A-Z' 'a-z')"
    secret=$(gen_uuid)
    if db_account_exists "$proto" "$user"; then continue; fi
    case "$proto" in
      vless)  cobj="{\"id\":\"${secret}\",\"email\":\"${user}\"}" ;;
      vmess)  cobj="{\"id\":\"${secret}\",\"alterId\":0,\"email\":\"${user}\"}" ;;
      trojan) cobj="{\"password\":\"${secret}\",\"email\":\"${user}\"}" ;;
    esac
    clients_ndjson+="${cobj}"$'\n'
    eu=$(sql_escape "$user"); es=$(sql_escape "$secret")
    sql_tx+="INSERT INTO accounts(protocol,username,secret,quota_bytes,limit_ip,expired_at,status) VALUES ('${proto}','${eu}','${es}',${quota_bytes},${limit_ip},${exp_epoch},'active');"$'\n'
    CREATED_USERS+=("$user")
    CREATED_SECRETS+=("$secret")
  done
  sql_tx+="INSERT INTO audit_log(actor,action,protocol,username,detail) VALUES ('$(sql_escape "$(whoami)")','bulk_create','${proto}','${prefix}*','count=${#CREATED_USERS[@]} quota=${quota}GB ip=${limit_ip}');"$'\n'
  sql_tx+="COMMIT;"

  clients_json=$(printf '%s' "$clients_ndjson" | jq -sc '.')
  if cfg_add_clients_batch "$proto" "$clients_json" && db_exec "$sql_tx"; then
    systemctl restart xray.service >/dev/null 2>&1
    success=${#CREATED_USERS[@]}
    for idx in "${!CREATED_USERS[@]}"; do
      echo "${proto^^}  ${CREATED_USERS[$idx]} / ${CREATED_SECRETS[$idx]}"
    done
  else
    err "Batch Xray creation failed; rolled back safely."
  fi
elif [[ "$proto" == "ssh" ]]; then
  nologin=$(ensure_nologin_shell); [[ -z "$nologin" ]] && nologin=/usr/sbin/nologin
  chpasswd_buf=""
  sql_tx="BEGIN TRANSACTION;"$'\n'
  for (( i=1; i<=count; i++ )); do
    user="${prefix}$(printf '%03d' "$i")_$(gen_pass 4 | tr 'A-Z' 'a-z')"
    pass=$(gen_pass 10)
    if db_account_exists "ssh" "$user" || id "$user" &>/dev/null; then continue; fi
    if useradd -e "$exp_system" -M -N -s "$nologin" "$user" 2>/dev/null; then
      chpasswd_buf+="${user}:${pass}"$'\n'
      eu=$(sql_escape "$user"); ep=$(sql_escape "$pass")
      sql_tx+="INSERT INTO accounts(protocol,username,secret,quota_bytes,limit_ip,expired_at,status) VALUES ('ssh','${eu}','${ep}',${quota_bytes},${limit_ip},${exp_epoch},'active');"$'\n'
      CREATED_USERS+=("$user")
      CREATED_SECRETS+=("$pass")
    fi
  done
  if [[ ${#CREATED_USERS[@]} -gt 0 ]]; then
    printf '%s' "$chpasswd_buf" | chpasswd
    sql_tx+="INSERT INTO audit_log(actor,action,protocol,username,detail) VALUES ('$(sql_escape "$(whoami)")','bulk_create','ssh','${prefix}*','count=${#CREATED_USERS[@]} quota=${quota}GB ip=${limit_ip}');"$'\n'
    sql_tx+="COMMIT;"
    db_exec "$sql_tx"
    success=${#CREATED_USERS[@]}
    for idx in "${!CREATED_USERS[@]}"; do
      echo "SSH  ${CREATED_USERS[$idx]} / ${CREATED_SECRETS[$idx]}"
    done
  fi
else
  for (( i=1; i<=count; i++ )); do
    user="${prefix}$(printf '%03d' "$i")_$(gen_pass 4 | tr 'A-Z' 'a-z')"
    pass=$(gen_pass 10)
    if acc_noobz_create "$user" "$pass" "$limit_ip" "$days" "$quota" >/dev/null 2>&1; then
      success=$((success+1))
      CREATED_USERS+=("$user")
      CREATED_SECRETS+=("$pass")
      echo "NOOBZ  $user / $pass"
    fi
  done
fi

if tg_is_configured && (( success > 0 )); then
  if (( success <= 15 )); then
    for idx in "${!CREATED_USERS[@]}"; do
      u="${CREATED_USERS[$idx]}"; s="${CREATED_SECRETS[$idx]}"
      if [[ "$proto" == "ssh" ]]; then
        tg_send "$(ssh_tg_text "$u" "$s" "$ip_disp" "$exp_disp" "$quota_disp" "SSH ACCOUNT (BULK)")" && sent=$((sent+1))
      elif [[ "$proto" == "noobz" ]]; then
        tg_send "$(noobz_tg_text "$u" "$s" "$ip_disp" "$exp_disp" "$quota_disp" "NOOBZVPN ACCOUNT (BULK)")" && sent=$((sent+1))
      else
        tg_send "$(xray_tg_text "$proto" "$u" "$s" "$domain" "$quota_disp" "$ip_disp" "$exp_disp" "${proto^^} ACCOUNT (BULK)")" && sent=$((sent+1))
      fi
    done
  else
    # Flash-sale summary message to avoid Telegram 429 flood-bans on 100+ accounts
    tg_send "<b>[ FLASH-SALE BULK CREATED ]</b>%0AProtocol: <code>${proto^^}</code>%0ACreated: <code>${success}</code> accounts%0APrefix: <code>${prefix}</code>%0AQuota: <code>${quota_disp}</code>%0AExpired: <code>${exp_disp}</code>" && sent=1
  fi
fi

ui_rule
ok "Created ${success}/${count} ${proto^^} accounts in high-speed batch mode."
if tg_is_configured; then
  ok "Telegram notification delivered (${sent} dispatch)."
fi
ui_foot
read -n 1 -s -r -p "Press any key to menu..."
menu
