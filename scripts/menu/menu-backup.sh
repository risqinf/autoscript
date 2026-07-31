#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf & sela-putri
# Description: Backup & Restore sub-menu (Telegram, Zip, Cloud Vault)
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
[[ -f /usr/local/sbin/lib/common.sh ]] && . /usr/local/sbin/lib/common.sh

menu_backup() {
    clear
    ui_header "BACKUP & RESTORE MENU"

    local current_auto; current_auto=$(get_autobackup_type)
    local auto_disp
    case "$current_auto" in
      telegram)   auto_disp="Telegram Bot" ;;
      cloudvault) auto_disp="Cloud Vault" ;;
      zip|*)      auto_disp="Manual File Zip (Default)" ;;
    esac

    local cv_url; cv_url=$(get_cloud_vault_url)
    [[ -z "$cv_url" ]] && cv_url="(not set: url=\"\")"

    ui_status "Auto Backup " "${GREEN}[ ${auto_disp} ]${NC}"
    ui_status "Cloud Vault " "${CYAN}[ ${cv_url} ]${NC}"
    ui_rule

    ui_opt 1 "Backup Data now"
    ui_opt 2 "Restore Data from backup"
    ui_opt 3 "Auto-Backup Settings (Select Method)"
    ui_opt 4 "Configure Cloud Vault URL"
    ui_rule
    ui_opt 0 "Back to Main Menu"
    ui_foot
    read -rp " Select option : " opt
    case "$opt" in
        1)
            clear
            ui_header "BACKUP METHOD"
            ui_opt 1 "Telegram Bot (Send file to Telegram)"
            ui_opt 2 "Manual File Zip (Save to local /root)"
            ui_opt 3 "Cloud Vault (Upload to Cloud Vault API)"
            ui_rule
            ui_opt 0 "Cancel"
            ui_foot
            read -rp " Select backup method : " bopt
            case "$bopt" in
                1) clear ; backup telegram ; ui_back ; menu_backup ;;
                2) clear ; backup zip ; ui_back ; menu_backup ;;
                3) clear ; backup cloudvault ; ui_back ; menu_backup ;;
                0|x|X) menu_backup ;;
                *) err "Invalid option."; sleep 1; menu_backup ;;
            esac
            ;;
        2)
            clear
            ui_header "RESTORE METHOD"
            ui_opt 1 "Telegram Bot (File ID)"
            ui_opt 2 "Manual File Zip (Local file path)"
            ui_opt 3 "Cloud Vault (Restore Code)"
            ui_rule
            ui_opt 0 "Cancel"
            ui_foot
            read -rp " Select restore method : " ropt
            case "$ropt" in
                1) clear ; restore telegram ; ui_back ; menu_backup ;;
                2) clear ; restore zip ; ui_back ; menu_backup ;;
                3) clear ; restore cloudvault ; ui_back ; menu_backup ;;
                0|x|X) menu_backup ;;
                *) err "Invalid option."; sleep 1; menu_backup ;;
            esac
            ;;
        3)
            clear
            ui_header "AUTO-BACKUP SETTINGS"
            echo -e " Select auto-backup type used by automatic schedule:"
            ui_opt 1 "Manual File Zip (Save locally in /root)"
            ui_opt 2 "Telegram Bot (Send archive to Telegram)"
            ui_opt 3 "Cloud Vault (Upload to Cloud Vault)"
            ui_rule
            ui_opt 0 "Cancel"
            ui_foot
            read -rp " Select option : " aopt
            case "$aopt" in
                1)
                    mkdir -p "$AS_ETC"
                    printf "zip" > "$AS_AUTOBACKUP_TYPE"
                    ok "Auto-backup type set to Manual File Zip."
                    sleep 1; menu_backup
                    ;;
                2)
                    mkdir -p "$AS_ETC"
                    printf "telegram" > "$AS_AUTOBACKUP_TYPE"
                    ok "Auto-backup type set to Telegram Bot."
                    sleep 1; menu_backup
                    ;;
                3)
                    mkdir -p "$AS_ETC"
                    printf "cloudvault" > "$AS_AUTOBACKUP_TYPE"
                    ok "Auto-backup type set to Cloud Vault."
                    sleep 1; menu_backup
                    ;;
                0|x|X) menu_backup ;;
                *) err "Invalid option."; sleep 1; menu_backup ;;
            esac
            ;;
        4)
            clear
            ui_header "CONFIGURE CLOUD VAULT"
            local cur; cur=$(get_cloud_vault_url)
            echo -e " Current Cloud Vault URL: ${CYAN}${cur:-"(not set)"}${NC}"
            echo -e " Repository: https://github.com/sela-putri/cloud-vault"
            line
            read -rp " Enter Cloud Vault URL (e.g. https://vault.example.com): " new_url
            if [[ -n "$new_url" ]]; then
                mkdir -p "$AS_ETC"
                printf '%s' "$new_url" > "$AS_CLOUD_VAULT_URL"
                ok "Cloud Vault URL updated to: ${new_url}"
            else
                warn "Cloud Vault URL remains unchanged."
            fi
            sleep 2; menu_backup
            ;;
        0|x|X) clear ; menu ;;
        *) err "Invalid option."; sleep 1; menu_backup ;;
    esac
}

menu_backup
