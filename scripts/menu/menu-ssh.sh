#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: SSH / OpenVPN management submenu
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
[[ -f /usr/local/sbin/lib/common.sh ]] && . /usr/local/sbin/lib/common.sh

menu_ssh() {
    clear
    ui_header "SSH / OPENVPN PANEL"
    ui_opt 1 "Create Account"
    ui_opt 2 "Trial Account"
    ui_opt 3 "Delete Account"
    ui_opt 4 "Renew Account"
    ui_opt 5 "List Accounts"
    ui_opt 6 "Check Config / Details"
    ui_opt 7 "Recovery Account"
    ui_opt 8 "Check Login (live)"
    ui_opt 9  "Change Dropbear Version"
    ui_opt 10 "Change WS Banner  (/etc/issue.net)"
    ui_rule
    ui_opt 0  "Back to Main Menu"
    ui_foot
    read -rp " Select option : " opt
    case "$opt" in
        1)  add-ssh ;;
        2)  trial-ssh ;;
        3)  delete-ssh ;;
        4)  renew-ssh ;;
        5)  list-ssh ;;
        6)  config-ssh ;;
        7)  recovery-ssh ;;
        8)  cek-ssh ;;
        9)  menu-dropbear ;;
        10) change-banner ;;
        0|x|X) menu ;;
        *) err "Invalid option."; sleep 1; menu_ssh ;;
    esac
}

menu_ssh
