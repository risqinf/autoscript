#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: SSH All-Protocol Live Session, Quota & App Telemetry Monitor
#              Covers: OpenSSH, Dropbear Direct, Direct SSH SSL/TLS,
#                      SSH WebSocket, SlowDNS, and OpenVPN
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
. /usr/local/sbin/lib/account.sh

db_init

# Flush latest kernel byte counters into SQLite before rendering
[[ -x /usr/local/sbin/quota-ssh ]] && /usr/local/sbin/quota-ssh >/dev/null 2>&1 || true

declare -A PORT2USER=() PORT2IP=() PORT2PID=() PID2USER=()

get_auth_logs() {
  if [[ -s /var/log/secure ]]; then
    tail -n 5000 /var/log/secure 2>/dev/null
  elif [[ -s /var/log/auth.log ]]; then
    tail -n 5000 /var/log/auth.log 2>/dev/null
  elif command -v journalctl >/dev/null 2>&1; then
    journalctl -u dropbear -u ssh -u sshd --since "1 day ago" --no-pager 2>/dev/null
  fi
}

while IFS='|' read -r port user ip pid; do
  if [[ -n "$port" && -n "$user" ]]; then
    PORT2USER[$port]="$user"
    PORT2IP[$port]="$ip"
    PORT2PID[$port]="$pid"
  fi
  [[ -n "$pid" && -n "$user" ]] && PID2USER[$pid]="$user"
done < <(
  get_auth_logs | awk '
    /dropbear\[/ && /Password auth succeeded/ {
      pid=$0; sub(/.*dropbear\[/,"",pid); sub(/\].*/,"",pid);
      f=$NF; n=split(f,a,":"); ip=a[1]; port=a[n]; u="";
      for(i=1;i<=NF;i++){ if($i ~ /^\047.*\047$/){ u=$i; gsub(/\047/,"",u) } }
      if(port ~ /^[0-9]+$/ && u!="") print port "|" u "|" ip "|" pid
    }
    /sshd\[/ && /Accepted / {
      pid=$0; sub(/.*sshd\[/,"",pid); sub(/\].*/,"",pid);
      u=""; port=""; ip="";
      for(i=1;i<=NF;i++){ if($i=="for") u=$(i+1); if($i=="port") port=$(i+1); if($i=="from") ip=$(i+1) }
      if(port ~ /^[0-9]+$/ && u!="") print port "|" u "|" ip "|" pid
    }
  ' 2>/dev/null
)

while read -r pid uname comm; do
  if [[ "$comm" == "sshd" && -n "$uname" && "$uname" != "root" && "$uname" != "sshd" ]]; then
    PID2USER[$pid]="$uname"
  fi
done < <(ps -eo pid=,user=,comm= 2>/dev/null)

# Enrich ssh-ws proxy_port -> real_client_ip, uptime, username
declare -A WS_CIP=() WS_UP=()
if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  ws_json=$(curl -s --connect-timeout 1 --max-time 2 http://127.0.0.1:8081/api/sessions 2>/dev/null)
  if [[ -n "$ws_json" ]]; then
    while IFS='|' read -r pport cip user up; do
      [[ -z "$pport" ]] && continue
      WS_CIP[$pport]="$cip"
      WS_UP[$pport]="$up"
      [[ -n "$user" && "$user" != "detecting..." ]] && PORT2USER[$pport]="$user"
    done < <(echo "$ws_json" | jq -r '.data.sessions[]? | "\(.proxy_to_ssh_port)|\(.real_client_ip)|\(.username)|\(.duration)"' 2>/dev/null)
  fi
fi

# Enrich HAProxy local proxy_port -> real_client_ip (for Direct SSH SSL/TLS on 443/8443)
declare -A HAP_CIP=()
if [[ -S /run/haproxy/admin.sock ]] && command -v socat >/dev/null 2>&1; then
  while IFS='|' read -r pport cip; do
    [[ -n "$pport" && -n "$cip" ]] && HAP_CIP[$pport]="$cip"
  done < <(
    echo "show sess all" | socat - UNIX-CONNECT:/run/haproxy/admin.sock 2>/dev/null | awk '
      /src=/ && /dst=/ {
        cip=""; pport="";
        for(i=1;i<=NF;i++){
          if($i ~ /^src=/){ s=substr($i,5); sub(/:[0-9]+$/,"",s); cip=s }
        }
      }
    '
  )
fi

# Inspect ALL established TCP sockets once
SS_SNAPSHOT=$(ss -tinpH state established 2>/dev/null)

declare -A LOCALPROXY_COMM=()
if [[ -n "$SS_SNAPSHOT" ]]; then
  while IFS='|' read -r lport pcomm; do
    [[ -n "$lport" && -n "$pcomm" ]] && LOCALPROXY_COMM[$lport]="$pcomm"
  done < <(
    printf '%s\n' "$SS_SNAPSHOT" | awk '
      /^[^ \t]/ {
        loc=$4; rem=$5; proc=$0;
        sub(/^::ffff:/, "", loc); sub(/^::ffff:/, "", rem);
        if (rem ~ /^127\.0\.0\.1:(109|143|22|3303)$/ || rem ~ /^\[::1\]:(109|143|22|3303)$/) {
          n=split(loc, a, ":"); lport=a[n];
          c="";
          if (match(proc, /users:\(\("[^"]+"/)) {
            c=substr(proc, RSTART+9, RLENGTH-10);
          }
          if (lport ~ /^[0-9]+$/ && c != "") print lport "|" c;
        }
      }
    '
  )
fi

# Also gather external HAProxy client IPs on :443/:8443 when HAProxy forwards to ssh_backend
HAP_EXT_IPS=()
if [[ -n "$SS_SNAPSHOT" ]]; then
  while IFS= read -r hip; do
    [[ -n "$hip" ]] && HAP_EXT_IPS+=("$hip")
  done < <(
    printf '%s\n' "$SS_SNAPSHOT" | awk '
      /^[^ \t]/ && /"haproxy"/ {
        loc=$4; rem=$5;
        sub(/^::ffff:/, "", loc); sub(/^::ffff:/, "", rem);
        if (loc ~ /:(443|8443)$/ && rem !~ /^127\./) {
          sub(/:[0-9]+$/, "", rem);
          seen[rem]=1;
        }
      }
      END { for (k in seen) print k }
    '
  )
fi

declare -A USER_SESSIONS=() USER_SESS_CNT=() USER_PROTOS=() USER_PIDS=() USER_OVPN_VIPS=()
total_live=0

add_user_session() {
  local u="$1" proto_label="$2" cip="$3" up="$4" rx_b="$5" tx_b="$6" pid="$7" vip="$8"
  [[ -z "$u" ]] && return
  local tot_b=$(( ${rx_b:-0} + ${tx_b:-0} ))
  local rx_h tx_h tot_h
  rx_h=$(human_bytes "$rx_b")
  tx_h=$(human_bytes "$tx_b")
  tot_h=$(human_bytes "$tot_b")

  USER_SESS_CNT[$u]=$(( ${USER_SESS_CNT[$u]:-0} + 1 ))
  total_live=$(( total_live + 1 ))

  if [[ ",${USER_PROTOS[$u]:-}," != *",${proto_label},"* ]]; then
    if [[ -n "${USER_PROTOS[$u]:-}" ]]; then
      USER_PROTOS[$u]="${USER_PROTOS[$u]}, ${proto_label}"
    else
      USER_PROTOS[$u]="$proto_label"
    fi
  fi

  if [[ -n "$pid" && ",${USER_PIDS[$u]:-}," != *",${pid},"* ]]; then
    USER_PIDS[$u]="${USER_PIDS[$u]:+${USER_PIDS[$u]},}${pid}"
  fi
  if [[ -n "$vip" && ",${USER_OVPN_VIPS[$u]:-}," != *",${vip},"* ]]; then
    USER_OVPN_VIPS[$u]="${USER_OVPN_VIPS[$u]:+${USER_OVPN_VIPS[$u]},}${vip}"
  fi

  local row="${proto_label}|${cip}|${up}|${tx_h}|${rx_h}|${tot_h}"
  if [[ -n "${USER_SESSIONS[$u]:-}" ]]; then
    USER_SESSIONS[$u]="${USER_SESSIONS[$u]}"$'\n'"${row}"
  else
    USER_SESSIONS[$u]="$row"
  fi
}

# 1) Collect live TCP SSH sessions (OpenSSH, Dropbear Direct, Direct SSH SSL/TLS, SSH-WS, SlowDNS)
if [[ -n "$SS_SNAPSHOT" ]]; then
  hap_idx=0
  while IFS='|' read -r lport rip rport pid rx tx; do
    [[ -z "$lport" || -z "$rport" ]] && continue
    user="${PORT2USER[$rport]:-}"
    [[ -z "$user" && -n "$pid" ]] && user="${PID2USER[$pid]:-}"
    # Skip unauthenticated banner probes
    if [[ -z "$user" ]]; then
      (( rx + tx < 4096 )) && continue
      user="(detecting)"
    fi

    proto_label="OpenSSH"
    cip="$rip"
    up="-"

    if [[ "$lport" == "22" || "$lport" == "3303" ]]; then
      proto_label="OpenSSH (:${lport})"
    else
      if [[ "$rip" == "127.0.0.1" || "$rip" == "::1" || "$rip" == "[::1]" ]]; then
        pcomm="${LOCALPROXY_COMM[$rport]:-}"
        case "$pcomm" in
          ssh-ws*)
            proto_label="SSH-WS"
            cip="${WS_CIP[$rport]:-${PORT2IP[$rport]:-127.0.0.1}}"
            up="${WS_UP[$rport]:--}"
            ;;
          haproxy*)
            proto_label="Direct SSH SSL/TLS"
            cip="${HAP_CIP[$rport]:-}"
            if [[ -z "$cip" && ${#HAP_EXT_IPS[@]} -gt 0 ]]; then
              cip="${HAP_EXT_IPS[$(( hap_idx % ${#HAP_EXT_IPS[@]} ))]}"
              hap_idx=$(( hap_idx + 1 ))
            fi
            [[ -z "$cip" ]] && cip="SSL/TLS Client"
            ;;
          dnstt*|dns-server*)
            proto_label="SlowDNS (DNSTT)"
            cip="DNS Tunnel"
            ;;
          *)
            proto_label="Direct SSH SSL/TLS"
            cip="${PORT2IP[$rport]:-SSL/TLS Client}"
            ;;
        esac
      else
        proto_label="Dropbear Direct (:${lport})"
      fi
    fi

    cip="${cip%%:*}"
    if [[ "$up" == "-" && -n "$pid" && -d "/proc/$pid" ]]; then
      up=$(ps -p "$pid" -o etime= 2>/dev/null | tr -d ' ')
      [[ -z "$up" ]] && up="-"
    fi
    # Also include child PIDs of sshd privilege-separated master so outbound sockets are captured
    all_pids="$pid"
    if [[ -n "$pid" ]]; then
      cpids=$(pgrep -P "$pid" 2>/dev/null | paste -sd ',' -)
      [[ -n "$cpids" ]] && all_pids="${pid},${cpids}"
    fi

    add_user_session "$user" "$proto_label" "$cip" "$up" "$rx" "$tx" "$all_pids" ""
  done < <(
    printf '%s\n' "$SS_SNAPSHOT" | awk '
      /^[^ \t]/ {
        if (in_sock) { print slport "|" srip "|" srport "|" spid "|" srx "|" stx; in_sock=0 }
        loc=$4; rem=$5; proc=$0;
        sub(/^::ffff:/, "", loc); sub(/^::ffff:/, "", rem);
        nl=split(loc, la, ":"); lport=la[nl];
        if (lport=="22" || lport=="3303" || lport=="109" || lport=="143") {
          nr=split(rem, ra, ":"); rport=ra[nr];
          rip=rem; sub(/:[0-9]+$/, "", rip);
          pid="";
          if (match(proc, /pid=[0-9]+/)) pid=substr(proc, RSTART+4, RLENGTH-4);
          in_sock=1; slport=lport; srip=rip; srport=rport; spid=pid; srx=0; stx=0;
        }
        next;
      }
      /^[ \t]/ && in_sock {
        for (i=1; i<=NF; i++) {
          if ($i ~ /^bytes_received:/) srx=substr($i, 16);
          if ($i ~ /^bytes_acked:/)    stx=substr($i, 13);
        }
      }
      END { if (in_sock) print slport "|" srip "|" srport "|" spid "|" srx "|" stx }
    '
  )
fi

# 2) Collect live OpenVPN sessions
OVPN_FILES=(
  "/etc/openvpn/server/openvpn-status-tcp.log"
  "/etc/openvpn/server/openvpn-status-udp.log"
  "/etc/openvpn/openvpn-status.log"
  "/var/log/openvpn/openvpn-status.log"
)
for sf in "${OVPN_FILES[@]}"; do
  [[ -s "$sf" ]] || continue
  ovpn_proto="OpenVPN TCP"
  [[ "$sf" == *udp* ]] && ovpn_proto="OpenVPN UDP"
  while IFS='|' read -r user raddr vip rx tx csince; do
    [[ -z "$user" || "$user" == "UNDEF" ]] && continue
    cip="${raddr%%:*}"
    up="-"
    if [[ "$csince" =~ ^[0-9]+$ ]]; then
      el=$(( $(date +%s) - csince ))
      (( el >= 0 )) && up=$(printf "%02d:%02d:%02d" $((el/3600)) $(((el%3600)/60)) $((el%60)))
    fi
    add_user_session "$user" "$ovpn_proto" "$cip" "$up" "$rx" "$tx" "" "$vip"
  done < <(
    awk -F',' '
      /^CLIENT_LIST,/ {
        u=$2; if ($10 != "" && $10 != "UNDEF") u=$10;
        if ($6 ~ /^[0-9]+$/) print u "|" $3 "|" $4 "|" $6 "|" $7 "|" $9;
      }
    ' "$sf" 2>/dev/null
  )
done

format_proto_breakdown() {
  local u="$1" parts=() sp rx tx tot label
  while IFS='|' read -r sp rx tx tot; do
    [[ -z "$sp" ]] && continue
    (( ${tot:-0} <= 0 )) && continue
    case "$sp" in
      openssh)  label="OpenSSH" ;;
      dropbear) label="Dropbear" ;;
      ssh_ssl)  label="SSH-SSL" ;;
      ssh_ws)   label="SSH-WS" ;;
      slowdns)  label="SlowDNS" ;;
      openvpn)  label="OpenVPN" ;;
      *)        label="$sp" ;;
    esac
    parts+=("${label}: $(human_bytes "$tot")")
  done < <(db_get_ssh_proto_usage "$u")
  if [[ ${#parts[@]} -gt 0 ]]; then
    local s
    s=$(printf " | %s" "${parts[@]}")
    echo "${s:3}"
  fi
}

clear
ui_header "SSH ALL-PROTOCOL LIVE MONITOR"

any=0
while IFS='|' read -r u limit qb used exp; do
  [[ -z "$u" ]] && continue
  cnt=${USER_SESS_CNT[$u]:-0}
  [[ "$cnt" -le 0 ]] && continue

  any=1
  usedd=$(human_bytes "${used:-0}")
  if [[ "$qb" == "0" || -z "$qb" ]]; then quotad="Unlimited"; else quotad=$(human_bytes "$qb"); fi
  [[ "$limit" == "0" ]] && limd="Unlimited" || limd="$limit"
  ipcol="$GREEN"
  if [[ "$limd" != "Unlimited" && "$cnt" -gt "$limit" ]]; then ipcol="$RED"; fi

  proto_bd=$(format_proto_breakdown "$u")
  apps_list=""
  if [[ -n "${USER_PIDS[$u]:-}" ]]; then
    apps_list=$(detect_pid_apps "${USER_PIDS[$u]}")
  fi
  if [[ -n "${USER_OVPN_VIPS[$u]:-}" ]]; then
    IFS=',' read -ra vips <<< "${USER_OVPN_VIPS[$u]}"
    for v in "${vips[@]}"; do
      va=$(detect_ovpn_vip_apps "$v")
      [[ -n "$va" ]] && apps_list="${apps_list:+${apps_list}, }${va}"
    done
  fi

  ui_rule
  ui_kv "Username"  "$u" "$CYAN"
  ui_kv "Protocol"  "${USER_PROTOS[$u]:-SSH}" "$PINK"
  ui_kv "Sessions"  "${cnt} / ${limd} Limit" "$ipcol"
  ui_kv "Quota Use" "${usedd} / ${quotad}"
  [[ -n "$proto_bd" ]] && ui_kv "Breakdown" "$proto_bd" "$WHITE"
  [[ -n "$apps_list" ]] && ui_kv "Apps/Dom" "$apps_list" "$YELLOW"
  ui_kv "Expired"   "${exp:--}"
  printf " ${WHITE}%-12s${NC} :\n" "Live Conns"
  while IFS='|' read -r plab cip up tx rx tot; do
    [[ -z "$cip" ]] && continue
    geo=$(lookup_ip_geo "$cip")
    asn_isp="${geo%%|*}"
    loc="${geo#*|}"
    echo -e "   ${GREEN}• [${plab}]${NC} ${WHITE}${cip}${NC} ${YELLOW}[ ${asn_isp} ]${NC}"
    [[ -n "$loc" && "$loc" != "Unknown Location" && "$loc" != "Unknown" ]] && echo -e "     ${CYAN}Location : ${loc}${NC}"
    echo -e "     \033[38;5;244m(Uptime: ${up} | TX: ${tx} | RX: ${rx} | Live: ${tot})${NC}"
  done <<< "${USER_SESSIONS[$u]}"
  if [[ "$ipcol" == "$RED" ]]; then
    echo -e "   ${RED}[!] EXCEEDS SESSION/IP LIMIT${NC}"
  fi
done < <(db_query "SELECT username, limit_ip, quota_bytes, used_bytes,
                          datetime(expired_at,'unixepoch','localtime')
                   FROM accounts WHERE protocol='ssh' AND status='active'
                   ORDER BY username;")

if [[ $any -eq 0 ]]; then
  ui_rule
  echo -e " ${YELLOW}No active SSH / SSL / WS / OpenVPN sessions.${NC}"
fi

ui_rule
echo -e " Total live sessions : ${GREEN}${total_live}${NC}"
ui_foot
ui_back
menu
