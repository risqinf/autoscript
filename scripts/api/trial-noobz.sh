#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: API - create trial NoobzVPN account (JSON in/out)
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
. /usr/local/sbin/lib/account.sh
db_init
domain=$(get_domain); ip=$(get_ip)

input=$(cat)
duration=$(echo "$input" | jq -r '.duration // "60m"' 2>/dev/null)
limit_ip=$(echo "$input" | jq -r '.limit_ip // 1' 2>/dev/null)
err_json() { echo "{\"status\":\"false\",\"code\":$1,\"message\":\"$2\"}"; exit 1; }
valid_duration "$duration" || err_json 400 "Duration must be like 30m, 1h, 1d"
valid_number "$limit_ip"   || err_json 400 "Limit IP must be a number"

user="trial$(gen_pass 6)"
pass=$(gen_pass 8)
secs=$(duration_to_seconds "$duration")
exp_epoch=$(( $(date +%s) + secs ))
exp_system=$(date -d "@${exp_epoch}" +%Y-%m-%d)

if db_account_exists "noobz" "$user"; then err_json 409 "Username collision, retry"; fi

noobzvpns user add "$user" "$pass" >/dev/null 2>&1 || true
noobzvpns user expire "$user" "$exp_system" >/dev/null 2>&1 || true
if [[ "$limit_ip" -gt 0 ]]; then
  noobzvpns user devices "$user" "$limit_ip" >/dev/null 2>&1 || true
fi

db_insert_account "noobz" "$user" "$pass" 0 "$limit_ip" "$exp_epoch"
db_audit "create" "noobz" "$user" "trial api ${duration}"
exp_disp=$(date -d "@${exp_epoch}" +"%d-%m-%Y %H:%M:%S")

payload="GET /noobz HTTP/1.1[crlf]Host: ${domain}[crlf]Upgrade: websocket[crlf][crlf]"
config="${domain}:8585@${user}:${pass}"

jq -nc --arg u "$user" --arg p "$pass" --arg d "$domain" --arg ip "$ip" \
      --argjson li "$limit_ip" --arg exp "$exp_disp" --arg pl "$payload" \
      --arg cfg "$config" \
'{status:"true",code:201,message:"NoobzVPN trial account created successfully",
  data:{username:$u,password:$p,domain:$d,ip:$ip,limit_ip:$li,expired:$exp,
         identifier:"risqinf",payload:$pl,
         ports:{tcp:"8585",ws_http:"80, 8080",ws_tls:"443"},
         config:$cfg}}'
