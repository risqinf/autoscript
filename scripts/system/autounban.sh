#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: 15-Minute Auto-Unban Evaluation Worker
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
. /usr/local/sbin/lib/account.sh 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/../lib/account.sh"

require_root
db_init

run_check() {
  local now; now=$(date +%s)
  local cutoff=$(( now - 900 )) # 15 minutes cooldown

  # Fetch all suspended accounts exceeding 15 minutes cooldown and not expired
  while IFS='|' read -r id proto user secret quota used limit_ip exp note; do
    [[ -z "$user" || -z "$proto" ]] && continue
    (( exp <= now )) && continue # Skip if already expired

    local is_quota=0
    [[ "$note" == *"quota"* ]] && is_quota=1

    local restored=0
    case "$proto" in
      vless|vmess|trojan)
        if cfg_add_client "$proto" "$user" "$secret"; then
          restored=1
        fi
        ;;
      ssh)
        if ! skip_user_provision; then
          local nologin; nologin=$(get_nologin_shell)
          local exp_str; exp_str=$(date -d "@${exp}" +%Y-%m-%d 2>/dev/null || date -r "${exp}" +%Y-%m-%d 2>/dev/null)
          usermod -U -s "$nologin" -e "$exp_str" "$user" 2>/dev/null
          restored=1
        fi
        ;;
      noobz)
        if command -v noobzvpns >/dev/null 2>&1; then
          noobzvpns unblock "$user" >/dev/null 2>&1
          restored=1
        fi
        ;;
    esac

    if [[ $restored -eq 1 ]]; then
      if [[ $is_quota -eq 1 ]]; then
        db_exec "UPDATE accounts SET used_bytes=0, status='active', updated_at=strftime('%s','now') WHERE protocol='$(sql_escape "$proto")' AND username='$(sql_escape "$user")';"
        [[ "$proto" == "ssh" ]] && db_exec "DELETE FROM ssh_proto_usage WHERE username='$(sql_escape "$user")';"
      else
        db_exec "UPDATE accounts SET status='active', updated_at=strftime('%s','now') WHERE protocol='$(sql_escape "$proto")' AND username='$(sql_escape "$user")';"
      fi

      db_audit "auto_unban" "$proto" "$user" "auto-unbanned after 15m cooldown (reason: ${note})"
      
      local reason_desc="Limit IP Multi-Device (Masa jeda 15 menit selesai)"
      if [[ $is_quota -eq 1 ]]; then
        reason_desc="Batas Kuota Bandwidth (Reset otomatis setelah jeda 15 menit)"
      fi

      tg_send "<b>━━━━━━━━━━━━━━━━━━━━━━━━━━━</b>%0A<b>    ⊹ AUTO-UNBAN (15 MENIT) • ${proto^^} ⊹</b>%0A<b>━━━━━━━━━━━━━━━━━━━━━━━━━━━</b>%0A<b>Username :</b> <code>${user}</code>%0A<b>Protocol :</b> <code>${proto^^}</code>%0A<b>Status   :</b> <b>ACTIVE (Dipulihkan)</b>%0A<b>Catatan  :</b> <code>${reason_desc}</code>%0A<b>━━━━━━━━━━━━━━━━━━━━━━━━━━━</b>"
      
      [[ "$proto" =~ ^(vless|vmess|trojan)$ ]] && systemctl restart xray.service >/dev/null 2>&1
      echo "[$(date '+%Y-%m-%d %H:%M:%S')] Auto-unbanned ${proto}/${user} (reason was: ${note})"
    fi
  done < <(db_query "SELECT id, protocol, username, secret, quota_bytes, used_bytes, limit_ip, expired_at, note
                     FROM accounts
                     WHERE status = 'suspended' AND updated_at <= ${cutoff} AND expired_at > ${now};")
}

if [[ "${1:-}" == "--once" ]]; then
  run_check
  exit 0
fi

while true; do
  run_check
  sleep 45
done
