#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: NoobzVPN management submenu
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
[[ -f /usr/local/sbin/lib/common.sh ]] && . /usr/local/sbin/lib/common.sh

menu_noobz() {
    clear
    ui_header "NOOBZVPN PANEL"
    ui_status "Service Status" "$(svc_badge noobzvpns)"
    ui_rule
    ui_opt 1 "Create Account"
    ui_opt 2 "Trial Account"
    ui_opt 3 "Delete Account"
    ui_opt 4 "Renew Account"
    ui_opt 5 "List Accounts"
    ui_opt 6 "Check Config / Details"
    ui_opt 7 "Recovery Account"
    ui_opt 8 "Check Login (live device IDs)"
    ui_opt 9 "Restart NoobzVPN Service"
    ui_rule
    ui_opt 0 "Back to Main Menu"
    ui_foot
    read -rp " Select option : " opt
    case "$opt" in
        1) add-noobz ;;
        2) trial-noobz ;;
        3) delete-noobz ;;
        4) renew-noobz ;;
        5) list-noobz ;;
        6) config-noobz ;;
        7) recovery-noobz ;;
        8) cek-noobz ;;
        9)
            systemctl restart noobzvpns
            ok "NoobzVPN service restarted."
            read -rp " Press Enter to continue..."
            menu_noobz
            ;;
        0|x|X) menu ;;
        *) err "Invalid option."; sleep 1; menu_noobz ;;
    esac
}

menu_noobz
