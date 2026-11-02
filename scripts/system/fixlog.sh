#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: Log maintenance (cap sizes; keep recent data for live telemetry)
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
# Retain recent tail lines in logs used by live session, IP-limit, and
# app/domain telemetry monitors while preventing unbounded disk/RAM growth.

cap_log_tail() {
  local f="$1" lines="${2:-3000}"
  if [[ -f "$f" ]]; then
    local cur
    cur=$(wc -l < "$f" 2>/dev/null || echo 0)
    if (( cur > lines )); then
      tail -n "$lines" "$f" > "${f}.tmp.$$" 2>/dev/null && \
        cat "${f}.tmp.$$" > "$f" && rm -f "${f}.tmp.$$"
    fi
  fi
}

: > /var/log/messages       2>/dev/null
: > /var/log/syslog         2>/dev/null
: > /var/log/xray/error.log 2>/dev/null

cap_log_tail /var/log/xray/access.log 5000
cap_log_tail /var/log/autoscript-dns.log 4000
cap_log_tail /var/log/secure 3000
cap_log_tail /var/log/auth.log 3000
cap_log_tail /var/log/ssh-ws.log 5000
