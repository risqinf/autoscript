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

to_bytes() {
  local s="$1" num unit
  [[ -z "$s" || "$s" == "-" ]] && { echo 0; return; }
  num=$(echo "$s" | awk '{print $1}')
  unit=$(echo "$s" | awk '{print toupper($2)}')
  case "$unit" in
    TB) awk -v n="$num" 'BEGIN{printf "%.0f", n*1099511627776}' ;;
    GB) awk -v n="$num" 'BEGIN{printf "%.0f", n*1073741824}' ;;
    MB) awk -v n="$num" 'BEGIN{printf "%.0f", n*1048576}' ;;
    KB) awk -v n="$num" 'BEGIN{printf "%.0f", n*1024}' ;;
    *)  echo "${num%.*}" ;;
  esac
}

clear
ui_header "SSH LIVE SESSION MONITOR"

declare -A USER_SESSIONS
declare -A USER_SESS_CNT
declare -A USER_LIVE_BYTES
total_live=0

# Iterate active proxy-ports, correlate to user + bandwidth.
for pport in "${!ACTIVEPORT[@]}"; do
  user="${PORT2USER[$pport]}"
  [[ -z "$user" ]] && user="(detecting)"
  
  tx="${S_TX[$pport]:--}"; rx="${S_RX[$pport]:--}"; tot="${S_TOT[$pport]:--}"

  # Ignore unauthenticated handshake ghost probes (TX: 0 B, only received SSH banner)
  if [[ "$user" == "(detecting)" && "$tx" == "0 B" ]]; then
    continue
  fi

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

  USER_SESS_CNT[$user]=$(( ${USER_SESS_CNT[$user]:-0} + 1 ))
  b_tot=$(to_bytes "$tot")
  USER_LIVE_BYTES[$user]=$(( ${USER_LIVE_BYTES[$user]:-0} + b_tot ))
  total_live=$((total_live+1))

  # Record per-session line
  if [[ -n "${USER_SESSIONS[$user]}" ]]; then
    USER_SESSIONS[$user]="${USER_SESSIONS[$user]}"$'\n'"${cip}|${up}|${tx}|${rx}|${tot}"
  else
    USER_SESSIONS[$user]="${cip}|${up}|${tx}|${rx}|${tot}"
  fi
done

any=0
# Loop through active SSH accounts from SQLite first for consistent ordering
while IFS='|' read -r u limit qb used exp; do
  [[ -z "$u" ]] && continue
  cnt=${USER_SESS_CNT[$u]:-0}
  [[ "$cnt" -le 0 ]] && continue

  any=1
  live_b="${USER_LIVE_BYTES[$u]:-0}"
  total_used=$(( ${used:-0} + live_b ))
  usedd=$(human_bytes "$total_used")
  if [[ "$qb" == "0" || -z "$qb" ]]; then quotad="Unlimited"; else quotad=$(human_bytes "$qb"); fi
  [[ "$limit" == "0" ]] && limd="Unlimited" || limd="$limit"
  ipcol="$GREEN"
  if [[ "$limd" != "Unlimited" && "$cnt" -gt "$limit" ]]; then ipcol="$RED"; fi

  ui_rule
  ui_kv "Username" "$u" "$CYAN"
  ui_kv "Login IP" "${cnt} / ${limd} IP" "$ipcol"
  ui_kv "Bandwidth" "${usedd} / ${quotad}"
  ui_kv "Expired" "${exp:--}"
  printf " ${WHITE}%-12s${NC} :\n" "Active IPs"
  while IFS='|' read -r cip up tx rx tot; do
    [[ -z "$cip" ]] && continue
    geo=$(lookup_ip_geo "$cip")
    asn_isp="${geo%%|*}"
    loc="${geo#*|}"
    echo -e "                ${GREEN}- ${cip}${NC} ${YELLOW}[ ${asn_isp} ]${NC}"
    [[ -n "$loc" && "$loc" != "Unknown Location" ]] && echo -e "                  ${CYAN}${loc}${NC}"
    s_info=()
    [[ -n "$up" && "$up" != "-" ]] && s_info+=("Uptime: $up")
    [[ -n "$tx" && "$tx" != "-" ]] && s_info+=("TX $tx")
    [[ -n "$rx" && "$rx" != "-" ]] && s_info+=("RX $rx")
    [[ -n "$tot" && "$tot" != "-" ]] && s_info+=("Total $tot")
    if [[ ${#s_info[@]} -gt 0 ]]; then
      echo -e "                  \033[38;5;244m($(IFS=' | '; echo "${s_info[*]}"))${NC}"
    fi
  done <<< "${USER_SESSIONS[$u]}"
  if [[ "$ipcol" == "$RED" ]]; then
    echo -e "                ${RED}[!] EXCEEDS IP LIMIT${NC}"
  fi
done < <(db_query "SELECT username, limit_ip, quota_bytes, used_bytes,
                          datetime(expired_at,'unixepoch','localtime')
                   FROM accounts WHERE protocol='ssh' AND status='active'
                   ORDER BY username;")

# Also handle any active sessions not in DB accounts (e.g. root or detecting)
for u in "${!USER_SESS_CNT[@]}"; do
  if ! db_account_exists "ssh" "$u"; then
    cnt=${USER_SESS_CNT[$u]:-0}
    [[ "$cnt" -le 0 ]] && continue
    any=1
    live_b="${USER_LIVE_BYTES[$u]:-0}"
    usedd=$(human_bytes "$live_b")

    ui_rule
    ui_kv "Username" "$u" "$YELLOW"
    ui_kv "Login IP" "${cnt} / Unlimited IP" "$GREEN"
    ui_kv "Bandwidth" "${usedd} / Unlimited"
    ui_kv "Expired" "System User"
    printf " ${WHITE}%-12s${NC} :\n" "Active IPs"
    while IFS='|' read -r cip up tx rx tot; do
      [[ -z "$cip" ]] && continue
      geo=$(lookup_ip_geo "$cip")
      asn_isp="${geo%%|*}"
      loc="${geo#*|}"
      echo -e "                ${GREEN}- ${cip}${NC} ${YELLOW}[ ${asn_isp} ]${NC}"
      [[ -n "$loc" && "$loc" != "Unknown Location" ]] && echo -e "                  ${CYAN}${loc}${NC}"
      s_info=()
      [[ -n "$up" && "$up" != "-" ]] && s_info+=("Uptime: $up")
      [[ -n "$tx" && "$tx" != "-" ]] && s_info+=("TX $tx")
      [[ -n "$rx" && "$rx" != "-" ]] && s_info+=("RX $rx")
      [[ -n "$tot" && "$tot" != "-" ]] && s_info+=("Total $tot")
      if [[ ${#s_info[@]} -gt 0 ]]; then
        echo -e "                  \033[38;5;244m($(IFS=' | '; echo "${s_info[*]}"))${NC}"
      fi
    done <<< "${USER_SESSIONS[$u]}"
  fi
done

if [[ $any -eq 0 ]]; then
  ui_rule
  echo -e " ${YELLOW}No active SSH sessions.${NC}"
fi

ui_rule
echo -e " Total live sessions : ${GREEN}${total_live}${NC}"
ui_foot
ui_back
menu

