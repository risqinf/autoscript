#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: API - recover SSH account (JSON in/out)
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
. /usr/local/sbin/lib/account.sh
db_init
PROTO="ssh"

input=$(cat)
user=$(echo "$input" | jq -r '.username // empty' 2>/dev/null)
days=$(echo "$input" | jq -r '.days // 30' 2>/dev/null)
err_json() { echo "{\"status\":\"false\",\"code\":$1,\"message\":\"$2\"}"; exit 1; }

valid_username "$user" || err_json 400 "Invalid username"
valid_days "$days"     || err_json 400 "Days must be 1-3650"

cnt=$(db_query "SELECT COUNT(*) FROM accounts WHERE protocol='$(sql_escape "$PROTO")' AND username='$(sql_escape "$user")' AND status IN ('deleted','suspended','expired');")
[[ "$cnt" -gt 0 ]] || err_json 404 "No recoverable account for '$user'"

secret=$(db_query "SELECT secret FROM accounts WHERE protocol='$(sql_escape "$PROTO")' AND username='$(sql_escape "$user")' ORDER BY updated_at DESC LIMIT 1;")
new_epoch=$(( $(date +%s) + days * 86400 ))
exp_system=$(date -d "@${new_epoch}" +%Y-%m-%d)

if id "$user" &>/dev/null; then
  chage -E "$exp_system" "$user" 2>/dev/null || true
else
  nologin=$(ensure_nologin_shell); [[ -z "$nologin" ]] && nologin=/usr/sbin/nologin
  useradd -e "$exp_system" -M -N -s "$nologin" "$user" || err_json 500 "Failed to recreate system user"
  echo "${user}:${secret}" | chpasswd || err_json 500 "Failed to set user password"
fi

db_set_expired "$PROTO" "$user" "$new_epoch"
db_set_status "$PROTO" "$user" "active"
db_audit "recover" "$PROTO" "$user" "via api +${days}d"
systemctl restart dropbear >/dev/null 2>&1 || true

new_disp=$(date -d "@${new_epoch}" +"%Y-%m-%d %H:%M:%S")

jq -nc --arg u "$user" --arg p "$PROTO" --arg exp "$new_disp" \
'{status:"true",code:200,message:("\($p) account \($u) recovered successfully"),
  data:{username:$u,protocol:$p,status:"active",expired:$exp}}'
