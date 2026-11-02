#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: High-level account service (DB + Xray config + system user)
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
[[ -n "${__AS_ACCOUNT_LOADED:-}" ]] && return 0
__AS_ACCOUNT_LOADED=1

LIBD="$(dirname "${BASH_SOURCE[0]}")"
. "$LIBD/common.sh"
. "$LIBD/db.sh"
. "$LIBD/xraycfg.sh"

# ---- XRAY ACCOUNTS (vless/vmess/trojan) ----
# Create. Args: proto user secret quota_gb limit_ip expired_epoch
# Echoes nothing; returns 0/!=0. On success the account is in DB + config.
acc_xray_create() {
  local proto="$1" user="$2" secret="$3" quota_gb="$4" limit_ip="$5" exp_epoch="$6"
  local quota_bytes=0
  (( quota_gb > 0 )) && quota_bytes=$(( quota_gb * 1073741824 ))

  if db_account_exists "$proto" "$user" || cfg_client_exists "$user"; then
    err "username '$user' already exists"; return 9
  fi
  if db_secret_in_use "$secret" || cfg_secret_exists "$secret"; then
    err "secret/uuid already in use"; return 9
  fi

  # Config first (validated + rollback); then DB.
  if ! cfg_add_client "$proto" "$user" "$secret"; then
    err "failed to update xray config"; return 1
  fi
  if ! db_insert_account "$proto" "$user" "$secret" "$quota_bytes" "$limit_ip" "$exp_epoch"; then
    # rollback config
    cfg_del_client "$proto" "$user"
    err "failed to write database"; return 1
  fi
  db_audit "create" "$proto" "$user" "quota=${quota_gb}GB ip=${limit_ip}"
  systemctl restart xray.service >/dev/null 2>&1
  return 0
}

# Soft-delete (status=deleted) + remove from config. Recoverable from DB.
acc_xray_delete() {
  local proto="$1" user="$2"
  db_account_exists "$proto" "$user" || { err "account not found"; return 4; }
  cfg_del_client "$proto" "$user" || { err "failed to update config"; return 1; }
  db_set_status "$proto" "$user" "deleted"
  db_audit "delete" "$proto" "$user" ""
  systemctl restart xray.service >/dev/null 2>&1
  return 0
}

# Suspend (status=suspended) + remove from config but keep DB row active-data.
acc_xray_suspend() {
  local proto="$1" user="$2" reason="${3:-limit}"
  db_account_exists "$proto" "$user" || return 4
  cfg_del_client "$proto" "$user"
  db_set_status "$proto" "$user" "suspended"
  db_audit "suspend" "$proto" "$user" "$reason"
  systemctl restart xray.service >/dev/null 2>&1
  return 0
}

# Renew. Args: proto user add_days  -> extends from max(now, current expiry)
acc_xray_renew() {
  local proto="$1" user="$2" days="$3"
  local cur now base new
  cur=$(db_get_field "$proto" "$user" "expired_at")
  [[ -z "$cur" ]] && { err "account not found"; return 4; }
  now=$(date +%s)
  base=$cur; (( cur < now )) && base=$now
  new=$(( base + days * 86400 ))
  db_set_expired "$proto" "$user" "$new"
  db_audit "renew" "$proto" "$user" "+${days}d"
  echo "$new"
  return 0
}

# ---- SSH ACCOUNTS ----
acc_ssh_create() {
  local user="$1" pass="$2" limit_ip="$3" days="$4" quota_gb="${5:-0}"
  local exp_epoch exp_system quota_bytes=0
  exp_epoch=$(( $(date +%s) + days * 86400 ))
  exp_system=$(date -d "@${exp_epoch}" +%Y-%m-%d)
  if [[ -n "$quota_gb" && "$quota_gb" =~ ^[0-9]+$ && "$quota_gb" -gt 0 ]]; then
    quota_bytes=$(( quota_gb * 1073741824 ))
  fi

  if db_account_exists "ssh" "$user" || id "$user" &>/dev/null; then
    err "username '$user' already exists"; return 9
  fi
  local nologin
  nologin=$(ensure_nologin_shell); [[ -z "$nologin" ]] && nologin=/usr/sbin/nologin
  useradd -e "$exp_system" -M -N -s "$nologin" "$user" || { err "useradd failed"; return 1; }
  echo "${user}:${pass}" | chpasswd || { userdel --force "$user" >/dev/null 2>&1; err "chpasswd failed"; return 1; }
  db_insert_account "ssh" "$user" "$pass" "$quota_bytes" "$limit_ip" "$exp_epoch"
  db_audit "create" "ssh" "$user" "ip=${limit_ip} days=${days} quota=${quota_gb}GB"
  return 0
}

# Terminate active processes/sockets for a single SSH/Dropbear/OpenVPN user
# WITHOUT restarting dropbear.service (preserving all other connected users).
acc_ssh_kill_user() {
  local user="$1"
  [[ -z "$user" || "$user" == "root" ]] && return 0
  pkill -KILL -u "$user" 2>/dev/null || true

  # Dropbear forks child processes as root when PermitTTY=no/-w/-g; find child PIDs from auth log
  local auth_src=""
  if [[ -s /var/log/secure ]]; then auth_src="/var/log/secure"
  elif [[ -s /var/log/auth.log ]]; then auth_src="/var/log/auth.log"
  fi
  if [[ -n "$auth_src" ]]; then
    local dpids p
    dpids=$(tail -n 2000 "$auth_src" 2>/dev/null | awk -v u="'${user}'" '
      /dropbear\[/ && /Password auth succeeded/ && index($0, u) {
        pid=$0; sub(/.*dropbear\[/,"",pid); sub(/\].*/,"",pid);
        if (pid ~ /^[0-9]+$/) print pid
      }
    ' | sort -u)
    for p in $dpids; do
      # Never kill master listener PID (PPID 1)
      local ppid comm
      ppid=$(awk '/^PPid:/ {print $2}' "/proc/${p}/status" 2>/dev/null)
      comm=$(cat "/proc/${p}/comm" 2>/dev/null)
      if [[ "$comm" == "dropbear" && -n "$ppid" && "$ppid" != "1" ]]; then
        kill -9 "$p" 2>/dev/null || true
      fi
    done
  fi
}

acc_ssh_delete() {
  local user="$1"
  db_account_exists "ssh" "$user" || { err "account not found"; return 4; }
  acc_ssh_kill_user "$user"
  id "$user" &>/dev/null && userdel --force "$user" >/dev/null 2>&1
  db_set_status "ssh" "$user" "deleted"
  db_audit "delete" "ssh" "$user" ""
  return 0
}

acc_ssh_suspend() {
  local user="$1" reason="${2:-quota}"
  db_account_exists "ssh" "$user" || return 4
  if id "$user" &>/dev/null; then
    usermod -L "$user" >/dev/null 2>&1 || true
    chage -E 0 "$user" >/dev/null 2>&1 || true
  fi
  acc_ssh_kill_user "$user"
  db_set_status "ssh" "$user" "suspended"
  db_audit "suspend" "ssh" "$user" "$reason"
  return 0
}

acc_ssh_unsuspend() {
  local user="$1"
  local exp_epoch
  exp_epoch=$(db_query "SELECT expired_at FROM accounts WHERE protocol='ssh' AND username='$(sql_escape "$user")' AND status!='deleted' LIMIT 1;")
  [[ -z "$exp_epoch" ]] && return 4
  if id "$user" &>/dev/null; then
    usermod -U "$user" >/dev/null 2>&1 || true
    chage -E "$(date -d "@${exp_epoch}" +%Y-%m-%d)" "$user" >/dev/null 2>&1 || true
  fi
  db_set_status "ssh" "$user" "active"
  db_audit "unsuspend" "ssh" "$user" ""
  return 0
}

acc_ssh_renew() {
  local user="$1" days="$2"
  local cur now base new
  cur=$(db_get_field "ssh" "$user" "expired_at")
  [[ -z "$cur" ]] && { err "account not found"; return 4; }
  now=$(date +%s)
  base=$cur; (( cur < now )) && base=$now
  new=$(( base + days * 86400 ))
  db_set_expired "ssh" "$user" "$new"
  if id "$user" &>/dev/null; then
    usermod -U "$user" 2>/dev/null || true
    chage -E "$(date -d "@${new}" +%Y-%m-%d)" "$user" 2>/dev/null
  fi
  db_audit "renew" "ssh" "$user" "+${days}d"
  echo "$new"
  return 0
}

# ---- NOOBZVPN ACCOUNTS ----
acc_noobz_create() {
  local user="$1" pass="$2" limit_dev="${3:-0}" days="${4:-30}" quota_gb="${5:-0}"
  local exp_epoch quota_bytes=0
  exp_epoch=$(( $(date +%s) + days * 86400 ))
  if [[ -n "$quota_gb" && "$quota_gb" =~ ^[0-9]+$ && "$quota_gb" -gt 0 ]]; then
    quota_bytes=$(( quota_gb * 1073741824 ))
  fi

  if db_account_exists "noobz" "$user"; then
    err "username '$user' already exists"; return 9
  fi

  if command -v noobzvpns &>/dev/null; then
    local cmd=("noobzvpns" "add" "$user" "-p" "$pass" "-e" "$days")
    (( quota_gb > 0 )) && cmd+=("-b" "$quota_gb")
    (( limit_dev > 0 )) && cmd+=("-d" "$limit_dev")
    "${cmd[@]}" >/dev/null 2>&1 || true
  fi

  db_insert_account "noobz" "$user" "$pass" "$quota_bytes" "$limit_dev" "$exp_epoch"
  db_audit "create" "noobz" "$user" "devices=${limit_dev} days=${days} quota=${quota_gb}GB"
  return 0
}

acc_noobz_delete() {
  local user="$1"
  db_account_exists "noobz" "$user" || { err "account not found"; return 4; }
  if command -v noobzvpns &>/dev/null; then
    noobzvpns remove "$user" >/dev/null 2>&1 || true
  fi
  db_set_status "noobz" "$user" "deleted"
  db_audit "delete" "noobz" "$user" ""
  return 0
}

acc_noobz_suspend() {
  local user="$1" reason="${2:-limit}"
  db_account_exists "noobz" "$user" || return 4
  if command -v noobzvpns &>/dev/null; then
    noobzvpns block "$user" >/dev/null 2>&1 || true
  fi
  db_set_status "noobz" "$user" "suspended"
  db_audit "suspend" "noobz" "$user" "$reason"
  return 0
}

acc_noobz_renew() {
  local user="$1" days="$2"
  local cur now base new
  cur=$(db_get_field "noobz" "$user" "expired_at")
  [[ -z "$cur" ]] && { err "account not found"; return 4; }
  now=$(date +%s)
  base=$cur; (( cur < now )) && base=$now
  new=$(( base + days * 86400 ))
  db_set_expired "noobz" "$user" "$new"
  if command -v noobzvpns &>/dev/null; then
    noobzvpns edit "$user" -e "$days" >/dev/null 2>&1 || noobzvpns renew "$user" >/dev/null 2>&1 || true
  fi
  db_audit "renew" "noobz" "$user" "+${days}d"
  echo "$new"
  return 0
}

acc_noobz_recover() {
  local user="$1" days="${2:-30}"
  db_account_exists "noobz" "$user" || return 4
  local pass quota_bytes limit_dev exp_epoch quota_gb
  pass=$(db_get_field "noobz" "$user" "secret")
  quota_bytes=$(db_get_field "noobz" "$user" "quota_bytes")
  limit_dev=$(db_get_field "noobz" "$user" "limit_ip")
  quota_gb=0
  if [[ -n "$quota_bytes" && "$quota_bytes" -gt 0 ]]; then
    quota_gb=$(( quota_bytes / 1073741824 ))
  fi
  exp_epoch=$(( $(date +%s) + days * 86400 ))

  if command -v noobzvpns &>/dev/null; then
    # Unblock if currently blocked/suspended; otherwise add user afresh
    if ! noobzvpns unblock "$user" >/dev/null 2>&1; then
      local cmd=("noobzvpns" "add" "$user" "-p" "$pass" "-e" "$days")
      (( quota_gb > 0 )) && cmd+=("-b" "$quota_gb")
      (( limit_dev > 0 )) && cmd+=("-d" "$limit_dev")
      "${cmd[@]}" >/dev/null 2>&1 || true
    else
      local cmd=("noobzvpns" "edit" "$user" "-e" "$days")
      (( quota_gb > 0 )) && cmd+=("-b" "$quota_gb")
      (( limit_dev > 0 )) && cmd+=("-d" "$limit_dev")
      "${cmd[@]}" >/dev/null 2>&1 || true
    fi
  fi

  db_set_expired "noobz" "$user" "$exp_epoch"
  db_set_status "noobz" "$user" "active"
  db_audit "recover" "noobz" "$user" "+${days}d"
  return 0
}

noobz_print_cli() {
  local user="$1" pass="$2" dev_disp="$3" exp_disp="$4" quota_disp="${5:-Unlimited}" title="${6:-NOOBZVPN ACCOUNT}"
  local d; d=$(get_domain); local sip; sip=$(get_ip)
  ui_header "$title"
  ui_kv "Username"     "$user" "$CYAN"
  ui_kv "Password"     "$pass" "$CYAN"
  ui_kv "Host / IP"    "${d} / ${sip}"
  ui_kv "Quota"        "$quota_disp"
  ui_kv "Limit Device" "$dev_disp"
  ui_kv "Expired"      "$exp_disp"
  ui_rule
  ui_kv "Port TCP"     "8585"
  ui_kv "Port HTTP"    "80, 8080"
  ui_kv "Port TLS"     "443"
  ui_kv "Identifier"   "risqinf"
  ui_kv "Path"         "/noobz"
  ui_rule
  echo -e " ${WHITE}Payload (WS) :${NC}"
  echo -e " ${GREEN}GET /noobz HTTP/1.1[crlf]Host: ${d}[crlf]Upgrade: websocket[crlf][crlf]${NC}"
  echo -e " ${WHITE}Config String :${NC}"
  echo -e " ${GREEN}${d}:8585@${user}:${pass}${NC}"
  ui_foot
}

noobz_tg_text() {
  local user="$1" pass="$2" dev_disp="$3" exp_disp="$4" quota_disp="${5:-Unlimited}" title="${6:-NOOBZVPN ACCOUNT}"
  local d; d=$(get_domain); local sip; sip=$(get_ip)
  local eu ed ep eq edev ex
  eu=$(html_escape "$user"); ed=$(html_escape "$d")
  ep=$(html_escape "$pass"); eq=$(html_escape "$quota_disp")
  edev=$(html_escape "$dev_disp"); ex=$(html_escape "$exp_disp")
  cat <<EOF
<b>━━━━━━━━━━━━━━━━━━━━━━━━━━━</b>
<b>      ⊹ $(html_escape "$title") ⊹</b>
<b>━━━━━━━━━━━━━━━━━━━━━━━━━━━</b>
<b>Username     :</b> <code>${eu}</code>
<b>Password     :</b> <code>${ep}</code>
<b>Host / IP    :</b> <code>${ed}</code> / <code>${sip}</code>
<b>Quota        :</b> <code>${eq}</code>
<b>Limit Device :</b> <code>${edev}</code>
<b>Expired      :</b> <code>${ex}</code>
<b>━━━━━━━━━━━━━━━━━━━━━━━━━━━</b>
<b>Port TCP     :</b> <code>8585</code>
<b>Port HTTP    :</b> <code>80, 8080</code>
<b>Port TLS     :</b> <code>443</code>
<b>Identifier   :</b> <code>risqinf</code>
<b>Path         :</b> <code>/noobz</code>
<b>━━━━━━━━━━━━━━━━━━━━━━━━━━━</b>
<b>Payload :</b>
<code>GET /noobz HTTP/1.1[crlf]Host: ${ed}[crlf]Upgrade: websocket[crlf][crlf]</code>
<b>━━━━━━━━━━━━━━━━━━━━━━━━━━━</b>
<b>Config String :</b>
<code>${ed}:8585@${eu}:${ep}</code>
<b>━━━━━━━━━━━━━━━━━━━━━━━━━━━</b>
EOF
}

# ---- SHARED DISPLAY HELPERS ----
# Full SSH account detail to the terminal. Args: user pass ip_disp exp_disp [quota_disp] [title]
ssh_print_cli() {
  local user="$1" pass="$2" ip_disp="$3" exp_disp="$4"
  local quota_disp="Unlimited" title="SSH ACCOUNT"
  if [[ $# -ge 6 ]]; then
    quota_disp="$5"
    title="$6"
  elif [[ $# -eq 5 ]]; then
    if [[ "$5" == *"GB"* || "$5" == *"MB"* || "$5" == "Unlimited" ]]; then
      quota_disp="$5"
    else
      title="$5"
    fi
  fi
  local d; d=$(get_domain); local sip; sip=$(get_ip)
  ui_header "$title"
  ui_kv "Username"  "$user" "$CYAN"
  ui_kv "Password"  "$pass" "$CYAN"
  ui_kv "Host / IP" "${d} / ${sip}"
  ui_kv "Quota"     "$quota_disp"
  ui_kv "Limit IP"  "$ip_disp"
  ui_kv "Expired"   "$exp_disp"
  ui_rule
  ui_kv "OpenSSH"   "22, 3303"
  ui_kv "Dropbear"  "109, 143"
  ui_kv "WS HTTP"   "80, 8080, 8888"
  ui_kv "WS TLS"    "443, 8443"
  ui_kv "SSH SSL"   "443, 8443"
  ui_kv "Squid"     "3128"
  ui_kv "BadVPN"    "7300 (UDPGW)"
  ui_kv "OpenVPN"   "1194 (TCP/UDP)"
  if [[ -s /etc/slowdns/server.pub && -s /etc/slowdns/nameserver ]]; then
    local dns_ns; dns_ns=$(cat /etc/slowdns/nameserver 2>/dev/null | tr -d '\r\n')
    local dns_pub; dns_pub=$(cat /etc/slowdns/server.pub 2>/dev/null | tr -d '\r\n')
    if [[ -n "$dns_ns" && -n "$dns_pub" ]]; then
      ui_rule
      ui_kv "SlowDNS NS"  "$dns_ns"
      ui_kv "SlowDNS Pub" "$dns_pub"
    fi
  fi
  ui_rule
  echo -e " ${WHITE}Config HTTP Custom :${NC}"
  echo -e " ${GREEN}${d}:1-65535@${user}:${pass}${NC}"
  ui_rule
  echo -e " ${WHITE}Payload (WS) :${NC}"
  echo -e " ${GREEN}GET /ssh HTTP/1.1[crlf]Host: ${d}[crlf]Upgrade: websocket[crlf][crlf]${NC}"
  ui_rule
  ui_kv "OVPN TCP"    "https://${d}/risqinf/openvpn/tcp.ovpn"
  ui_foot
}

# Full SSH account detail as Telegram HTML. Args: user pass ip_disp exp_disp [quota_disp] [title]
ssh_tg_text() {
  local user="$1" pass="$2" ip_disp="$3" exp_disp="$4"
  local quota_disp="Unlimited" title="SSH ACCOUNT"
  if [[ $# -ge 6 ]]; then
    quota_disp="$5"
    title="$6"
  elif [[ $# -eq 5 ]]; then
    if [[ "$5" == *"GB"* || "$5" == *"MB"* || "$5" == "Unlimited" ]]; then
      quota_disp="$5"
    else
      title="$5"
    fi
  fi
  local d; d=$(get_domain); local sip; sip=$(get_ip)
  local slowdns_tg=""
  if [[ -s /etc/slowdns/server.pub && -s /etc/slowdns/nameserver ]]; then
    local dns_ns dns_pub
    dns_ns=$(cat /etc/slowdns/nameserver 2>/dev/null | tr -d '\r\n')
    dns_pub=$(cat /etc/slowdns/server.pub 2>/dev/null | tr -d '\r\n')
    if [[ -n "$dns_ns" && -n "$dns_pub" ]]; then
      dns_ns=$(html_escape "$dns_ns")
      dns_pub=$(html_escape "$dns_pub")
      slowdns_tg=$(printf "\n<b>━━━━━━━━━━━━━━━━━━━━━━━━━━━</b>\n<b>SlowDNS (DNSTT) :</b>\n<b>Nameserver :</b> <code>%s</code>\n<b>Public Key :</b> <code>%s</code>" "$dns_ns" "$dns_pub")
    fi
  fi
  cat <<EOF
<b>━━━━━━━━━━━━━━━━━━━━━━━━━━━</b>
<b>      ⊹ ${title} ⊹</b>
<b>━━━━━━━━━━━━━━━━━━━━━━━━━━━</b>
<b>Username  :</b> <code>${user}</code>
<b>Password  :</b> <code>${pass}</code>
<b>Host/IP   :</b> <code>${d}</code> / <code>${sip}</code>
<b>Quota     :</b> <code>${quota_disp}</code>
<b>Limit IP  :</b> <code>${ip_disp}</code>
<b>Expired   :</b> <code>${exp_disp}</code>
<b>━━━━━━━━━━━━━━━━━━━━━━━━━━━</b>
<b>Port OpenSSH :</b> <code>22, 3303</code>
<b>Port Dropbear:</b> <code>109, 143</code>
<b>Port WS HTTP :</b> <code>80, 8080, 8888</code>
<b>Port WS TLS  :</b> <code>443, 8443</code>
<b>Port SSH SSL :</b> <code>443, 8443</code>
<b>Port Squid   :</b> <code>3128</code>
<b>Port BadVPN  :</b> <code>7300</code>
<b>Port OpenVPN :</b> <code>1194 (TCP/UDP)</code>${slowdns_tg}
<b>━━━━━━━━━━━━━━━━━━━━━━━━━━━</b>
<b>Config HTTP Custom :</b>
<code>${d}:1-65535@${user}:${pass}</code>
<b>━━━━━━━━━━━━━━━━━━━━━━━━━━━</b>
<b>Payload :</b>
<code>GET /ssh HTTP/1.1[crlf]Host: ${d}[crlf]Upgrade: websocket[crlf][crlf]</code>
<b>━━━━━━━━━━━━━━━━━━━━━━━━━━━</b>
<b>OVPN TCP :</b> <code>https://${d}/risqinf/openvpn/tcp.ovpn</code>
<b>━━━━━━━━━━━━━━━━━━━━━━━━━━━</b>
EOF
}

# ---- XRAY TELEGRAM MESSAGE BUILDER (shared by add-* and add-bulk) ----
# Build a vmess:// share link (base64 JSON). Args: ps add id port tls [net] [path]
_vmess_link() {
  local ps="$1" add="$2" id="$3" port="$4" tls="$5" net="${6:-ws}" path="${7:-/}"
  jq -nc --arg ps "$ps" --arg add "$add" --arg port "$port" \
        --arg id "$id" --arg host "$add" --arg tls "$tls" \
        --arg net "$net" --arg path "$path" \
        '{v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:"0",net:$net,path:$path,type:"none",host:$host,tls:$tls,sni:$add}' \
    | base64 -w 0 | sed 's/^/vmess:\/\//'
}

# Telegram HTML message for an xray account (vless/vmess/trojan). Every dynamic
# value is HTML-escaped (Telegram HTML parse_mode needs &,<,> escaped; raw '&'
# in vless/trojan links was causing the API to reject the message).
# Args: proto user secret domain quota_disp ip_disp exp_disp [title]
xray_tg_text() {
  local proto="$1" user="$2" secret="$3" domain="$4" quota_disp="$5" ip_disp="$6" exp_disp="$7" title="$8"
  local eu ed es eq ei ex link1 link2
  eu=$(html_escape "$user");       ed=$(html_escape "$domain")
  es=$(html_escape "$secret");     eq=$(html_escape "$quota_disp")
  ei=$(html_escape "$ip_disp");    ex=$(html_escape "$exp_disp")

  case "$proto" in
    vless)
      [[ -z "$title" ]] && title="VLESS ACCOUNT"
      link1=$(html_escape "vless://${secret}@${domain}:443?path=/vless&security=tls&encryption=none&type=ws&host=${domain}&sni=${domain}#${user}")
      link2=$(html_escape "vless://${secret}@${domain}:80?path=/vless&encryption=none&type=ws&host=${domain}#${user}")
      cat <<EOF
<b>━━━━━━━━━━━━━━━━━━━━━━━━━━━</b>
<b>      ⊹ $(html_escape "$title") ⊹</b>
<b>━━━━━━━━━━━━━━━━━━━━━━━━━━━</b>
<b>Remarks   :</b> <code>${eu}</code>
<b>Host/IP   :</b> <code>${ed}</code>
<b>Port TLS  :</b> <code>443</code>
<b>Port HTTP :</b> <code>80</code>
<b>UUID      :</b> <code>${es}</code>
<b>Encryption:</b> <code>none</code>
<b>Network   :</b> <code>ws</code>
<b>Path      :</b> <code>/vless</code>
<b>Quota     :</b> <code>${eq}</code>
<b>Limit IP  :</b> <code>${ei}</code>
<b>Expired   :</b> <code>${ex}</code>
<b>━━━━━━━━━━━━━━━━━━━━━━━━━━━</b>
<b>Link TLS  :</b>
<code>${link1}</code>
<b>━━━━━━━━━━━━━━━━━━━━━━━━━━━</b>
<b>Link HTTP :</b>
<code>${link2}</code>
<b>━━━━━━━━━━━━━━━━━━━━━━━━━━━</b>
EOF
      ;;
    vmess)
      [[ -z "$title" ]] && title="VMESS ACCOUNT"
      link1=$(html_escape "$(_vmess_link "$user" "$domain" "$secret" 443 tls)")
      link2=$(html_escape "$(_vmess_link "$user" "$domain" "$secret" 80 none)")
      cat <<EOF
<b>━━━━━━━━━━━━━━━━━━━━━━━━━━━</b>
<b>      ⊹ $(html_escape "$title") ⊹</b>
<b>━━━━━━━━━━━━━━━━━━━━━━━━━━━</b>
<b>Remarks   :</b> <code>${eu}</code>
<b>Host/IP   :</b> <code>${ed}</code>
<b>Port TLS  :</b> <code>443</code>
<b>Port HTTP :</b> <code>80</code>
<b>UUID      :</b> <code>${es}</code>
<b>AlterId   :</b> <code>0</code>
<b>Network   :</b> <code>ws</code>
<b>Path      :</b> <code>/ (multipath)</code>
<b>Quota     :</b> <code>${eq}</code>
<b>Limit IP  :</b> <code>${ei}</code>
<b>Expired   :</b> <code>${ex}</code>
<b>━━━━━━━━━━━━━━━━━━━━━━━━━━━</b>
<b>Link TLS  :</b>
<code>${link1}</code>
<b>━━━━━━━━━━━━━━━━━━━━━━━━━━━</b>
<b>Link HTTP :</b>
<code>${link2}</code>
<b>━━━━━━━━━━━━━━━━━━━━━━━━━━━</b>
EOF
      ;;
    trojan)
      [[ -z "$title" ]] && title="TROJAN ACCOUNT"
      link1=$(html_escape "trojan://${secret}@${domain}:443?type=ws&security=tls&host=${domain}&path=/trojan&sni=${domain}#${user}")
      cat <<EOF
<b>━━━━━━━━━━━━━━━━━━━━━━━━━━━</b>
<b>      ⊹ $(html_escape "$title") ⊹</b>
<b>━━━━━━━━━━━━━━━━━━━━━━━━━━━</b>
<b>Remarks   :</b> <code>${eu}</code>
<b>Host/IP   :</b> <code>${ed}</code>
<b>Port TLS  :</b> <code>443</code>
<b>Key       :</b> <code>${es}</code>
<b>Network   :</b> <code>ws</code>
<b>Path      :</b> <code>/trojan</code>
<b>Quota     :</b> <code>${eq}</code>
<b>Limit IP  :</b> <code>${ei}</code>
<b>Expired   :</b> <code>${ex}</code>
<b>━━━━━━━━━━━━━━━━━━━━━━━━━━━</b>
<b>Link TLS  :</b>
<code>${link1}</code>
<b>━━━━━━━━━━━━━━━━━━━━━━━━━━━</b>
EOF
      ;;
  esac
}

# ---- XRAY LOGIN MONITOR (shared by cek-vless/vmess/trojan) ----
# Human-readable bytes with one/two-decimal precision (clear + tidy).
human_bytes() {
  local b="${1:-0}"
  [[ "$b" =~ ^[0-9]+$ ]] || b=0
  if   (( b >= 1099511627776 )); then awk -v x="$b" 'BEGIN{printf "%.2f TB", x/1099511627776}'
  elif (( b >= 1073741824 ));    then awk -v x="$b" 'BEGIN{printf "%.2f GB", x/1073741824}'
  elif (( b >= 1048576 ));       then awk -v x="$b" 'BEGIN{printf "%.2f MB", x/1048576}'
  elif (( b >= 1024 ));          then awk -v x="$b" 'BEGIN{printf "%.2f KB", x/1024}'
  else echo "${b} B"; fi
}

# Xray stats API endpoint (StatsService on the dokodemo "api" inbound).
XRAY_API="${XRAY_API:-127.0.0.1:10085}"

# Read an xray per-user traffic counter (uplink+downlink) in bytes.
# Xray names per-user counters as: user>>>{email}>>>traffic>>>{uplink|downlink}
# Args: <user> [reset]   -> pass the literal word "reset" to zero counters.
# Echoes a non-negative integer (0 when stats are unavailable).
xray_user_bytes() {
  local user="$1" reset="${2:-}" total=0 dir v
  local xb="${AS_XRAY_BIN:-xray}"; [[ -x "$xb" ]] || xb="xray"
  local -a rflag=(); [[ "$reset" == "reset" ]] && rflag=(-reset)
  for dir in uplink downlink; do
    v=$("$xb" api stats --server="$XRAY_API" \
          -name "user>>>${user}>>>traffic>>>${dir}" "${rflag[@]}" 2>/dev/null \
        | grep -w value | awk '{print $2}' | tr -d '", ')
    [[ "$v" =~ ^[0-9]+$ ]] && total=$(( total + v ))
  done
  echo "$total"
}

# Accumulate live traffic into used_bytes and enforce quota for one protocol.
# Reads (and RESETS) each active user's counters, adds the delta to the DB,
# then suspends users that exceeded a finite quota. Unlimited users
# (quota_bytes=0) are still accounted; they are simply never suspended.
# Arg: protocol (vless|vmess|trojan)
xray_account_proto() {
  local proto="$1" user quota used delta
  local xb="${AS_XRAY_BIN:-xray}"; [[ -x "$xb" ]] || xb="xray"

  # Pre-fetch non-zero user traffic counters in 1 single statsquery call (no reset yet)
  # so idle accounts cost zero subprocess forks on 1-vCPU VPS nodes.
  declare -A NONZERO_USERS=()
  local sq_out u_name u_val
  sq_out=$("$xb" api statsquery --server="$XRAY_API" -pattern "user>>>" 2>/dev/null)
  if [[ -n "$sq_out" ]] && command -v jq >/dev/null 2>&1; then
    while IFS='|' read -r u_name u_val; do
      [[ -n "$u_name" && "$u_val" =~ ^[0-9]+$ ]] && (( u_val > 0 )) && NONZERO_USERS[$u_name]=1
    done < <(echo "$sq_out" | jq -r '.stat[]? | select(.value != null and (.value|tonumber) > 0) | ((.name | split(">>>")[1]) + "|" + (.value|tostring))' 2>/dev/null)
  fi

  local sql_batch=""
  local -a to_suspend=()

  while IFS='|' read -r user quota used; do
    [[ -z "$user" ]] && continue
    delta=0
    if [[ ${#NONZERO_USERS[@]} -eq 0 && -z "$sq_out" ]]; then
      # Fallback if statsquery output format differed
      delta=$(xray_user_bytes "$user" reset)
    elif [[ -n "${NONZERO_USERS[$user]:-}" ]]; then
      delta=$(xray_user_bytes "$user" reset)
    fi

    if [[ "$delta" =~ ^[0-9]+$ ]] && (( delta > 0 )); then
      sql_batch+="UPDATE accounts SET used_bytes = used_bytes + ${delta}, updated_at = strftime('%s','now') WHERE protocol='${proto}' AND username='$(sql_escape "$user")';"$'\n'
      used=$(( ${used:-0} + delta ))
    fi

    if [[ "$quota" =~ ^[0-9]+$ ]] && (( quota > 0 )) && (( used >= quota )); then
      to_suspend+=("$user")
    fi
  done < <(db_query "SELECT username, quota_bytes, used_bytes FROM accounts
                     WHERE protocol='${proto}' AND status='active';")

  if [[ -n "$sql_batch" ]]; then
    db_exec "BEGIN TRANSACTION;"$'\n'"${sql_batch}COMMIT;"
  fi

  for user in "${to_suspend[@]}"; do
    acc_xray_suspend "$proto" "$user" "quota"
    tg_send "<b>[ ${proto^^} QUOTA EXCEEDED ]</b>%0AUsername: <code>${user}</code>%0AStatus: suspended"
  done
}

# Boxed per-account login monitor for an xray protocol.
# Counts distinct CLIENT IPs seen in the most recent login window so a single
# client that reconnected several times is not counted multiple times, and shows
# exact transport protocol, ISP, GeoIP location, and accessed apps/domains.
# Arg: protocol (vless|vmess|trojan)
xray_cek_monitor() {
  local proto="$1"
  local LOG="/var/log/xray/access.log"
  local RECENT_SECS=180          # only connections within the last 3 minutes

  clear
  ui_header "${proto^^} LOGIN MONITOR"

  local cutoff; cutoff=$(date +%s)

  local any=0
  while IFS='|' read -r user limit qb used exp; do
    [[ -z "$user" ]] && continue

    # Distinct client IPs + inbound transport tags from RECENT accepted log lines
    local parsed ips tags cnt
    parsed=$(tail -n 4000 "$LOG" 2>/dev/null | awk -v u="email: ${user}" -v cutoff="$cutoff" -v win="$RECENT_SECS" '
      index($0, u) && /accepted/ {
        split($1, d, "/");
        t=$2; sub(/\..*/, "", t); split(t, c, ":");
        ep=mktime(d[1]" "d[2]" "d[3]" "c[1]" "c[2]" "c[3]);
        if (ep <= 0) next;
        if (cutoff - ep <= win) {
          ipp=""; tag="";
          for (i=1; i<=NF; i++) {
            if ($i=="from" && (i+1)<=NF) ipp=$(i+1);
            if ($i ~ /^\[.*\]$/) { tag=$i; gsub(/^\[|\]$/, "", tag); }
          }
          sub(/:[0-9]+$/, "", ipp);
          if (ipp ~ /^[0-9a-fA-F:.]+$/ && ipp != "" && ipp != "127.0.0.1") seen_ip[ipp]=1;
          if (tag != "" && tag != "api") seen_tag[tag]=1;
        }
      }
      END {
        for (k in seen_ip) print "IP|" k;
        for (t in seen_tag) print "TAG|" t;
      }
    ' 2>/dev/null)

    ips=$(printf '%s\n' "$parsed" | awk -F'|' '$1=="IP"{print $2}' | sort -u)
    tags=$(printf '%s\n' "$parsed" | awk -F'|' '$1=="TAG"{print $2}' | sort -u | paste -sd ', ' -)

    cnt=0
    [[ -n "$ips" ]] && cnt=$(printf '%s\n' "$ips" | grep -c .)
    [[ "$cnt" -le 0 ]] && continue

    local limd usedd quotad ipcol live used_total apps_used
    live=$(xray_user_bytes "$user")
    used_total=$(( ${used:-0} + ${live:-0} ))
    [[ "$limit" == "0" ]] && limd="Unlimited" || limd="$limit"
    usedd=$(human_bytes "$used_total")
    if [[ "$qb" == "0" ]]; then quotad="Unlimited"; else quotad=$(human_bytes "$qb"); fi
    ipcol="$GREEN"
    if [[ "$limd" != "Unlimited" && "$cnt" -gt "$limit" ]]; then ipcol="$RED"; fi
    [[ -z "$tags" ]] && tags="${proto}-ws"
    apps_used=$(detect_xray_user_apps "$user")

    any=1
    ui_rule
    ui_kv "Username" "$user" "$CYAN"
    ui_kv "Protocol" "${tags^^}" "$PINK"
    ui_kv "Login IP" "${cnt} / ${limd} IP" "$ipcol"
    ui_kv "Bandwidth" "${usedd} / ${quotad}"
    ui_kv "Expired" "$exp"
    [[ -n "$apps_used" ]] && ui_kv "Apps/Domain" "$apps_used" "$YELLOW"
    printf " ${WHITE}%-12s${NC} :\n" "Active IPs"
    while read -r one; do
      [[ -z "$one" ]] && continue
      local geo asn_isp loc
      geo=$(lookup_ip_geo "$one")
      asn_isp="${geo%%|*}"
      loc="${geo#*|}"
      echo -e "                ${GREEN}- ${one}${NC} ${YELLOW}[ ${asn_isp} ]${NC}"
      [[ -n "$loc" && "$loc" != "Unknown Location" ]] && echo -e "                  ${CYAN}${loc}${NC}"
    done <<< "$ips"
    if [[ "$ipcol" == "$RED" ]]; then
      echo -e "                ${RED}[!] EXCEEDS IP LIMIT${NC}"
    fi
  done < <(db_query "SELECT username, limit_ip, quota_bytes, used_bytes,
                            datetime(expired_at,'unixepoch','localtime')
                     FROM accounts WHERE protocol='${proto}' AND status='active'
                     ORDER BY username;")

  ui_rule
  [[ $any -eq 0 ]] && echo -e " ${YELLOW}No ${proto^^} users with active connections.${NC}"
  ui_foot
}
