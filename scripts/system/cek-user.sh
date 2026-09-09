#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: Unified account lookup across all protocols (DB-driven)
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
. /usr/local/sbin/lib/account.sh

db_init
domain=$(get_domain)
ip=$(get_ip)

clear
ui_header "UNIFIED ACCOUNT CHECKER"
read -rp " Input Username : " user
ui_rule

if ! valid_username "$user"; then
  err "Invalid username format."
  read -n 1 -s -r -p "Press any key to menu..."; menu; exit 1
fi

vmess_link() {
  local secret="$1" port="$2" tls="$3"
  jq -nc --arg ps "$user" --arg add "$domain" --arg port "$port" \
        --arg id "$secret" --arg host "$domain" --arg tls "$tls" \
        '{v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:"0",net:"ws",path:"/",type:"none",host:$host,tls:$tls}' \
    | base64 -w 0 | sed 's/^/vmess:\/\//'
}

found=0
while IFS='|' read -r proto secret iplim qb exp status; do
  [[ -z "$proto" ]] && continue
  found=1
  [[ "$iplim" == "0" ]] && iplim="Unlimited"
  [[ "$qb" == "0" || -z "$qb" ]] && quota="Unlimited" || quota="$(( qb / 1073741824 )) GB"
  if [[ "$proto" == "ssh" ]]; then
    ssh_print_cli "$user" "$secret" "$iplim" "$exp" "$quota" "SSH ACCOUNT ($status)"
    continue
  fi
  ui_header "${proto^^} ACCOUNT (${status})"
  ui_kv "Remarks"   "$user" "$CYAN"
  ui_kv "Host / IP" "$domain"
  case "$proto" in
    vless)
      ui_kv "UUID"     "$secret"
      ui_kv "Net/Path" "ws  /vless   (443 TLS / 80 HTTP)"
      ui_kv "Quota"    "$quota"
      ui_kv "Limit IP" "$iplim"
      ui_kv "Expired"  "$exp"
      ui_rule
      echo -e " ${WHITE}Link TLS :${NC}"
      echo -e " ${GREEN}vless://${secret}@${domain}:443?path=/vless&security=tls&encryption=none&type=ws&host=${domain}&sni=${domain}#${user}${NC}"
      echo -e " ${WHITE}Link HTTP :${NC}"
      echo -e " ${GREEN}vless://${secret}@${domain}:80?path=/vless&encryption=none&type=ws&host=${domain}#${user}${NC}"
      ;;
    vmess)
      ui_kv "UUID"     "${secret}  (AlterId 0)"
      ui_kv "Net/Path" "ws  /  multipath   (443 TLS / 80 HTTP)"
      ui_kv "Quota"    "$quota"
      ui_kv "Limit IP" "$iplim"
      ui_kv "Expired"  "$exp"
      ui_rule
      echo -e " ${WHITE}Link TLS :${NC}"
      echo -e " ${GREEN}$(vmess_link "$secret" 443 tls)${NC}"
      echo -e " ${WHITE}Link HTTP :${NC}"
      echo -e " ${GREEN}$(vmess_link "$secret" 80 none)${NC}"
      ;;
    trojan)
      ui_kv "Key"      "$secret"
      ui_kv "Net/Path" "ws  /trojan   (443 TLS)"
      ui_kv "Quota"    "$quota"
      ui_kv "Limit IP" "$iplim"
      ui_kv "Expired"  "$exp"
      ui_rule
      echo -e " ${WHITE}Link TLS :${NC}"
      echo -e " ${GREEN}trojan://${secret}@${domain}:443?type=ws&security=tls&host=${domain}&path=/trojan&sni=${domain}#${user}${NC}"
      ;;
  esac
  ui_foot
done < <(db_query "SELECT protocol, secret, limit_ip, quota_bytes,
                          datetime(expired_at,'unixepoch','localtime'), status
                   FROM accounts
                   WHERE username='$(sql_escape "$user")' AND status!='deleted'
                   ORDER BY protocol;")

[[ $found -eq 0 ]] && err "Account '$user' not found in any protocol."
line
read -n 1 -s -r -p "Press any key to menu..."
menu
