#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf & sela-putri
# Description: Multi-method Restore (Telegram File ID, Manual Zip, Cloud Vault)
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
[[ -f /usr/local/sbin/lib/common.sh ]] && . /usr/local/sbin/lib/common.sh || . "$(dirname "$0")/../lib/common.sh"

require_root
backup_dir="/root"

clear
line
echo -e "${WHITE}  RESTORE BACKUP DATA${NC}"
line

METHOD="${1:-}"
if [[ -z "$METHOD" ]]; then
  echo -e " Select restore method:"
  ui_opt 1 "Telegram Bot (File ID)"
  ui_opt 2 "Manual File Zip (Local path)"
  ui_opt 3 "Cloud Vault (Restore Code)"
  ui_rule
  read -rp " Select option [1-3]: " m_opt
  case "$m_opt" in
    1) METHOD="telegram" ;;
    2) METHOD="zip" ;;
    3) METHOD="cloudvault" ;;
    *) err "Invalid selection."; exit 1 ;;
  esac
fi

backup_file=""
case "$METHOD" in
  1|telegram|Telegram)
    botToken=$(cat "$AS_BOTKEY" 2>/dev/null)
    if [[ -z "$botToken" ]]; then
      read -rp "Telegram Bot Token: " botToken
      [[ -z "$botToken" ]] && { err "Bot token is required."; exit 1; }
    fi
    read -rp "Enter Telegram File ID: " file_id
    [[ -z "$file_id" ]] && { err "File ID cannot be empty."; exit 1; }

    info "Fetching file info from Telegram..."
    tg_resp=$(curl -s "https://api.telegram.org/bot${botToken}/getFile?file_id=${file_id}")
    file_path=$(echo "$tg_resp" | jq -r '.result.file_path // empty' 2>/dev/null)
    if [[ -z "$file_path" ]]; then
      err "Failed to resolve File ID from Telegram. Check token and File ID."
      exit 1
    fi

    backup_file="/tmp/tg_restore.zip"
    info "Downloading backup archive from Telegram..."
    curl -sSL -o "$backup_file" "https://api.telegram.org/file/bot${botToken}/${file_path}"
    ;;

  3|cloudvault|cloud-vault|CloudVault)
    cv_url=$(get_cloud_vault_url)
    if [[ -z "$cv_url" ]]; then
      read -rp "Enter Cloud Vault Base URL (e.g. https://cv.risqinf.dev): " cv_url
      [[ -z "$cv_url" ]] && { err "Cloud Vault URL cannot be empty."; exit 1; }
    fi
    read -rp "Enter Cloud Vault Restore Code: " cv_code
    [[ -z "$cv_code" ]] && { err "Restore code cannot be empty."; exit 1; }

    backup_file="/tmp/cv_restore.zip"
    download_cloudvault_archive "$cv_url" "$cv_code" "$backup_file" || exit 1
    ;;

  2|zip|manual|Zip|*)
    backup_file=$(ls -t "$backup_dir"/backup-*.zip 2>/dev/null | head -1)
    if [[ -z "$backup_file" || ! -f "$backup_file" ]]; then
      read -rp "Path to backup .zip file: " backup_file
    else
      echo -e " Found recent backup: ${GREEN}${backup_file}${NC}"
      read -rp " Use this backup? [Y/n]: " use_rec
      if [[ "$use_rec" =~ ^[nN] ]]; then
        read -rp "Path to backup .zip file: " backup_file
      fi
    fi
    ;;
esac

if [[ ! -f "$backup_file" || ! -s "$backup_file" ]]; then
  err "Backup file not found or empty at: ${backup_file}"
  exit 1
fi

if ! head -c 4 "$backup_file" 2>/dev/null | grep -q 'PK'; then
  err "Selected file is not a valid zip archive."
  exit 1
fi

which unzip >/dev/null 2>&1 || dnf install unzip -y >/dev/null 2>&1

pass_file="${AS_ETC}/backup.pass"
PASSWORD=""
if [[ -s "$pass_file" ]]; then
  PASSWORD=$(cat "$pass_file")
fi

if [[ -z "$PASSWORD" ]] || ! unzip -t -P "$PASSWORD" "$backup_file" &>/dev/null; then
  if [[ -n "$PASSWORD" ]]; then
    warn "Stored password in ${pass_file} did not match archive."
  fi
  read -rsp "Enter backup encryption password: " PASSWORD; echo
  [[ -z "$PASSWORD" ]] && { err "Password cannot be empty."; exit 1; }

  if ! unzip -t -P "$PASSWORD" "$backup_file" &>/dev/null; then
    err "Invalid archive or wrong encryption password."
    exit 1
  fi
fi

work="/root/.restore_work"
rm -rf "$work"; mkdir -p "$work"
unzip -o -P "$PASSWORD" "$backup_file" -d "$work" >/dev/null 2>&1

info "Restoring configuration and database..."
mkdir -p "$AS_ETC"; chmod 700 "$AS_ETC"
[[ -f "$work/etc/xray.db" ]]         && { cp -f "$work/etc/xray.db" "$AS_DB"; chmod 600 "$AS_DB"; ok "Database restored"; }
[[ -f "$work/etc/config.json" ]]     && { cp -f "$work/etc/config.json" "$AS_CONFIG"; ok "Config restored"; }
[[ -f "$work/etc/domain" ]]          && cp -f "$work/etc/domain" "$AS_DOMAIN_FILE"
[[ -f "$work/etc/bot.key" ]]         && { cp -f "$work/etc/bot.key" "$AS_BOTKEY"; chmod 600 "$AS_BOTKEY"; }
[[ -f "$work/etc/client.id" ]]       && { cp -f "$work/etc/client.id" "$AS_CHATID"; chmod 600 "$AS_CHATID"; }
[[ -f "$work/etc/cloudvault.url" ]]  && cp -f "$work/etc/cloudvault.url" "$AS_CLOUD_VAULT_URL"
[[ -f "$work/etc/autobackup.type" ]] && cp -f "$work/etc/autobackup.type" "$AS_AUTOBACKUP_TYPE"
[[ -f "$work/passwd" ]]              && cp -f "$work/passwd" /etc/
[[ -f "$work/shadow" ]]              && cp -f "$work/shadow" /etc/
[[ -f "$work/group" ]]               && cp -f "$work/group" /etc/
[[ -f "$work/gshadow" ]]             && cp -f "$work/gshadow" /etc/

printf '%s' "$PASSWORD" > "$pass_file"; chmod 600 "$pass_file"

rm -rf "$work"
[[ "$backup_file" == /tmp/*.zip ]] && rm -f "$backup_file"

info "Restarting services..."
systemctl restart xray 2>/dev/null
systemctl restart sshd 2>/dev/null
systemctl restart dropbear 2>/dev/null

line
ok "Restore operation complete successfully!"
line
