#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: API - delete NoobzVPN account (JSON in/out)
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
. /usr/local/sbin/lib/account.sh
db_init

input=$(cat)
user=$(echo "$input" | jq -r '.username // empty' 2>/dev/null)
err_json() { echo "{\"status\":\"false\",\"code\":$1,\"message\":\"$2\"}"; exit 1; }

valid_username "$user" || err_json 400 "Invalid username"
db_account_exists "noobz" "$user" || err_json 404 "User '$user' not found"
acc_noobz_delete "$user" >/dev/null 2>&1 || err_json 500 "Failed to delete account"

jq -nc --arg u "$user" \
'{status:"true",code:200,message:("User \($u) deleted successfully"),
  data:{username:$u,recoverable:true}}'
