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

cnt=$(db_query "SELECT COUNT(*) FROM accounts WHERE protocol='$(sql_escape "$PROTO")' AND username='$(sql_escape "$user")' AND status IN ('deleted','suspended');")
[[ "$cnt" -gt 0 ]] || err_json 404 "No recoverable account for '$user'"

secret=$(db_query "SELECT secret FROM accounts WHERE protocol='$(sql_escape "$PROTO")' AND username='$(sql_escape "$user")' ORDER BY updated_at DESC LIMIT 1;")
exp_epoch=$(db_query "SELECT expired_at FROM accounts WHERE protocol='$(sql_escape "$PROTO")' AND username='$(sql_escape "$user")' ORDER BY updated_at DESC LIMIT 1;")
exp_system=$(date -d "@${exp_epoch}" +%Y-%m-%d 2>/dev/null || date -d "+30 days" +%Y-%m-%d)

noobzvpns user add "$user" "$secret" >/dev/null 2>&1 || true
noobzvpns user expire "$user" "$exp_system" >/dev/null 2>&1 || true

db_exec "UPDATE accounts SET status='active', updated_at=strftime('%s','now')
         WHERE protocol='$(sql_escape "$PROTO")' AND username='$(sql_escape "$user")';"
db_audit "recover" "$PROTO" "$user" "via api"

jq -nc --arg u "$user" --arg p "$PROTO" \
'{status:"true",code:200,message:("\($p) account \($u) recovered successfully"),
  data:{username:$u,protocol:$p,status:"active"}}'
