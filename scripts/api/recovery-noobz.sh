#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: API - recover NoobzVPN account (JSON in/out)
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
. /usr/local/sbin/lib/account.sh
db_init
PROTO="noobz"

input=$(cat)
user=$(echo "$input" | jq -r '.username // empty' 2>/dev/null)
err_json() { echo "{\"status\":\"false\",\"code\":$1,\"message\":\"$2\"}"; exit 1; }

valid_username "$user" || err_json 400 "Invalid username"

days=$(echo "$input" | jq -r '.days // 30' 2>/dev/null)
valid_days "$days"     || err_json 400 "Days must be 1-3650"

cnt=$(db_query "SELECT COUNT(*) FROM accounts WHERE protocol='$(sql_escape "$PROTO")' AND username='$(sql_escape "$user")' AND status IN ('deleted','suspended');")
[[ "$cnt" -gt 0 ]] || err_json 404 "No recoverable account for '$user'"

if ! acc_noobz_recover "$user" "$days"; then
  err_json 500 "Failed to recover NoobzVPN account"
fi

new_epoch=$(db_get_field "$PROTO" "$user" "expired_at")
new_disp=$(date -d "@${new_epoch}" +"%Y-%m-%d %H:%M:%S")

jq -nc --arg u "$user" --arg p "$PROTO" --arg exp "$new_disp" \
'{status:"true",code:200,message:("\($p) account \($u) recovered successfully"),
  data:{username:$u,protocol:$p,status:"active",expired:$exp}}'
