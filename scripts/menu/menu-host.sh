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

function install_acme() {
    if [ ! -f ~/.acme.sh/acme.sh ]; then
        echo -e "[ ${yellow}INFO${NC} ] acme.sh not found, installing..."
        curl https://get.acme.sh | sh
        export PATH=~/.acme.sh:$PATH
    fi

    random_prefix=$(tr -dc a-z </dev/urandom | head -c5)
    random_number=$(shuf -i 1000-9999 -n 1)
    acme_email="${random_prefix}${random_number}@risqinf.biz.id"

    if [ ! -f ~/.acme.sh/account.conf ]; then
        echo -e "[ ${green}INFO${NC} ] Registering new account with email: $acme_email"
        ~/.acme.sh/acme.sh --register-account -m "$acme_email" --agree-tos > /dev/null 2>&1
    else
        echo -e "[ ${green}INFO${NC} ] ACME account already exists. Using existing."
    fi
}

cert() {
    clear
    install_acme

    echo -e "[ ${green}INFO${NC} ] Start "
    sleep 0.5
    systemctl stop nginx haproxy

    domain=$(cat /etc/xray/domain)
    rm -f /etc/xray/xray.crt /etc/xray/xray.key

    sleep 1
    echo -e "[ ${red}WARNING${NC} ] Detected port 80 used by Nginx/HAProxy "
    sleep 2
    echo -e "[ ${green}INFO${NC} ] Processing to stop Nginx and HAProxy "
    sleep 1

    clear
    echo -e "[ ${green}INFO${NC} ] Starting renew cert... "
    sleep 2
    clear

    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    ~/.acme.sh/acme.sh --issue -d $domain --standalone -k ec-256
    ~/.acme.sh/acme.sh --installcert -d $domain \
        --fullchainpath /etc/xray/xray.crt \
        --keypath /etc/xray/xray.key \
        --ecc
        
    # Update HAProxy combined certificate
    cat /etc/xray/xray.crt /etc/xray/xray.key | tee /etc/haproxy/haproxy.pem > /dev/null
    chmod 600 /etc/xray/xray.key /etc/haproxy/haproxy.pem 2>/dev/null

    # Update NoobzVPN certificate
    if [[ -d /etc/noobzvpns ]]; then
        cp -f /etc/xray/xray.crt /etc/noobzvpns/cert.pem
        cp -f /etc/xray/xray.key /etc/noobzvpns/key.pem
        chmod 600 /etc/noobzvpns/key.pem /etc/noobzvpns/cert.pem 2>/dev/null || true
    fi

    sleep 2
    clear
    echo -e "[ ${green}INFO${NC} ] Renew cert done... "
    sleep 2
    clear
    echo -e "[ ${green}INFO${NC} ] Restarting services... "
    sleep 2

    systemctl restart nginx haproxy xray
    svc_active noobzvpns && systemctl restart noobzvpns 2>/dev/null || true
    sleep 0.5
    clear
    echo -e "[ ${green}INFO${NC} ] All finished... "
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
    echo ""
    if [ -z "$host" ]; then
        warn "No change made."
        ui_rule
        read -n 1 -s -r -p " Press any key to return..."
        menu
    else
        cat /etc/xray/domain > /etc/xray/domain.bak
        echo "$host" > /etc/xray/domain
        old=$(cat /etc/xray/domain.bak)
        sed -i "s|server_name ${old};|server_name ${host};|" /etc/nginx/risqinf.conf
        rm -f /etc/xray/domain.bak
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
