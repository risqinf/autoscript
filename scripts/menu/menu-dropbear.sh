#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: AutoScript VPN & Tunneling Management System
# Developed for Rocky Linux 9
# ========================================================
[[ -f /usr/local/sbin/lib/common.sh ]] && . /usr/local/sbin/lib/common.sh
BIGreen='\033[1;92m'
BIRed='\033[1;91m'
BIYellow='\033[1;93m'
BIWhite='\033[1;97m'
DROPBEAR_BIN="/usr/sbin/dropbear"
DROPBEAR_LIB="/usr/lib/dropbear"
DROPBEAR_CONFIG="/etc/dropbear"
DROPBEAR_MAN="/usr/share/man/man8/dropbear.8.gz"
DROPBEAR_URL="https://matt.ucc.asn.au/dropbear/releases"
clear
ui_header "DROPBEAR MANAGER"
echo -e " Current: ${GREEN}$(/usr/sbin/dropbear -V 2>&1)${NC}"
ui_rule
ui_opt 1 "Version 2018.76  (Recommended)"
ui_opt 2 "Version 2019.78  (Recommended)"
ui_opt 3 "Version 2020.81  (Stable)"
ui_opt 4 "Version 2022.82  (Stable)"
ui_opt 5 "Version 2024.86  (New)"
ui_rule
ui_opt 0 "Back to Menu"
ui_foot
read -rp " Select menu : " opt
echo -e ""
case $opt in
1) clear ; DROPBEAR_VERSION="2018.76" ;;
2) clear ; DROPBEAR_VERSION="2019.78" ;;
3) clear ; DROPBEAR_VERSION="2020.81" ;;
4) clear ; DROPBEAR_VERSION="2022.82" ;;
5) clear ; DROPBEAR_VERSION="2024.86" ;;
0|x|X) clear ; menu ; exit ;;
*) err "Invalid option." ; sleep 1 ; menu ;;
esac

clear
ui_header "INSTALLING DROPBEAR ${DROPBEAR_VERSION}"

# Hentikan Dropbear jika berjalan
if systemctl stop dropbear || service dropbear stop; then
    echo -e "${BIGreen}Dropbear dihentikan.${BIWhite}"
else
    echo -e "${BIRed}Gagal menghentikan Dropbear.${BIWhite}"
fi

clear
if [ -f "$DROPBEAR_BIN" ]; then
    echo -e "${BIGreen}Backup versi lama Dropbear...${BIWhite}"
    cp $DROPBEAR_BIN /usr/sbin/dropbear.bak
fi

rm -f $DROPBEAR_BIN $DROPBEAR_LIB/* $DROPBEAR_CONFIG/* $DROPBEAR_MAN
clear

# Install dependensi
dnf groupinstall "Development Tools" -y && dnf install zlib-devel curl bzip2 -y
clear

BUILD_DIR=$(mktemp -d /tmp/dropbear-build.XXXXXX)
chmod 700 "$BUILD_DIR"
cd "$BUILD_DIR" || exit 1

# Download Dropbear with strict HTTPS/TLS verification
echo -e "${BIGreen}Mengunduh Dropbear versi $DROPBEAR_VERSION (TLS Verified)...${BIWhite}"
curl -fsSL --proto '=https' --tlsv1.2 --max-time 60 -o dropbear.tar.bz2 "$DROPBEAR_URL/dropbear-$DROPBEAR_VERSION.tar.bz2" || \
curl -fsSL --proto '=https' --tlsv1.2 --max-time 60 -o dropbear.tar.bz2 "https://dropbear.nl/mirror/releases/dropbear-$DROPBEAR_VERSION.tar.bz2"

# Periksa apakah file berhasil diunduh & valid bzip2 archive
if [[ ! -s "dropbear.tar.bz2" ]] || ! bzip2 -t dropbear.tar.bz2 2>/dev/null; then
    rm -rf "$BUILD_DIR"
    [[ -f /usr/sbin/dropbear.bak ]] && cp -f /usr/sbin/dropbear.bak "$DROPBEAR_BIN"
    echo -e "${BIRed}Download atau verifikasi arsip gagal, periksa koneksi internet.${BIWhite}"
    echo -e "${BIWhite}Press any key to menu${NC}"
    read -n 1 -s -r
    menu
    exit 1
fi

# Ekstrak file
tar -xjf dropbear.tar.bz2
cd "dropbear-$DROPBEAR_VERSION" || { rm -rf "$BUILD_DIR"; exit 1; }

clear
if ./configure --prefix=/usr && make && make install; then
    echo -e "${BIGreen}Kompilasi berhasil.${BIWhite}"
else
    echo -e "${BIRed}Kompilasi gagal.${BIWhite}"
    echo -e "${BIWhite}Press any key to menu${NC}"
    read -n 1 -s -r
    menu
fi

clear
mv /usr/bin/dropbear $DROPBEAR_BIN
mkdir -p $DROPBEAR_LIB
mkdir -p $DROPBEAR_CONFIG
if [ -f "/usr/share/man/man8/dropbear.8.gz" ]; then
    mv /usr/share/man/man8/dropbear.8.gz $DROPBEAR_MAN
else
    echo -e "${BIYellow}File man tidak ditemukan.${BIWhite}"
fi

clear
# Buat ulang key
rm -f /etc/dropbear/dropbear_rsa_host_key
rm -f /etc/dropbear/dropbear_dss_host_key
rm -f /etc/dropbear/dropbear_ecdsa_host_key

dropbearkey -t rsa -f /etc/dropbear/dropbear_rsa_host_key
dropbearkey -t dss -f /etc/dropbear/dropbear_dss_host_key
dropbearkey -t ecdsa -f /etc/dropbear/dropbear_ecdsa_host_key

chmod 600 /etc/dropbear/dropbear_rsa_host_key
chmod 600 /etc/dropbear/dropbear_dss_host_key
chmod 600 /etc/dropbear/dropbear_ecdsa_host_key

clear
if systemctl start dropbear || service dropbear start; then
    echo -e "${BIGreen}Dropbear berhasil dimulai.${BIWhite}"
else
    echo -e "${BIRed}Gagal memulai Dropbear.${BIWhite}"
fi

clear
if dropbear -V; then
    echo -e "${BIGreen}Dropbear versi $DROPBEAR_VERSION telah terinstal.${BIWhite}"
else
    echo -e "${BIRed}Verifikasi gagal, Dropbear mungkin tidak terinstal dengan benar.${BIWhite}"
fi

clear
cd /root || cd /
rm -rf "$BUILD_DIR"

# Pesan akhir
ui_rule
echo -e "${BIGreen}Dropbear version $DROPBEAR_VERSION installed successfully!${NC}"
echo -e ""
read -n 1 -s -r -p " Press any key to return..."
menu