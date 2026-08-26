#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: SSH live session monitor (WS bandwidth correlation)
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
# Correlation:
#   ssh-ws.log [CONNECT]  -> sessionID, real client IP, proxy-port
#   ssh-ws.log [MONITOR]  -> live TX / RX / Total / uptime per session
#   /var/log/secure       -> proxy-port -> SSH username (dropbear/sshd auth)
#   ss (live sockets)     -> proxy-port still connected to dropbear:109
# ========================================================
. /usr/local/sbin/lib/account.sh

db_init

# --- 1) proxy-port -> username map (last auth per port wins) ---
declare -A PORT2USER PORT2IP PORT2PID

WSLOG="/var/log/ssh-ws.log"

get_auth_logs() {
  if [[ -f /var/log/secure && -s /var/log/secure ]]; then
    cat /var/log/secure 2>/dev/null
  elif [[ -f /var/log/auth.log && -s /var/log/auth.log ]]; then
    cat /var/log/auth.log 2>/dev/null
  elif command -v journalctl >/dev/null 2>&1; then
    journalctl -u dropbear -u ssh -u sshd --since "1 day ago" --no-pager 2>/dev/null
  fi
}

while read -r port user ip pid; do
  if [[ -n "$port" && -n "$user" ]]; then
    PORT2USER[$port]="$user"
    PORT2IP[$port]="$ip"
    PORT2PID[$port]="$pid"
  fi
done < <(
  get_auth_logs | awk '
    /dropbear\[/ && /Password auth succeeded/ {
      pid=$0; sub(/.*dropbear\[/,"",pid); sub(/\].*/,"",pid);
      f=$NF; n=split(f,a,":"); ip=a[1]; port=a[2]; u="";
      for(i=1;i<=NF;i++){ if($i ~ /^\047.*\047$/){ u=$i; gsub(/\047/,"",u) } }
      if(port ~ /^[0-9]+$/ && u!="") print port, u, ip, pid
    }
    /sshd\[/ && /Accepted / {
      pid=$0; sub(/.*sshd\[/,"",pid); sub(/\].*/,"",pid);
      u=""; port=""; ip="";
      for(i=1;i<=NF;i++){ if($i=="for") u=$(i+1); if($i=="port") port=$(i+1); if($i=="from") ip=$(i+1) }
      if(port ~ /^[0-9]+$/ && u!="") print port, u, ip, pid
    }
  ' 2>/dev/null | sort -u
)

declare -A S_PORT S_CIP S_TX S_RX S_TOT S_UP S_TS ACTIVEPORT

# --- 2) Try querying ssh-ws HTTP API (port 8081) if available ---
if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  ws_json=$(curl -s --connect-timeout 1 http://127.0.0.1:8081/api/sessions 2>/dev/null)
  if [[ -n "$ws_json" ]]; then
    while IFS='|' read -r pport cip user up tx rx tot; do
      [[ -z "$pport" ]] && continue
      ACTIVEPORT[$pport]=1
      S_CIP[$pport]="$cip"
      [[ -n "$user" && "$user" != "detecting..." ]] && PORT2USER[$pport]="$user"
      S_UP[$pport]="$up"
      S_TX[$pport]="$tx"
      S_RX[$pport]="$rx"
      S_TOT[$pport]="$tot"
    done < <(echo "$ws_json" | jq -r '.data.sessions[]? | "\(.proxy_to_ssh_port)|\(.real_client_ip)|\(.username)|\(.duration)|\(.tx_formatted)|\(.rx_formatted)|\(.total_formatted)"' 2>/dev/null)
  fi
fi

# --- 3) Parse ssh-ws.log if API returned no active sessions ---
if [[ ${#ACTIVEPORT[@]} -eq 0 && -f "$WSLOG" ]]; then
  while IFS='|' read -r pport cip tx rx tot up ts; do
    [[ -z "$pport" ]] && continue
    S_PORT[$pport]=1
    S_CIP[$pport]="$cip"; S_TX[$pport]="$tx"; S_RX[$pport]="$rx"
    S_TOT[$pport]="$tot"; S_UP[$pport]="$up"; S_TS[$pport]="$ts"
  done < <(
    awk '
      function sid_from_line(i,t){
        for(i=1;i<=NF;i++){
          t=$i;
          if(t ~ /^\[/ && t !~ /CONNECT/ && t !~ /MONITOR/){ gsub(/[][]/,"",t); return t }
        }
        return "";
      }
      function client_ip(i){
        for(i=1;i<=NF;i++){ if($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+$/) return $i }
        return "";
      }
      {
        line=$0; gsub(/\033\[[0-9;]*m/,"",line); $0=line;
      }
      /\[CONNECT\]/ && /proxy-port:/ {
        s=sid_from_line(); if(s==""){ next }
        pp=$0; sub(/.*proxy-port:/,"",pp); gsub(/[^0-9]/,"",pp);
        ip=client_ip();
        SIDPP[s]=pp; if(ip!="") SIDCIP[s]=ip; SIDTS[s]=$1" "$2;
        next;
      }
      /\[MONITOR\]/ {
        s=sid_from_line(); if(s==""){ next }
        tx=""; rx=""; tot=""; upv="";
        for(i=1;i<=NF;i++){
          if($i ~ /^up:/)    upv=substr($i,4);
          if($i ~ /^TX:/)    tx=substr($i,4)" "$(i+1);
          if($i ~ /^RX:/)    rx=substr($i,4)" "$(i+1);
          if($i ~ /^Total:/) tot=substr($i,7)" "$(i+1);
        }
        if(tx!="")  SIDTX[s]=tx;
        if(rx!="")  SIDRX[s]=rx;
        if(tot!="") SIDTOT[s]=tot;
        if(upv!="") SIDUP[s]=upv;
        ip=client_ip(); if(ip!="") SIDCIP[s]=ip;
        SIDTS[s]=$1" "$2;
        next;
      }
      END {
        for(s in SIDPP){
          pp=SIDPP[s];
          print pp"|"SIDCIP[s]"|"SIDTX[s]"|"SIDRX[s]"|"SIDTOT[s]"|"SIDUP[s]"|"SIDTS[s]
        }
      }
    ' "$WSLOG" 2>/dev/null
  )

  LIVE_WINDOW=120
  now_epoch=$(date +%s)
  for pport in "${!S_PORT[@]}"; do
    ts="${S_TS[$pport]}"
    [[ -z "$ts" ]] && continue
    e=$(date -d "$ts" +%s 2>/dev/null) || continue
    [[ -z "$e" ]] && continue
    if (( now_epoch - e <= LIVE_WINDOW )); then
      ACTIVEPORT[$pport]=1
    fi
  done
fi

# --- 4) FALLBACK: jika ssh-ws.log / API tidak ada atau tidak ada sesi aktif,
#    deteksi koneksi live dari ss (socket) + PORT2USER dari auth log.
if [[ ${#ACTIVEPORT[@]} -eq 0 ]]; then
  DROPBEAR_PORT=$(systemctl cat dropbear 2>/dev/null | grep -oP '(?<=-p )\d+' | head -1)
  DROPBEAR_PORT=${DROPBEAR_PORT:-109}

  while IFS= read -r ssline; do
    src_port=$(echo "$ssline" | awk -v dport="$DROPBEAR_PORT" '{
      for(i=1;i<=NF;i++){
        if($i ~ ":"dport"$"){
          if(i>1 && $(i-1) ~ /^[0-9.]+:[0-9]+$/){
            n=split($(i-1),a,":"); print a[n]; exit
          }
          if(i<NF && $(i+1) ~ /^[0-9.]+:[0-9]+$/){
            n=split($(i+1),a,":"); print a[n]; exit
          }
        }
      }
    }')
    [[ "$src_port" =~ ^[0-9]+$ ]] && ACTIVEPORT[$src_port]=1
  done < <(ss -tn state established 2>/dev/null | grep ":${DROPBEAR_PORT}$\|:${DROPBEAR_PORT} ")
fi

clear
ui_header "SSH LIVE SESSION MONITOR"

declare -A USER_SESS
total_live=0

# Iterate active proxy-ports, correlate to user + bandwidth.
for pport in "${!ACTIVEPORT[@]}"; do
  user="${PORT2USER[$pport]}"
  [[ -z "$user" ]] && user="(detecting)"
  
  cip="${S_CIP[$pport]}"
  cip="${cip%%:*}"
  if [[ -z "$cip" || "$cip" == "(detecting)" ]]; then
    cip="${PORT2IP[$pport]}"
    [[ "$cip" == "127.0.0.1" ]] && cip="127.0.0.1 (SSL/Direct)"
    [[ -z "$cip" ]] && cip="(direct)"
  fi

  up="${S_UP[$pport]}"
  if [[ -z "$up" || "$up" == "-" ]]; then
    cpid="${PORT2PID[$pport]}"
    if [[ -n "$cpid" && -d "/proc/$cpid" ]]; then
      up=$(ps -p "$cpid" -o etime= 2>/dev/null | tr -d ' ')
    fi
    [[ -z "$up" ]] && up="-"
  fi

  tx="${S_TX[$pport]:--}"; rx="${S_RX[$pport]:--}"; tot="${S_TOT[$pport]:--}"
  if [[ "$tx" == "-" && "$rx" == "-" ]]; then
    bw_display="Live (Direct/SSL)"
  else
    bw_display="TX ${tx} | RX ${rx} | Total ${tot}"
  fi

  USER_SESS[$user]=$(( ${USER_SESS[$user]:-0} + 1 ))
  total_live=$((total_live+1))
  ui_rule
  ui_kv "Username"  "$user" "$CYAN"
  ui_kv "Client IP" "$cip"
  ui_kv "Uptime"    "$up"
  ui_kv "Bandwidth" "$bw_display"
done

if [[ $total_live -eq 0 ]]; then
  ui_rule
  echo -e " ${YELLOW}No active SSH sessions.${NC}"
fi

ui_rule
echo -e " ${WHITE}PER-USER SESSIONS (vs IP limit)${NC}"
ui_rule
shown_users=0
while IFS='|' read -r u limit; do
  [[ -z "$u" ]] && continue
  cnt=${USER_SESS[$u]:-0}
  # Only show usernames that actually have an active connection.
  [[ "$cnt" -le 0 ]] && continue
  col="$GREEN"
  if [[ "$limit" == "0" ]]; then
    limd="Unlimited"
  else
    limd="$limit"
    [[ "$cnt" -gt "$limit" ]] && col="$RED"
  fi
  printf " ${WHITE}%-14s${NC} ${col}%s / %s${NC}\n" "$u" "$cnt" "$limd"
  shown_users=$((shown_users+1))
done < <(db_query "SELECT username, limit_ip FROM accounts WHERE protocol='ssh' AND status='active' ORDER BY username;")
if [[ $shown_users -eq 0 ]]; then
  echo -e " ${YELLOW}No users with active connections.${NC}"
fi
ui_rule
echo -e " Total live sessions : ${GREEN}${total_live}${NC}"
ui_foot
ui_back
menu

