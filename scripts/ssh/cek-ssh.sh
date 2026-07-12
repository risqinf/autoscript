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

WSLOG="/var/log/ssh-ws.log"
if   [ -e /var/log/secure ];   then SECLOG=/var/log/secure
elif [ -e /var/log/auth.log ]; then SECLOG=/var/log/auth.log
else SECLOG=""
fi

# --- 1) proxy-port -> username map (last auth per port wins) ---
declare -A PORT2USER
if [[ -n "$SECLOG" ]]; then
  while read -r port user; do
    [[ -n "$port" && -n "$user" ]] && PORT2USER[$port]="$user"
  done < <(
    awk '
      /dropbear\[/ && /Password auth succeeded/ {
        f=$NF; n=split(f,a,":"); port=a[n]; u="";
        for(i=1;i<=NF;i++){ if($i ~ /^\047.*\047$/){ u=$i; gsub(/\047/,"",u) } }
        if(port ~ /^[0-9]+$/ && u!="") print port, u
      }
      /sshd\[/ && /Accepted / {
        u=""; port="";
        for(i=1;i<=NF;i++){ if($i=="for") u=$(i+1); if($i=="port") port=$(i+1) }
        if(port ~ /^[0-9]+$/ && u!="") print port, u
      }
    ' "$SECLOG" 2>/dev/null
  )
fi

# --- 2) ssh-ws.log -> per session: proxyport|clientip|tx|rx|total|up|timestamp ---
# Robust parser: strips ANSI color codes and matches [CONNECT]/[MONITOR]
# anywhere on the line, extracting sessionID / client-IP / proxy-port by
# pattern instead of fixed field positions. This survives colorized logs
# and minor spacing differences.
declare -A S_PORT S_CIP S_TX S_RX S_TOT S_UP S_TS
if [[ -f "$WSLOG" ]]; then
  while IFS='|' read -r pport cip tx rx tot up ts; do
    [[ -z "$pport" ]] && continue
    S_PORT[$pport]=1
    S_CIP[$pport]="$cip"; S_TX[$pport]="$tx"; S_RX[$pport]="$rx"
    S_TOT[$pport]="$tot"; S_UP[$pport]="$up"; S_TS[$pport]="$ts"
  done < <(
    awk '
      # session id = first [token] on the line that is not the tag itself
      function sid_from_line(   i,t){
        for(i=1;i<=NF;i++){
          t=$i;
          if(t ~ /^\[/ && t !~ /CONNECT/ && t !~ /MONITOR/){ gsub(/[][]/,"",t); return t }
        }
        return "";
      }
      # client ip = first IPv4:port token on the line (the real client)
      function client_ip(   i){
        for(i=1;i<=NF;i++){ if($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+$/) return $i }
        return "";
      }
      {
        line=$0; gsub(/\033\[[0-9;]*m/,"",line); $0=line;   # strip ANSI, re-split
      }
      /\[CONNECT\]/ && /proxy-port:/ {
        s=sid_from_line(); if(s==""){ next }
        pp=$0; sub(/.*proxy-port:/,"",pp); gsub(/[^0-9]/,"",pp);
        ip=client_ip();
        SIDPP[s]=pp; if(ip!="") SIDCIP[s]=ip; SIDTS[s]=$1" "$2;
        next;
      }
      /\[MONITOR\]/ {
        s=sid_from_line(); if(s==""){ next }   # skips "Active sessions: N" summary
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
fi

# --- 3) decide which proxy-ports are ACTIVE right now ---------------------
# A session is active if it has a fresh [MONITOR] heartbeat or a recent
# [CONNECT] entry in ssh-ws.log.  ssh-ws writes MONITOR every ~10s so a
# 45 s window is safe even if one tick is delayed.
#
# ss-detected ports are deliberately NOT added — they include TIME_WAIT
# sockets from already-closed sessions which would appear as ghost entries
# with no bandwidth/uptime data.
LIVE_WINDOW=45   # seconds
now_epoch=$(date +%s)
declare -A ACTIVEPORT
for pport in "${!S_PORT[@]}"; do
  ts="${S_TS[$pport]}"
  [[ -z "$ts" ]] && continue
  e=$(date -d "$ts" +%s 2>/dev/null) || continue
  [[ -z "$e" ]] && continue
  if (( now_epoch - e <= LIVE_WINDOW )); then
    ACTIVEPORT[$pport]=1
  fi
done

clear
ui_header "SSH LIVE SESSION MONITOR"

declare -A USER_SESS
total_live=0

# Iterate active proxy-ports, correlate to user + bandwidth.
for pport in "${!ACTIVEPORT[@]}"; do
  user="${PORT2USER[$pport]}"
  [[ -z "$user" ]] && user="(detecting)"
  cip="${S_CIP[$pport]}"; cip="${cip%%:*}"; [[ -z "$cip" ]] && cip="(detecting)"
  up="${S_UP[$pport]}";  [[ -z "$up" ]] && up="-"
  tx="${S_TX[$pport]:--}"; rx="${S_RX[$pport]:--}"; tot="${S_TOT[$pport]:--}"
  USER_SESS[$user]=$(( ${USER_SESS[$user]:-0} + 1 ))
  total_live=$((total_live+1))
  ui_rule
  ui_kv "Username"  "$user" "$CYAN"
  ui_kv "Client IP" "$cip"
  ui_kv "Uptime"    "$up"
  ui_kv "Bandwidth" "TX ${tx} | RX ${rx} | Total ${tot}"
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
