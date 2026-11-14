#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: AutoScript VPN & Tunneling Management System
# Developed for Rocky Linux 9
# ========================================================
[[ -f /usr/local/sbin/lib/common.sh ]] && . /usr/local/sbin/lib/common.sh

# Warna
green='\033[0;92m'
red='\033[0;91m'
yellow='\033[0;93m'

cert() {
    clear
    local domain
    domain=$(cat /etc/xray/domain 2>/dev/null || echo "")
    if [[ -z "$domain" ]]; then
        err "No domain configured in /etc/xray/domain."
        read -n 1 -s -r -p "Press any key to return..."
        menu
        return
    fi

    echo -e "[ ${green}INFO${NC} ] Starting SSL certificate issuance / renewal for ${domain}..."
    sleep 0.5

    obtain_ssl_certificates "$domain"

    echo -e "[ ${green}INFO${NC} ] Restarting services..."
    systemctl restart nginx haproxy xray 2>/dev/null || true
    svc_active noobzvpns && systemctl restart noobzvpns 2>/dev/null || true

    echo -e "[ ${green}INFO${NC} ] Process finished."
    echo ""
    read -n 1 -s -r -p "Press any key to back on menu"
    menu
}

addhost() {
    clear
    ui_header "CHANGE DOMAIN / HOST"
    echo -e " Current domain:"
    echo -e " ${GREEN}$(cat /etc/xray/domain)${NC}"
    echo ""
    read -rp " New Domain/Host: " -e host
    host=$(echo "$host" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    echo ""
    if [ -z "$host" ]; then
        warn "No change made."
        ui_rule
        read -n 1 -s -r -p " Press any key to return..."
        menu
    elif ! valid_domain "$host"; then
        err "Invalid domain format."
        ui_rule
        read -n 1 -s -r -p " Press any key to return..."
        menu
    else
        old=$(cat /etc/xray/domain 2>/dev/null | tr -d '\r\n')
        echo "$host" > /etc/xray/domain
        if [[ -n "$old" && -f /etc/nginx/risqinf.conf ]]; then
            sed -i "s|server_name ${old};|server_name ${host};|g" /etc/nginx/risqinf.conf
        fi
        ui_rule
        read -n 1 -s -r -p " Press any key to renew cert..."
        cert
    fi
}

menu1() {
    clear
    ui_header "DOMAIN & CERTIFICATE"
    ui_opt 1 "Change Hostname / Domain / Subdomain"
    ui_opt 2 "Renew Certificate (current domain)"
    ui_rule
    ui_opt 0 "Back to Menu"
    ui_foot
    read -rp " Select option : " ope
    case $ope in
        1) addhost ;;
        2) cert ;;
        0|x|X) menu ;;
        *) clear ; menu1 ;;
    esac
}

menu1
