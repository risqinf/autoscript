#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: API - create SSH account (JSON in/out)
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

err_json() { echo "{\"status\":\"false\",\"code\":$1,\"message\":\"$2\"}"; exit 1; }

valid_username "$user"   || err_json 400 "Invalid username (3-32 chars: letters, numbers, underscore)"
valid_password "$pass"   || err_json 400 "Invalid password (no spaces/tabs/newlines/colons)"
valid_days "$days"       || err_json 400 "Expired must be 1-3650 days"
valid_number "$limit_ip" || err_json 400 "Limit IP must be a number"

if db_account_exists "ssh" "$user" || id "$user" &>/dev/null; then
  err_json 409 "Username '$user' already exists"
fi

if ! acc_ssh_create "$user" "$pass" "$limit_ip" "$days" >/dev/null 2>&1; then
  err_json 500 "Failed to create SSH account"
fi

exp_epoch=$(db_get_field "ssh" "$user" "expired_at")
exp_disp=$(date -d "@${exp_epoch}" +"%d-%m-%Y %H:%M:%S")

jq -nc --arg u "$user" --arg p "$pass" --arg d "$domain" --arg ip "$ip" \
      --argjson li "$limit_ip" --arg exp "$exp_disp" \
'{status:"true",code:201,message:"SSH account created successfully",
  data:{username:$u,password:$p,domain:$d,ip:$ip,limit_ip:$li,expired:$exp,
         ports:{ssh:"109",ws_http:"80, 8888",ws_tls:"443",badvpn:"7300",
                openvpn_tcp:"1194"},
        config:($d+":1-65535@"+$u+":"+$p)}}'
