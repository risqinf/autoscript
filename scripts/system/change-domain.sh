#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: AutoScript VPN & Tunneling Management System
# Developed for Rocky Linux 9
# ========================================================
# ========================================================
# Domain Changer
# ========================================================
[[ -f /usr/local/sbin/lib/common.sh ]] && . /usr/local/sbin/lib/common.sh
clear
ui_header "CHANGE DOMAIN"

old_domain=$(cat /etc/xray/domain 2>/dev/null)
echo "Current Domain: $old_domain"
read -p "Enter New Domain: " new_domain

if [[ -z "$new_domain" ]]; then
    echo "Domain cannot be empty."
    exit 1
fi

# Validasi format domain (cegah injeksi ke sed/certbot/nginx)
if ! [[ "$new_domain" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    echo "Invalid domain format."
    exit 1
fi

echo "Stopping services..."
systemctl stop haproxy nginx xray

echo "Updating domain configuration..."
echo "$new_domain" > /etc/xray/domain
sed -i "s|${old_domain}|${new_domain}|g" /etc/nginx/risqinf.conf 2>/dev/null || true
sed -i "s|${old_domain}|${new_domain}|g" /var/www/html/index.html 2>/dev/null || true

echo "Requesting new SSL certificate..."
obtain_ssl_certificates "$new_domain"

echo "Starting services..."
systemctl restart nginx xray haproxy 2>/dev/null || true
svc_active noobzvpns && systemctl restart noobzvpns 2>/dev/null || true

echo "Domain changed to: $new_domain"
read -n 1 -s -r -p "Press any key to return to menu..."
menu