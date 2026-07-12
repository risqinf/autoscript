#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: AutoScript VPN & Tunneling Management System
# Developed for Rocky Linux 9
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
# System Uninstaller — removes everything install.sh created:
#   services, binaries, command scripts, libraries, database, configs,
#   cron entries, login profile, and (optionally) the swap file.
# It intentionally does NOT revert sshd_config or firewall rules, to avoid
# locking you out of an active session. Those are noted at the end.
# ========================================================
clear
echo ""
echo -e "\e[0;41;36m                 AUTOSCRIPT UNINSTALLER                     \e[0m"
echo ""

if [[ $EUID -ne 0 ]]; then
    echo -e "\e[31mError: must be run as root.\e[0m"
    exit 1
fi

echo -e "\e[31mWARNING: This removes ALL VPN/proxy configs, accounts, and the database!\e[0m"
read -rp "Type 'yes' to proceed: " confirm
if [[ "$confirm" != "yes" ]]; then
    echo "Uninstallation cancelled."
    exit 0
fi

# ---------------------------------------------------------------------------
echo "[1/9] Stopping and disabling services..."
SERVICES=(
    haproxy xray nginx dropbear ssh-ws server api-server
    quota limit-ip-vless quota-trojan limit-ip-trojan quota-vmess limit-ip-vmess
    autoexpire.timer limit-ip-ssh.timer backup.timer fixlog.timer
    openvpn-server@server-tcp-1194
)
for svc in "${SERVICES[@]}"; do
    systemctl stop "$svc" 2>/dev/null
    systemctl disable "$svc" 2>/dev/null
done

# ---------------------------------------------------------------------------
echo "[2/9] Removing systemd unit files..."
rm -f /etc/systemd/system/xray.service
rm -f /etc/systemd/system/ssh-ws.service
rm -f /etc/systemd/system/server.service
rm -f /etc/systemd/system/api-server.service
rm -f /etc/systemd/system/dropbear.service
rm -f /etc/systemd/system/quota.service
rm -f /etc/systemd/system/quota-trojan.service
rm -f /etc/systemd/system/quota-vmess.service
rm -f /etc/systemd/system/limit-ip-vless.service
rm -f /etc/systemd/system/limit-ip-trojan.service
rm -f /etc/systemd/system/limit-ip-vmess.service
# Scheduled-maintenance timers + their oneshot services (replaced cron).
rm -f /etc/systemd/system/autoexpire.timer   /etc/systemd/system/autoexpire.service
rm -f /etc/systemd/system/limit-ip-ssh.timer /etc/systemd/system/limit-ip-ssh.service
rm -f /etc/systemd/system/backup.timer       /etc/systemd/system/backup.service
rm -f /etc/systemd/system/fixlog.timer       /etc/systemd/system/fixlog.service
systemctl daemon-reload

# ---------------------------------------------------------------------------
echo "[3/9] Removing binaries and runtime files..."
rm -f /usr/local/bin/xray
rm -f /usr/local/bin/server
rm -f /usr/local/bin/api-server
rm -f /usr/local/bin/ssh-ws
rm -f /var/log/ssh-ws.log
rm -rf /usr/local/share/xray
rm -f /etc/rsyslog.d/00-autoscript-secure.conf
systemctl restart rsyslog 2>/dev/null

# ---------------------------------------------------------------------------
echo "[4/9] Removing management scripts, libraries, and API handlers..."
rm -rf /usr/local/sbin/api
rm -rf /usr/local/sbin/lib
rm -f /usr/local/sbin/db-migrate
for cmd in menu menu-ssh menu-vless menu-vmess menu-trojan menu-host menu-backup menu-api menu-dropbear menu-system \
    add-ssh add-vless add-vmess add-trojan add-bulk \
    trial-ssh trial-vless trial-vmess trial-trojan \
    delete-ssh delete-vless delete-vmess delete-trojan \
    renew-ssh renew-vless renew-vmess renew-trojan \
    recovery-ssh recovery-vless recovery-vmess recovery-trojan \
    cek-ssh cek-vless cek-vmess cek-trojan cek-user \
    config-ssh config-vless config-vmess config-trojan \
    list-ssh list-vless list-vmess list-trojan \
    limit-ip-ssh limit-ip-vless limit-ip-vmess limit-ip-trojan \
    loop-ip-vless loop-ip-vmess loop-ip-trojan \
    loop-quota-vless loop-quota-vmess loop-quota-trojan \
    quota-vless quota-vmess quota-trojan \
    xp-ssh xp-vless xp-vmess xp-trojan \
    backup restore fixlog versi-xray stream-check change-domain change-dns change-timezone status set-telegram uninstall; do
    rm -f "/usr/local/sbin/$cmd"
done

# ---------------------------------------------------------------------------
echo "[5/9] Removing SSH system users created by the script..."
# SSH accounts are real system users (useradd). Remove them with userdel
# --force BEFORE deleting the database (the DB is our list of who we created),
# so we never touch unrelated/system accounts.
if [[ -f /etc/xray/xray.db ]] && command -v sqlite3 >/dev/null 2>&1; then
    mapfile -t _ssh_users < <(sqlite3 /etc/xray/xray.db \
        "SELECT username FROM accounts WHERE protocol='ssh';" 2>/dev/null | sort -u)
    for u in "${_ssh_users[@]}"; do
        [[ -z "$u" ]] && continue
        if id "$u" &>/dev/null; then
            pkill -KILL -u "$u" 2>/dev/null
            userdel --force "$u" >/dev/null 2>&1 && echo "  - removed user: $u"
        fi
    done
    [[ ${#_ssh_users[@]} -eq 0 ]] && echo "  (no SSH users recorded in database)"
else
    echo "  (database not found; skipping user removal)"
fi

# ---------------------------------------------------------------------------
echo "[6/9] Removing configs, database, and web/log directories..."
rm -rf /etc/xray                       # config.json, xray.db, domain, keys, backup.pass
rm -f  /etc/nginx/risqinf.conf
# Restore a stock nginx.conf (ours 'include's the now-removed risqinf.conf,
# which would otherwise make nginx fail to start).
if [[ -f /etc/nginx/nginx.conf ]] && grep -q "risqinf.conf" /etc/nginx/nginx.conf; then
    if [[ -f /etc/nginx/nginx.conf.rpmsave ]]; then
        mv -f /etc/nginx/nginx.conf.rpmsave /etc/nginx/nginx.conf
    else
        rm -f /etc/nginx/nginx.conf
    fi
fi
# HAProxy config + combined cert (created by the installer).
rm -f  /etc/haproxy/haproxy.cfg
rm -f  /etc/haproxy/haproxy.pem
# Let's Encrypt / acme.sh material for this server (best effort).
rm -rf /root/.acme.sh 2>/dev/null
rm -rf /etc/dropbear
rm -rf /etc/openvpn
rm -rf /var/www/html/risqinf
rm -rf /var/log/xray

# ---------------------------------------------------------------------------
echo "[7/9] Cleaning up legacy crontab entries and login profile..."
# Newer installs use systemd timers (removed above), but strip any leftover
# crontab lines from older cron-based installs so nothing dangles.
for pat in xp-ssh xp-vless xp-vmess xp-trojan limit-ip-ssh backup fixlog cek-; do
    sed -i "/ $pat/d" /etc/crontab 2>/dev/null
done
systemctl restart crond 2>/dev/null || true
# Restore a normal root login profile (installer set 'clear ; menu').
[[ -f /root/.profile ]] && grep -q "menu" /root/.profile && : > /root/.profile

# ---------------------------------------------------------------------------
echo "[8/9] Optional: remove swap file created by the installer..."
if [[ -f /swapfile ]]; then
    read -rp "Remove /swapfile too? (y/N): " rmswap
    if [[ "$rmswap" =~ ^[Yy]$ ]]; then
        swapoff /swapfile 2>/dev/null
        sed -i '/swapfile/d' /etc/fstab 2>/dev/null
        rm -f /swapfile
        echo "  Swap removed."
    fi
fi

# ---------------------------------------------------------------------------
echo "[9/9] Removing packages and firewall rules (best effort)..."
# Close the ports the installer opened (leave 22 so you keep SSH access).
for p in 3303/tcp 109/tcp 80/tcp 443/tcp 1194/tcp; do
    firewall-cmd --permanent --zone=public --remove-port="$p" >/dev/null 2>&1
done
for p in 7300/udp; do
    firewall-cmd --permanent --zone=public --remove-port="$p" >/dev/null 2>&1
done
firewall-cmd --permanent --remove-masquerade >/dev/null 2>&1
firewall-cmd --reload >/dev/null 2>&1
dnf remove haproxy nginx dropbear openvpn easy-rsa -y >/dev/null 2>&1

echo ""
echo -e "\e[0;42;30m              UNINSTALLATION COMPLETE                       \e[0m"
echo ""
echo "Not reverted (to avoid lockout) — adjust manually if desired:"
echo "  - /etc/ssh/sshd_config (Port 22/3303, root login, password auth)"
echo "  - /etc/sysctl.conf network tuning"
echo "  - rsyslog package (kept; only the drop-in was removed)"
echo "It is recommended to reboot the server."

# Self-delete: remove this uninstaller script after a successful run.
INSTALLED_CMD="/usr/local/sbin/uninstall"
[[ -f "$INSTALLED_CMD" ]] && rm -f "$INSTALLED_CMD" 2>/dev/null
rm -f -- "$0" 2>/dev/null
exit 0
