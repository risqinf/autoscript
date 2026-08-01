#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf & sela-putri
# Description: Multi-method Encrypted Backup (Telegram, Zip, Cloud Vault)
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
[[ -f /usr/local/sbin/lib/common.sh ]] && . /usr/local/sbin/lib/common.sh || . "$(dirname "$0")/../lib/common.sh"

require_root
domain=$(get_domain)
ipsaya=$(get_ip)
ts=$(date +"%d-%m-%Y")
tm=$(date +"%H-%M-%S")
code=$(openssl rand -hex 4)
backup_dir="${HOME:-/root}"
zip_file="${backup_dir}/backup-${ts}-${tm}-${code}.zip"
work="/root/.backup_work"

# Clean up old local backup files if count >= 3 (keep max 2 before creating new backup)
old_backups=($(ls -t "${backup_dir}"/backup-*.zip /root/backup-*.zip 2>/dev/null | sort -u))
if (( ${#old_backups[@]} >= 3 )); then
  info "Local backup count (${#old_backups[@]}) reached limit. Cleaning up older archives..."
  for old_file in "${old_backups[@]:2}"; do
    rm -f "$old_file" 2>/dev/null
  done
fi

# Backup encryption password from secure store (fallback: generate + persist).
pass_file="${AS_ETC}/backup.pass"
if [[ -s "$pass_file" ]]; then
  PASSWORD=$(cat "$pass_file")
else
  PASSWORD=$(openssl rand -base64 18)
  mkdir -p "$AS_ETC"
  printf '%s' "$PASSWORD" > "$pass_file"; chmod 600 "$pass_file"
fi

# Determine method (arg or auto-backup setting)
METHOD="${1:-$(get_autobackup_type)}"
case "$METHOD" in
  1|telegram|Telegram) METHOD="telegram" ;;
  2|zip|manual|Zip)     METHOD="zip" ;;
  3|cloudvault|cloud-vault|CloudVault) METHOD="cloudvault" ;;
  *) METHOD="zip" ;;
esac

info "Preparing backup archive..."
rm -rf "$work"; mkdir -p "$work/etc"

# Checkpoint WAL so xray.db is consistent, then copy DB + sidecars.
sqlite3 "$AS_DB" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1
cp -f "$AS_DB" "$work/etc/" 2>/dev/null
cp -f "$AS_CONFIG" "$work/etc/" 2>/dev/null
cp -f "$AS_DOMAIN_FILE" "$work/etc/" 2>/dev/null
cp -f "$AS_BOTKEY" "$AS_CHATID" "$work/etc/" 2>/dev/null
cp -f "$AS_CLOUD_VAULT_URL" "$AS_AUTOBACKUP_TYPE" "$work/etc/" 2>/dev/null
cp -f /etc/passwd /etc/shadow /etc/group /etc/gshadow "$work/" 2>/dev/null

which zip >/dev/null 2>&1 || dnf install zip -y >/dev/null 2>&1
( cd "$work" && zip -rqP "$PASSWORD" "$zip_file" . )
rm -rf "$work"

if [[ ! -f "$zip_file" ]]; then err "Failed to create backup archive."; exit 1; fi

zip_name=$(basename "$zip_file")
zip_size=$(du -h "$zip_file" 2>/dev/null | awk '{print $1}')

cv_code=""
direct_link=""
file_id=""

case "$METHOD" in
  cloudvault)
    cv_url=$(get_cloud_vault_url)
    if [[ -z "$cv_url" ]]; then
      warn "Cloud Vault URL is empty (url=\"\")."
      warn "Please configure Cloud Vault URL via Backup Menu or save backup locally."
    else
      info "Uploading backup to Cloud Vault (${cv_url})..."
      resp=$(curl -s -X POST "${cv_url}/api/upload" \
                  -F "file=@${zip_file}" \
                  -F "domain=${domain}")

      cv_code=$(echo "$resp" | jq -r '.data.code // .code // empty' 2>/dev/null)
      if [[ -n "$cv_code" && "$cv_code" != "null" ]]; then
        ok "Backup uploaded to Cloud Vault successfully!"
        direct_link="${cv_url}/api/file/${cv_code}"
      else
        warn "Cloud Vault upload failed. Response: ${resp}"
      fi
    fi
    ;;
esac

# Send copy to Telegram Bot whenever Telegram bot/chatid are configured
if tg_is_configured; then
  botToken=$(cat "$AS_BOTKEY" 2>/dev/null)
  chatId=$(cat "$AS_CHATID" 2>/dev/null)

  caption="📦 <b>AUTOSCRIPT BACKUP DATA</b>
━━━━━━━━━━━━━━━━━━━━━━━━━
File Name   : <code>${zip_name}</code>
File Size   : <code>${zip_size}</code>
Domain      : <code>${domain}</code>
IP Address  : <code>${ipsaya}</code>
Date        : <code>${ts} ${tm}</code>
Password    : <code>${PASSWORD}</code>
Restore Code: <code>${cv_code:-"N/A"}</code>
Direct Link : <code>${direct_link:-"N/A"}</code>
━━━━━━━━━━━━━━━━━━━━━━━━━
<i>Use Restore Code in Cloud Vault or Telegram File ID to restore.</i>"

  info "Sending backup archive to Telegram..."
  resp=$(curl -s -F "chat_id=${chatId}" \
              -F "caption=${caption}" \
              -F "parse_mode=HTML" \
              -F "document=@${zip_file}" \
              "https://api.telegram.org/bot${botToken}/sendDocument")

  if echo "$resp" | grep -q '"ok":true'; then
    ok "Backup sent to Telegram successfully."
    file_id=$(echo "$resp" | jq -r '.result.document.file_id // empty' 2>/dev/null)
    msg_id=$(echo "$resp" | jq -r '.result.message_id // empty' 2>/dev/null)

    if [[ -n "$file_id" && -n "$msg_id" ]]; then
      updated_caption="📦 <b>AUTOSCRIPT BACKUP DATA</b>
━━━━━━━━━━━━━━━━━━━━━━━━━
File Name   : <code>${zip_name}</code>
File Size   : <code>${zip_size}</code>
Domain      : <code>${domain}</code>
IP Address  : <code>${ipsaya}</code>
Date        : <code>${ts} ${tm}</code>
Password    : <code>${PASSWORD}</code>
Restore Code: <code>${cv_code:-"N/A"}</code>
Direct Link : <code>${direct_link:-"N/A"}</code>
Telegram ID : <code>${file_id}</code>
━━━━━━━━━━━━━━━━━━━━━━━━━
<i>Use Restore Code in Cloud Vault or Telegram File ID to restore.</i>"

      curl -s -F "chat_id=${chatId}" \
           -F "message_id=${msg_id}" \
           -F "caption=${updated_caption}" \
           -F "parse_mode=HTML" \
           "https://api.telegram.org/bot${botToken}/editMessageCaption" >/dev/null 2>&1
    fi
  else
    warn "Backup created but Telegram send failed."
  fi
elif [[ "$METHOD" == "telegram" ]]; then
  warn "Telegram bot.key/client.id not configured. Saved backup locally."
fi

# Print detailed summary to CLI
line
ui_header "BACKUP DETAIL INFO"
ui_kv "File Name" "${zip_name}"
ui_kv "File Size" "${zip_size}"
ui_kv "Domain" "${domain}"
ui_kv "IP Address" "${ipsaya}"
ui_kv "Date" "${ts} ${tm}"
ui_kv "Password" "${PASSWORD}"
[[ -n "$cv_code" ]] && ui_kv "Restore Code" "${cv_code}"
[[ -n "$direct_link" ]] && ui_kv "Direct Link" "${direct_link}"
[[ -n "$file_id" ]] && ui_kv "Telegram ID" "${file_id}"
line

if [[ "$METHOD" == "cloudvault" && -n "$cv_code" ]] || [[ "$METHOD" == "telegram" && -n "$file_id" ]]; then
  rm -f "$zip_file"
else
  ok "Backup archive stored locally at: ${zip_file}"
fi

ok "Backup operation finished."
