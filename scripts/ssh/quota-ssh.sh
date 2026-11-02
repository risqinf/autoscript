#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: SSH All-Protocol Usage Quota Accounting & Enforcement
#              Covers: OpenSSH (22,3303), Dropbear (109,143),
#                      Direct SSH SSL/TLS (443,8443 via HAProxy),
#                      SSH WebSocket (80,8080,8888,443 via ssh-ws),
#                      SlowDNS (53,5300 via dnstt), and OpenVPN (1194 TCP/UDP)
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
. /usr/local/sbin/lib/account.sh

db_init

STATE_FILE="/run/autoscript-ssh-quota.state"
LOCK_FILE="/run/autoscript-ssh-quota.lock"
mkdir -p /run 2>/dev/null

exec 201>"$LOCK_FILE"
flock -n 201 || exit 0

touch "$STATE_FILE" 2>/dev/null
chmod 600 "$STATE_FILE" 2>/dev/null

# 1) Load previous per-session counters: key -> "rx|tx|ts"
declare -A PREV_RX=() PREV_TX=() NEXT_STATE=()
now_ts=$(date +%s)

while IFS=$'\t' read -r skey srx stx sts; do
  [[ -z "$skey" ]] && continue
  # Retain entries seen within last 6 hours to handle idle long-lived tunnels
  if [[ "$sts" =~ ^[0-9]+$ ]] && (( now_ts - sts <= 21600 )); then
    PREV_RX[$skey]="${srx:-0}"
    PREV_TX[$skey]="${stx:-0}"
    NEXT_STATE[$skey]="${srx:-0}"$'\t'"${stx:-0}"$'\t'"${sts}"
  fi
done < "$STATE_FILE"

# 2) Build port -> username map from auth logs + ssh-ws live API
declare -A PORT2USER=() PID2USER=()

read_auth_stream() {
  if [[ -s /var/log/secure ]]; then
    tail -n 5000 /var/log/secure 2>/dev/null
  elif [[ -s /var/log/auth.log ]]; then
    tail -n 5000 /var/log/auth.log 2>/dev/null
  elif command -v journalctl >/dev/null 2>&1; then
    journalctl -u dropbear -u sshd -u ssh --since "12 hours ago" --no-pager 2>/dev/null
  fi
}

while IFS='|' read -r port user pid; do
  [[ -n "$port" && -n "$user" ]] && PORT2USER[$port]="$user"
  [[ -n "$pid" && -n "$user" ]] && PID2USER[$pid]="$user"
done < <(
  read_auth_stream | awk '
    /dropbear\[/ && /Password auth succeeded/ {
      pid=$0; sub(/.*dropbear\[/,"",pid); sub(/\].*/,"",pid);
      f=$NF; n=split(f,a,":"); port=a[n]; u="";
      for(i=1;i<=NF;i++){ if($i ~ /^\047.*\047$/){ u=$i; gsub(/\047/,"",u) } }
      if(port ~ /^[0-9]+$/ && u!="") print port "|" u "|" pid
    }
    /sshd\[/ && /Accepted / {
      pid=$0; sub(/.*sshd\[/,"",pid); sub(/\].*/,"",pid);
      u=""; port="";
      for(i=1;i<=NF;i++){ if($i=="for") u=$(i+1); if($i=="port") port=$(i+1) }
      if(port ~ /^[0-9]+$/ && u!="") print port "|" u "|" pid
    }
  ' 2>/dev/null
)

if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  ws_json=$(curl -s --connect-timeout 1 --max-time 2 http://127.0.0.1:8081/api/sessions 2>/dev/null)
  if [[ -n "$ws_json" ]]; then
    while IFS='|' read -r pport u; do
      [[ -n "$pport" && -n "$u" && "$u" != "detecting..." ]] && PORT2USER[$pport]="$u"
    done < <(echo "$ws_json" | jq -r '.data.sessions[]? | "\(.proxy_to_ssh_port)|\(.username)"' 2>/dev/null)
  fi
fi

# Also map sshd unprivileged child PIDs -> username from process table
while read -r pid uname comm; do
  if [[ "$comm" == "sshd" && -n "$uname" && "$uname" != "root" && "$uname" != "sshd" ]]; then
    PID2USER[$pid]="$uname"
  fi
done < <(ps -eo pid=,user=,comm= 2>/dev/null)

# 3) Inspect live kernel TCP sockets + TCP_INFO byte counters in ONE snapshot
SS_SNAPSHOT=$(ss -tinpH state established 2>/dev/null)

# Map local proxy source port -> proxy daemon name (ssh-ws, haproxy, dnstt-server)
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

# Accumulators per "username|sub_protocol"
declare -A DELTA_RX=() DELTA_TX=() USER_DELTA_TOTAL=()

record_delta() {
  local user="$1" subproto="$2" skey="$3" cur_rx="$4" cur_tx="$5"
  [[ -z "$user" || "$user" == "root" || "$user" == "sshd" ]] && return
  [[ "$cur_rx" =~ ^[0-9]+$ ]] || cur_rx=0
  [[ "$cur_tx" =~ ^[0-9]+$ ]] || cur_tx=0

  local prx="${PREV_RX[$skey]:-0}"
  local ptx="${PREV_TX[$skey]:-0}"
  local drx=0 dtx=0

  if (( cur_rx >= prx )); then drx=$(( cur_rx - prx )); else drx=$cur_rx; fi
  if (( cur_tx >= ptx )); then dtx=$(( cur_tx - ptx )); else dtx=$cur_tx; fi

  NEXT_STATE[$skey]="${cur_rx}"$'\t'"${cur_tx}"$'\t'"${now_ts}"

  if (( drx > 0 || dtx > 0 )); then
    local uk="${user}|${subproto}"
    DELTA_RX[$uk]=$(( ${DELTA_RX[$uk]:-0} + drx ))
    DELTA_TX[$uk]=$(( ${DELTA_TX[$uk]:-0} + dtx ))
    USER_DELTA_TOTAL[$user]=$(( ${USER_DELTA_TOTAL[$user]:-0} + drx + dtx ))
  fi
}

# Parse inbound sockets on 22, 3303 (OpenSSH) and 109, 143 (Dropbear/SSL/WS/SlowDNS)
if [[ -n "$SS_SNAPSHOT" ]]; then
  while IFS='|' read -r lport rip rport pid sk rx tx; do
    [[ -z "$lport" || -z "$rport" ]] && continue
    user="${PORT2USER[$rport]:-}"
    [[ -z "$user" && -n "$pid" ]] && user="${PID2USER[$pid]:-}"
    [[ -z "$user" ]] && continue

    subproto="openssh"
    if [[ "$lport" == "22" || "$lport" == "3303" ]]; then
      subproto="openssh"
    else
      if [[ "$rip" == "127.0.0.1" || "$rip" == "::1" || "$rip" == "[::1]" ]]; then
        pcomm="${LOCALPROXY_COMM[$rport]:-}"
        case "$pcomm" in
          ssh-ws*)              subproto="ssh_ws" ;;
          haproxy*)             subproto="ssh_ssl" ;;
          dnstt*|dns-server*)   subproto="slowdns" ;;
          *)                    subproto="ssh_ssl" ;;
        esac
      else
        subproto="dropbear"
      fi
    fi

    [[ -z "$sk" ]] && sk="${lport}:${rip}:${rport}:${pid}"
    skey="tcp:${subproto}:${user}:${sk}"
    record_delta "$user" "$subproto" "$skey" "$rx" "$tx"
  done < <(
    printf '%s\n' "$SS_SNAPSHOT" | awk '
      /^[^ \t]/ {
        if (in_sock) {
          print slport "|" srip "|" srport "|" spid "|" ssk "|" srx "|" stx;
          in_sock=0;
        }
        loc=$4; rem=$5; proc=$0;
        sub(/^::ffff:/, "", loc); sub(/^::ffff:/, "", rem);
        nl=split(loc, la, ":"); lport=la[nl];
        if (lport=="22" || lport=="3303" || lport=="109" || lport=="143") {
          nr=split(rem, ra, ":"); rport=ra[nr];
          rip=rem; sub(/:[0-9]+$/, "", rip);
          pid="";
          if (match(proc, /pid=[0-9]+/)) {
            pid=substr(proc, RSTART+4, RLENGTH-4);
          }
          in_sock=1; slport=lport; srip=rip; srport=rport; spid=pid;
          ssk=""; srx=0; stx=0;
        }
        next;
      }
      /^[ \t]/ && in_sock {
        for (i=1; i<=NF; i++) {
          if ($i ~ /^sk:/)             { ssk=substr($i, 4); }
          if ($i ~ /^bytes_received:/) { srx=substr($i, 16); }
          if ($i ~ /^bytes_acked:/)    { stx=substr($i, 13); }
        }
      }
      END {
        if (in_sock) {
          print slport "|" srip "|" srport "|" spid "|" ssk "|" srx "|" stx;
        }
      }
    '
  )
fi

# 4) Parse OpenVPN status files (status-version 1, 2, or 3)
OVPN_STATUS_FILES=(
  "/etc/openvpn/server/openvpn-status-tcp.log"
  "/etc/openvpn/server/openvpn-status-udp.log"
  "/etc/openvpn/openvpn-status.log"
  "/var/log/openvpn/openvpn-status.log"
  "/var/log/openvpn/status-tcp.log"
  "/var/log/openvpn/status-udp.log"
)

for sf in "${OVPN_STATUS_FILES[@]}"; do
  [[ -s "$sf" ]] || continue
  while IFS='|' read -r user raddr rx tx csince; do
    [[ -z "$user" || "$user" == "UNDEF" || "$user" == "Common Name" ]] && continue
    skey="ovpn:${user}:${raddr}:${csince}"
    record_delta "$user" "openvpn" "$skey" "$rx" "$tx"
  done < <(
    awk -F',' '
      /^CLIENT_LIST,/ {
        # status-version 2: CLIENT_LIST,CN,RealAddr,VirtAddr,VirtIPv6,BytesRecv,BytesSent,ConnSince,ConnSinceEpoch,Username
        u=$2; if ($10 != "" && $10 != "UNDEF") u=$10;
        raddr=$3; rx=$6; tx=$7; cs=($9 != "" ? $9 : $8);
        if (rx ~ /^[0-9]+$/ && tx ~ /^[0-9]+$/) print u "|" raddr "|" rx "|" tx "|" cs;
        next;
      }
      /^Common Name,Real Address,Bytes Received,Bytes Sent/ { v1=1; next }
      /^ROUTING TABLE/ || /^GLOBAL STATS/ || /^END/ { v1=0; next }
      v1 && NF >= 5 {
        if ($3 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/) print $1 "|" $2 "|" $3 "|" $4 "|" $5;
      }
    ' "$sf" 2>/dev/null
  )
done

# 5) Persist state file atomically
tmp_state="${STATE_FILE}.tmp.$$"
{
  for k in "${!NEXT_STATE[@]}"; do
    printf '%s\t%s\n' "$k" "${NEXT_STATE[$k]}"
  done
} > "$tmp_state" 2>/dev/null && mv -f "$tmp_state" "$STATE_FILE"
chmod 600 "$STATE_FILE" 2>/dev/null

# 6) Flush deltas into SQLite in a single transaction
sql_tx=""
for uk in "${!DELTA_RX[@]}"; do
  u="${uk%%|*}"
  sp="${uk#*|}"
  drx="${DELTA_RX[$uk]:-0}"
  dtx="${DELTA_TX[$uk]:-0}"
  (( drx + dtx <= 0 )) && continue
  eu=$(sql_escape "$u")
  esp=$(sql_escape "$sp")
  sql_tx+="INSERT INTO ssh_proto_usage(username, sub_protocol, rx_bytes, tx_bytes, updated_at) VALUES ('${eu}', '${esp}', ${drx}, ${dtx}, ${now_ts}) ON CONFLICT(username, sub_protocol) DO UPDATE SET rx_bytes = rx_bytes + ${drx}, tx_bytes = tx_bytes + ${dtx}, updated_at = ${now_ts};"$'\n'
done

for u in "${!USER_DELTA_TOTAL[@]}"; do
  dtot="${USER_DELTA_TOTAL[$u]:-0}"
  (( dtot <= 0 )) && continue
  eu=$(sql_escape "$u")
  sql_tx+="UPDATE accounts SET used_bytes = used_bytes + ${dtot}, updated_at = ${now_ts} WHERE protocol='ssh' AND username='${eu}' AND status='active';"$'\n'
done

if [[ -n "$sql_tx" ]]; then
  db_exec "BEGIN TRANSACTION;"$'\n'"${sql_tx}COMMIT;" >/dev/null 2>&1
fi

# 7) Enforce SSH quota across all active SSH accounts with finite quota_bytes > 0
while IFS='|' read -r u qb used; do
  [[ -z "$u" ]] && continue
  if [[ "$qb" =~ ^[0-9]+$ && "$used" =~ ^[0-9]+$ ]] && (( qb > 0 && used >= qb )); then
    acc_ssh_suspend "$u" "quota_exceeded"
    used_h=$(human_bytes "$used")
    qb_h=$(human_bytes "$qb")
    tg_send "<b>[ SSH ALL-PROTOCOL QUOTA EXCEEDED ]</b>%0AUsername: <code>${u}</code>%0AUsed: <code>${used_h} / ${qb_h}</code>%0AStatus: <b>suspended</b>"
  fi
done < <(db_query "SELECT username, quota_bytes, used_bytes FROM accounts WHERE protocol='ssh' AND status='active' AND quota_bytes > 0;")

exit 0
