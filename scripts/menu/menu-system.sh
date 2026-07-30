#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: System & maintenance submenu
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
[[ -f /usr/local/sbin/lib/common.sh ]] && . /usr/local/sbin/lib/common.sh

menu_system() {
    clear
    ui_header "SYSTEM PANEL"
    ui_opt 1  "Change Domain / Renew SSL"
    ui_opt 2  "Change DNS"
    ui_opt 3  "Stream / Media Check"
    ui_opt 4  "Speedtest"
    ui_opt 5  "Xray Core Version"
    ui_opt 6  "Dropbear Version"
    ui_opt 7  "Change Timezone"
    ui_opt 8  "Service Status"
    ui_opt 9  "Telegram Setup"
    ui_opt 10 "Limit Speed (Bandwidth Shaper)"
    ui_opt 11 "Bandwidth Monitor (vnstat)"
    ui_opt 12 "Uninstall Script"
    ui_rule
    ui_opt 0 "Back to Main Menu"
    ui_foot
    read -rp " Select option : " opt
    case "$opt" in
        1) clear ; menu-host ;;
        2) clear ; change-dns ;;
        3) clear ; stream-check ;;
        4) clear ; echo -e "YES" | speedtest ; ui_back ; menu_system ;;
        5) clear ; versi-xray ;;
        6) clear ; menu-dropbear ;;
        7) clear ; change-timezone ;;
        8) clear ; status ;;
        9) clear ; set-telegram ;;
        10) clear ; limit-speed ; ui_back ; menu_system ;;
        11) clear ; bw-monitor ; ui_back ; menu_system ;;
        12) clear ; uninstall ;;
        0|x|X) clear ; menu ;;
        *) err "Invalid option."; sleep 1; menu_system ;;
    esac
}

menu_system
