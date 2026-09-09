#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: API - create trial SSH account (JSON in/out)
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
pass=$(gen_pass 10)
secs=$(duration_to_seconds "$duration")
exp_epoch=$(( $(date +%s) + secs ))
exp_system=$(date -d "@${exp_epoch}" +%Y-%m-%d)

if db_account_exists "ssh" "$user" || id "$user" &>/dev/null; then err_json 409 "Username collision, retry"; fi
nologin=$(ensure_nologin_shell); [[ -z "$nologin" ]] && nologin=/usr/sbin/nologin
useradd -e "$exp_system" -M -N -s "$nologin" "$user" || err_json 500 "useradd failed"
echo "${user}:${pass}" | chpasswd || { userdel --force "$user" >/dev/null 2>&1; err_json 500 "chpasswd failed"; }
db_insert_account "ssh" "$user" "$pass" 0 "$limit_ip" "$exp_epoch"
db_audit "create" "ssh" "$user" "trial api ${duration}"
exp_disp=$(date -d "@${exp_epoch}" +"%d-%m-%Y %H:%M:%S")

dns_ns=$(cat /etc/slowdns/nameserver 2>/dev/null | tr -d '\r\n')
dns_pub=$(cat /etc/slowdns/server.pub 2>/dev/null | tr -d '\r\n')

jq -nc --arg u "$user" --arg p "$pass" --arg d "$domain" --arg ip "$ip" \
      --argjson li "$limit_ip" --arg exp "$exp_disp" \
      --arg dns_ns "$dns_ns" --arg dns_pub "$dns_pub" \
'{status:"true",code:201,message:"SSH trial account created successfully",
  data:{username:$u,password:$p,domain:$d,ip:$ip,limit_ip:$li,expired:$exp,
         ports:{ssh:"109",ws_http:"80, 8888",ws_tls:"443",badvpn:"7300",
                openvpn_tcp:"1194",
                slowdns:(if $dns_pub != "" then "53, 5300" else null end)},
         slowdns:(if $dns_pub != "" then {nameserver:$dns_ns,public_key:$dns_pub,port:"53, 5300 UDP"} else null end),
        config:($d+":1-65535@"+$u+":"+$p)}}'
