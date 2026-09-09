#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: API - create NoobzVPN account (JSON in/out)
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
. /usr/local/sbin/lib/account.sh
db_init
domain=$(get_domain); ip=$(get_ip)

input=$(cat)
user=$(echo "$input" | jq -r '.username // empty' 2>/dev/null)
pass=$(echo "$input" | jq -r '.password // empty' 2>/dev/null)
days=$(echo "$input" | jq -r '.expired // .masa // empty' 2>/dev/null)
limit_ip=$(echo "$input" | jq -r '.limit_ip // .iplimit // 0' 2>/dev/null)
quota=$(echo "$input" | jq -r '.quota // 0' 2>/dev/null)

err_json() { echo "{\"status\":\"false\",\"code\":$1,\"message\":\"$2\"}"; exit 1; }

valid_username "$user"   || err_json 400 "Invalid username (3-32 chars: letters, numbers, underscore)"
valid_password "$pass"   || err_json 400 "Invalid password (no spaces/tabs/newlines/colons)"
valid_days "$days"       || err_json 400 "Expired must be 1-3650 days"
valid_number "$limit_ip" || err_json 400 "Limit IP must be a number"
valid_number "$quota"    || err_json 400 "Quota must be a number"

if db_account_exists "noobz" "$user"; then
  err_json 409 "Username '$user' already exists"
fi

if ! acc_noobz_create "$user" "$pass" "$limit_ip" "$days" "$quota" >/dev/null 2>&1; then
  err_json 500 "Failed to create NoobzVPN account"
fi

exp_epoch=$(db_get_field "noobz" "$user" "expired_at")
exp_disp=$(date -d "@${exp_epoch}" +"%d-%m-%Y %H:%M:%S")

payload="GET /noobz HTTP/1.1[crlf]Host: ${domain}[crlf]Upgrade: websocket[crlf][crlf]"
config="${domain}:8585@${user}:${pass}"

jq -nc --arg u "$user" --arg p "$pass" --arg d "$domain" --arg ip "$ip" \
      --argjson li "$limit_ip" --arg exp "$exp_disp" --arg pl "$payload" \
      --arg cfg "$config" --argjson q "$quota" \
'{status:"true",code:201,message:"NoobzVPN account created successfully",
  data:{username:$u,password:$p,domain:$d,ip:$ip,limit_ip:$li,quota_gb:$q,expired:$exp,
         identifier:"risqinf",payload:$pl,
         ports:{tcp:"8585",ws_http:"80, 8080",ws_tls:"443"},
         config:$cfg}}'
