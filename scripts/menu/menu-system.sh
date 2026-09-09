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
    ui_opt 8  "Service Manager (Status / On-Off / Restart)"
    ui_opt 9  "Restart All Services"
    ui_opt 10 "Telegram Setup"
    ui_opt 11 "Limit Speed (Bandwidth Shaper)"
    ui_opt 12 "Bandwidth Monitor (vnstat)"
    ui_opt 13 "Uninstall Script"
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
        9)
            clear
            ui_header "RESTART ALL SERVICES"
            echo ""
            info "Restarting all core services..."
            systemctl restart haproxy nginx xray sshd dropbear ssh-ws 2>/dev/null
            svc_active openvpn-server@server-tcp-1194 && systemctl restart openvpn-server@server-tcp-1194 2>/dev/null || true
            svc_active squid && systemctl restart squid 2>/dev/null || true
            svc_active noobzvpns && systemctl restart noobzvpns 2>/dev/null || true
            svc_active slowdns && systemctl restart slowdns 2>/dev/null || true
            svc_active api-server && systemctl restart api-server 2>/dev/null || true
            ok "All services restarted successfully."
            echo ""
            read -rp " Press Enter to continue..."
            menu_system
            ;;
        10) clear ; set-telegram ;;
        11) clear ; limit-speed ; ui_back ; menu_system ;;
        12) clear ; bw-monitor ; ui_back ; menu_system ;;
        13) clear ; uninstall ;;
        0|x|X) clear ; menu ;;
        *) err "Invalid option."; sleep 1; menu_system ;;
    esac
}

menu_system
