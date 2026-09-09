#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: API - renew NoobzVPN account (JSON in/out)
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
. /usr/local/sbin/lib/account.sh
db_init

input=$(cat)
user=$(echo "$input" | jq -r '.username // empty' 2>/dev/null)
days=$(echo "$input" | jq -r '.days // empty' 2>/dev/null)
err_json() { echo "{\"status\":\"false\",\"code\":$1,\"message\":\"$2\"}"; exit 1; }

valid_username "$user" || err_json 400 "Invalid username"
valid_days "$days"     || err_json 400 "Days must be 1-3650"
db_account_exists "noobz" "$user" || err_json 404 "User '$user' not found"

new_epoch=$(acc_noobz_renew "$user" "$days")
[[ -n "$new_epoch" ]] || err_json 500 "Renew failed"
new_disp=$(date -d "@${new_epoch}" +"%Y-%m-%d %H:%M:%S")

jq -nc --arg u "$user" --argjson d "$days" --arg exp "$new_disp" \
'{status:"true",code:200,message:("Account \($u) renewed successfully"),
  data:{username:$u,protocol:"noobz",days_added:$d,new_expiry:$exp}}'
