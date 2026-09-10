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
sed -i "s|${old_domain}|${new_domain}|g" /etc/nginx/risqinf.conf
sed -i "s|${old_domain}|${new_domain}|g" /var/www/html/index.html 2>/dev/null

echo "Requesting new SSL certificate..."
dnf install socat lsof certbot -y >/dev/null 2>&1

yes Y | certbot certonly --standalone --preferred-challenges http --agree-tos --email www@${new_domain} -d "$new_domain"

if [[ -f /etc/letsencrypt/live/$new_domain/fullchain.pem ]]; then
    cp /etc/letsencrypt/live/$new_domain/fullchain.pem /etc/xray/xray.crt
    cp /etc/letsencrypt/live/$new_domain/privkey.pem /etc/xray/xray.key
    chmod 600 /etc/xray/xray.key
    chmod 644 /etc/xray/xray.crt
    
    # Update HAProxy certificate
    cat /etc/xray/xray.crt /etc/xray/xray.key | tee /etc/haproxy/haproxy.pem > /dev/null
    chmod 600 /etc/haproxy/haproxy.pem

    # Update NoobzVPN certificate
    if [[ -d /etc/noobzvpns ]]; then
        cp -f /etc/xray/xray.crt /etc/noobzvpns/cert.pem
        cp -f /etc/xray/xray.key /etc/noobzvpns/key.pem
        chmod 600 /etc/noobzvpns/key.pem /etc/noobzvpns/cert.pem 2>/dev/null || true
    fi
    
    echo "SSL Certificate updated successfully."
else
    echo -e "\e[31mFailed to get SSL certificate. Check your DNS records.\e[0m"
fi

echo "Starting services..."
systemctl start nginx xray haproxy
svc_active noobzvpns && systemctl restart noobzvpns 2>/dev/null || true

echo "Domain changed to: $new_domain"
read -n 1 -s -r -p "Press any key to return to menu..."
menu