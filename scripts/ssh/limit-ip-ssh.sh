#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: SSH All-Protocol IP-limit enforcement (OpenSSH, Dropbear, SSL, WS, OpenVPN)
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
. /usr/local/sbin/lib/account.sh

db_init

declare -A PORT2USER=() PORT2CIP=() PID2USER=()

if   [[ -s /var/log/secure ]];   then SECLOG=/var/log/secure
elif [[ -s /var/log/auth.log ]]; then SECLOG=/var/log/auth.log
else SECLOG=""
fi

if [[ -n "$SECLOG" ]]; then
  while IFS='|' read -r port user ip pid; do
    [[ -n "$port" && -n "$user" ]] && PORT2USER[$port]="$user"
    [[ -n "$port" && -n "$ip" ]] && PORT2CIP[$port]="$ip"
    [[ -n "$pid" && -n "$user" ]] && PID2USER[$pid]="$user"
  done < <(
    tail -n 5000 "$SECLOG" 2>/dev/null | awk '
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
fi

if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  ws_json=$(curl -s --connect-timeout 1 --max-time 2 http://127.0.0.1:8081/api/sessions 2>/dev/null)
  if [[ -n "$ws_json" ]]; then
    while IFS='|' read -r pport cip u; do
      [[ -n "$pport" && -n "$cip" ]] && PORT2CIP[$pport]="${cip%%:*}"
      [[ -n "$pport" && -n "$u" && "$u" != "detecting..." ]] && PORT2USER[$pport]="$u"
    done < <(echo "$ws_json" | jq -r '.data.sessions[]? | "\(.proxy_to_ssh_port)|\(.real_client_ip)|\(.username)"' 2>/dev/null)
  fi
fi

declare -A USER_IPS=()

record_user_ip() {
  local u="$1" cip="$2"
  [[ -z "$u" || -z "$cip" ]] && return
  case " ${USER_IPS[$u]:-} " in
    *" $cip "*) ;;
    *) USER_IPS[$u]="${USER_IPS[$u]:-} $cip" ;;
  esac
}

# 1) Live TCP sockets on 22, 3303, 109, 143
while IFS='|' read -r lport rip rport pid; do
  [[ -z "$rport" ]] && continue
  u="${PORT2USER[$rport]:-${PID2USER[$pid]:-}}"
  [[ -z "$u" ]] && continue
  cip="$rip"
  if [[ "$cip" == "127.0.0.1" || "$cip" == "::1" ]]; then
    cip="${PORT2CIP[$rport]:-port:${rport}}"
    [[ "$cip" == "127.0.0.1" ]] && cip="port:${rport}"
  fi
  record_user_ip "$u" "$cip"
done < <(
  ss -tnpH state established 2>/dev/null | awk '
    {
      loc=$4; rem=$5; proc=$0;
      sub(/^::ffff:/, "", loc); sub(/^::ffff:/, "", rem);
      nl=split(loc, la, ":"); lport=la[nl];
      if (lport=="22" || lport=="3303" || lport=="109" || lport=="143") {
        nr=split(rem, ra, ":"); rport=ra[nr];
        rip=rem; sub(/:[0-9]+$/, "", rip);
        pid=""; if (match(proc, /pid=[0-9]+/)) pid=substr(proc, RSTART+4, RLENGTH-4);
        print lport "|" rip "|" rport "|" pid;
      }
    }
  '
)

# 2) Live OpenVPN sessions
for sf in /etc/openvpn/server/openvpn-status-tcp.log /etc/openvpn/server/openvpn-status-udp.log /etc/openvpn/openvpn-status.log; do
  [[ -s "$sf" ]] || continue
  while IFS='|' read -r u raddr; do
    [[ -z "$u" || "$u" == "UNDEF" ]] && continue
    record_user_ip "$u" "${raddr%%:*}"
  done < <(awk -F',' '/^CLIENT_LIST,/ { u=$2; if($10!="" && $10!="UNDEF") u=$10; print u "|" $3 }' "$sf" 2>/dev/null)
done

# 3) Enforce per active SSH account
while IFS='|' read -r user limit; do
  [[ -z "$user" ]] && continue
  [[ "$limit" =~ ^[0-9]+$ ]] && (( limit > 0 )) || continue
  ips="${USER_IPS[$user]:-}"
  cnt=$(echo "$ips" | tr ' ' '\n' | grep -c '[^[:space:]]')
  if (( cnt > limit )); then
    acc_ssh_kill_user "$user"
    db_audit "ip_limit_kick" "ssh" "$user" "ips=${cnt}/${limit}"
    tg_send "<b>[ SSH IP LIMIT ]</b>%0AUsername: <code>${user}</code>%0AIPs: ${cnt}/${limit}%0AAction: sessions terminated"
  fi
done < <(db_query "SELECT username, limit_ip FROM accounts WHERE protocol='ssh' AND status='active';")
exit 0
