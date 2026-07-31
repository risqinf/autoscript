#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf & sela-putri
# Description: Multi-method Encrypted Backup (Telegram, Zip, Cloud Vault)
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
. /usr/local/sbin/lib/common.sh

require_root
domain=$(get_domain)
ipsaya=$(get_ip)
ts=$(date +"%d-%m-%Y")
tm=$(date +"%H-%M-%S")
code=$(openssl rand -hex 4)
zip_file="/root/backup-${ts}-${tm}-${code}.zip"
work="/root/.backup_work"

# Backup encryption password from secure store (fallback: generate + persist).
pass_file="${AS_ETC}/backup.pass"
if [[ -s "$pass_file" ]]; then
  PASSWORD=$(cat "$pass_file")
else
  PASSWORD=$(openssl rand -base64 18)
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

caption="[OK] Backup Archive
File   : $(basename "$zip_file")
Domain : ${domain}
IP     : ${ipsaya}
Date   : ${ts} ${tm}
Code   : ${code}
Pass   : ${PASSWORD}"

case "$METHOD" in
  telegram)
    botToken=$(cat "$AS_BOTKEY" 2>/dev/null)
    chatId=$(cat "$AS_CHATID" 2>/dev/null)
    if [[ -z "$botToken" || -z "$chatId" ]]; then
      warn "Telegram bot.key/client.id not configured. Saved backup locally."
      ok "Backup archive stored at: ${zip_file}"
      exit 0
    fi

    info "Sending backup to Telegram..."
    resp=$(curl -s -F "chat_id=${chatId}" -F "caption=${caption}" \
                -F "document=@${zip_file}" \
                "https://api.telegram.org/bot${botToken}/sendDocument")

    if echo "$resp" | grep -q '"ok":true'; then
      ok "Backup sent to Telegram successfully."
      file_id=$(echo "$resp" | jq -r '.result.document.file_id // empty' 2>/dev/null)
      [[ -n "$file_id" ]] && ui_kv "File ID" "${file_id}"
      rm -f "$zip_file"
    else
      warn "Backup created but Telegram send failed. Saved locally."
      ok "Backup archive stored at: ${zip_file}"
    fi
    ;;

  cloudvault)
    cv_url=$(get_cloud_vault_url)
    if [[ -z "$cv_url" ]]; then
      warn "Cloud Vault URL is empty (url=\"\")."
      warn "Please configure Cloud Vault URL via Backup Menu or save backup locally."
      ok "Backup archive stored at: ${zip_file}"
      exit 0
    fi

    info "Uploading backup to Cloud Vault (${cv_url})..."
    resp=$(curl -s -X POST "${cv_url}/api/upload" \
                -F "file=@${zip_file}" \
                -F "domain=${domain}")

    cv_code=$(echo "$resp" | jq -r '.data.code // .code // empty' 2>/dev/null)
    if [[ -n "$cv_code" && "$cv_code" != "null" ]]; then
      ok "Backup uploaded to Cloud Vault successfully!"
      ui_kv "Restore Code" "${cv_code}"
      rm -f "$zip_file"
    else
      warn "Cloud Vault upload failed. Response: ${resp}"
      ok "Backup archive stored locally at: ${zip_file}"
    fi
    ;;

  zip)
    ok "Backup archive saved locally."
    ui_kv "Backup File" "${zip_file}"
    ui_kv "Password" "${PASSWORD}"
    ;;
esac

ok "Backup operation finished."
