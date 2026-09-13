#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Module: RDNS Client Interactive TUI Menu
# Author / Credit: github: @risqinf
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================

# Load Autoscript common helpers
if [[ -f /usr/local/sbin/lib/common.sh ]]; then
  . /usr/local/sbin/lib/common.sh
elif [[ -f "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/common.sh" ]]; then
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/common.sh"
else
  # Fallback colors & primitives if standalone
  NC='\033[0m'
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  CYAN='\033[0;36m'
  WHITE='\033[1;37m'
  ORANGE='\033[38;5;208m'
  PINK='\033[38;5;205m'
  PILL_TITLE='\033[30;107m'
  ui_width() { echo 56; }
  ui_rep() { local ch="$1" n="$2" out=""; while (( n > 0 )); do out+="$ch"; ((n--)); done; printf '%s' "$out"; }
  ui_rule() { echo -e "${CYAN}$(ui_rep '═' 56)${NC}"; }
  ui_edge() { echo -e "${ORANGE}$(ui_rep '═' 56)${NC}"; }
  ui_foot() { ui_edge; }
  ui_header() {
    ui_edge
    printf "                  ${PILL_TITLE}[ %s ]${NC}\n" "$1"
    ui_edge
  }
  ui_label() { echo -e "  ${PILL_TITLE}[ $1 ]${NC}"; }
  ui_opt() { printf "  ${PINK}(•%2s)${NC} ${WHITE}│${NC} %b\n" "$1" "$2"; }
  ui_kv() { printf " ${WHITE}%-14s${NC} ${CYAN}:${NC} %b\n" "$1" "$2"; }
  ui_status() { printf " ${WHITE}%-14s${NC} ${CYAN}:${NC} %b\n" "$1" "$2"; }
  ui_back() { echo ""; read -n 1 -s -r -p " Press any key to return..."; }
  svc_badge() {
    if systemctl is-active --quiet "$1" 2>/dev/null; then
      echo -e "${PINK}[${GREEN} ON ${PINK}]${NC}"
    else
      echo -e "${PINK}[${RED} OFF ${PINK}]${NC}"
    fi
  }
  ok()   { echo -e " ${GREEN}[OK]${NC} $1"; }
  info() { echo -e " ${BLUE}[INFO]${NC} $1"; }
  warn() { echo -e " ${YELLOW}[WARN]${NC} $1"; }
  err()  { echo -e " ${RED}[ERROR]${NC} $1"; }
fi

# Locate rdns-manager
if command -v rdns-manager &>/dev/null; then
  RDNS_MGR="rdns-manager"
elif [[ -x /usr/local/sbin/rdns-manager ]]; then
  RDNS_MGR="/usr/local/sbin/rdns-manager"
elif [[ -x /usr/local/sbin/rdns/rdns-manager.sh ]]; then
  RDNS_MGR="/usr/local/sbin/rdns/rdns-manager.sh"
else
  RDNS_MGR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../rdns" && pwd)/rdns-manager.sh"
fi

get_rdns_status() {
  if type svc_badge &>/dev/null; then
    svc_badge rdns-client
  elif systemctl is-active rdns-client &>/dev/null; then
    echo -e "${PINK}[${GREEN} ON ${PINK}]${NC}"
  else
    echo -e "${PINK}[${RED} OFF ${PINK}]${NC}"
  fi
}

get_profile_list() {
  if [[ -f /etc/rdns/client.yaml ]]; then
    python3 -c "import yaml; cfg=yaml.safe_load(open('/etc/rdns/client.yaml')) or {}; print(' '.join([p.get('name','') for p in cfg.get('profiles',[])]))" 2>/dev/null || echo ""
  else
    echo ""
  fi
}

get_rules_count() {
  if [[ -f /etc/rdns/rules.json ]]; then
    python3 -c "import json; r=json.load(open('/etc/rdns/rules.json')); print(sum(len(v) for v in r.values()))" 2>/dev/null || echo "0"
  else
    echo "0"
  fi
}

menu_rdns() {
  clear
  local svc_st; svc_st=$(get_rdns_status)
  local profiles; profiles=$(get_profile_list)
  local prof_count; prof_count=$(echo "$profiles" | wc -w)
  local rules_count; rules_count=$(get_rules_count)

  ui_header "RDNS CLIENT (STEALTH TUNNEL)"
  ui_kv "Author / Credit" "${CYAN}github: @risqinf${NC}"
  ui_kv "Architecture"    "${GREEN}mTLS Yamux + Longest-Suffix DNS${NC}"
  ui_rule
  ui_status "RDNS Service"  "$svc_st"
  ui_kv "Active Nodes"    "${prof_count} Exit Node(s)"
  ui_kv "Routed Rules"    "${rules_count} Domain(s)"
  ui_rule
  ui_label "PAIRING & PROFILES"
  ui_opt 1  "Pair Exit Node Baru (Paste Token rdns://...)"
  ui_opt 2  "Status & Detail Exit Node Terpasang"
  ui_opt 3  "Hapus Profil Exit Node"
  ui_rule
  ui_label "RULES PRESETS (INSTANT LOAD)"
  ui_opt 4  "Terapkan Preset Rules ke Profil"
  ui_opt 5  "Hapus Preset Rules dari Profil"
  ui_rule
  ui_label "CUSTOM DOMAIN RULES"
  ui_opt 6  "Tambah Custom Domain Rule (Single / Multi koma)"
  ui_opt 7  "Hapus Custom Domain Rule"
  ui_opt 8  "Lihat Semua Routing Rules Aktif"
  ui_opt 9  "Test Routing Domain (Dry-Run Matcher)"
  ui_rule
  ui_label "MAINTENANCE"
  ui_opt 10 "Restart / Reload Service rdns-client"
  ui_rule
  ui_opt 0  "Kembali ke Menu Utama"
  ui_foot

  read -rp " Select option : " opt
  case "$opt" in
    1)
      clear
      ui_header "PAIR EXIT NODE BARU"
      ui_kv "Credit" "github: @risqinf" "$PINK"
      ui_rule
      echo -e " ${WHITE}Masukkan token pairing ${CYAN}rdns://...${WHITE} yang didapat dari Bot Store:${NC}"
      echo ""
      read -rp " Token Pairing: " user_token
      if [[ -z "$user_token" ]]; then
        err "Token tidak boleh kosong."
      else
        info "Memproses token pairing..."
        bash "$RDNS_MGR" pair "$user_token" || true
      fi
      ui_foot
      ui_back
      menu_rdns
      ;;

    2)
      clear
      ui_header "STATUS & DETAIL EXIT NODE"
      ui_kv "Credit" "github: @risqinf" "$PINK"
      ui_rule
      if [[ -f /etc/rdns/client.yaml ]]; then
        python3 - <<'EOF'
import yaml
try:
    with open('/etc/rdns/client.yaml', 'r') as f:
        cfg = yaml.safe_load(f) or {}
    profiles = cfg.get('profiles', [])
    if not profiles:
        print(" \033[1;33mBelum ada profil Exit Node yang terpasang.\033[0m")
    else:
        print(f" \033[1;37mTotal Exit Nodes Terdaftar:\033[0m \033[0;36m{len(profiles)}\033[0m\n")
        for i, p in enumerate(profiles, 1):
            print(f" \033[38;5;205m(•{i:2d})\033[0m \033[1;37m│\033[0m \033[1;32m{p.get('name')}\033[0m")
            print(f"       \033[0;36mServer Host  :\033[0m {p.get('server')}")
            print(f"       \033[0;36mServer Name  :\033[0m {p.get('server_name')}")
            print(f"       \033[0;36mDNS Upstream :\033[0m {p.get('dns')}")
            print(f"       \033[0;36mCert Serial  :\033[0m {p.get('cert_serial', 'N/A')}\n")
except Exception as e:
    print(f" \033[0;31mError membaca client.yaml: {e}\033[0m")
EOF
      else
        warn "File konfigurasi /etc/rdns/client.yaml belum dibuat."
      fi
      ui_foot
      ui_back
      menu_rdns
      ;;

    3)
      clear
      ui_header "HAPUS PROFIL EXIT NODE"
      ui_kv "Credit" "github: @risqinf" "$PINK"
      ui_rule
      local profs; profs=$(get_profile_list)
      if [[ -z "$profs" ]]; then
        warn "Belum ada profil Exit Node terdaftar."
      else
        echo -e " ${WHITE}Profil terdaftar:${NC} ${CYAN}${profs}${NC}"
        echo ""
        read -rp " Masukkan nama profil yang ingin dihapus: " del_prof
        if [[ -n "$del_prof" ]]; then
          read -rp " Yakin ingin menghapus profil '${del_prof}'? [y/N]: " confirm
          if [[ "$confirm" =~ ^[yY]$ ]]; then
            bash "$RDNS_MGR" remove-profile "$del_prof"
            ok "Profil '${del_prof}' telah dihapus."
          else
            info "Penghapusan dibatalkan."
          fi
        fi
      fi
      ui_foot
      ui_back
      menu_rdns
      ;;

    4)
      clear
      ui_header "TERAPKAN PRESET RULES"
      ui_kv "Credit" "github: @risqinf" "$PINK"
      ui_rule
      local profs; profs=$(get_profile_list)
      if [[ -z "$profs" ]]; then
        err "Belum ada profil Exit Node. Silakan pair profil terlebih dahulu."
      else
        echo -e " ${WHITE}Profil tersedia:${NC} ${CYAN}${profs}${NC}"
        read -rp " Masukkan nama profil target: " target_prof
        if [[ -z "$target_prof" ]]; then
          err "Nama profil tidak boleh kosong."
        else
          echo ""
          ui_rule
          ui_label "PILIH KATEGORI PRESET"
          ui_opt 1 "Streaming (Netflix, Disney+, Viu, Vidio, Prime, Crunchyroll, etc)"
          ui_opt 2 "Malaysia (TLD .my, Maybank, CIMB, TNG, Boost, Astro, Unifi)"
          ui_opt 3 "Indonesia (TLD .id, BCA, Mandiri, BRI, BNI, Dana, GoPay, Pajak)"
          ui_opt 4 "Bypass IP Check (ipinfo, speedtest, fast.com, ifconfig, etc)"
          ui_opt 5 "Google & YouTube (YouTube, Gmail, Play Store, Google Services)"
          ui_rule
          ui_opt 0 "Batal"
          ui_foot
          read -rp " Pilihan Preset [1-5]: " p_choice
          case "$p_choice" in
            1) bash "$RDNS_MGR" load-preset "$target_prof" "streaming" ;;
            2) bash "$RDNS_MGR" load-preset "$target_prof" "malaysia" ;;
            3) bash "$RDNS_MGR" load-preset "$target_prof" "indonesia" ;;
            4) bash "$RDNS_MGR" load-preset "$target_prof" "ipcheck" ;;
            5) bash "$RDNS_MGR" load-preset "$target_prof" "google" ;;
            0) info "Batal." ;;
            *) err "Pilihan tidak valid." ;;
          esac
        fi
      fi
      ui_foot
      ui_back
      menu_rdns
      ;;

    5)
      clear
      ui_header "HAPUS PRESET RULES"
      ui_kv "Credit" "github: @risqinf" "$PINK"
      ui_rule
      local profs; profs=$(get_profile_list)
      if [[ -z "$profs" ]]; then
        warn "Belum ada profil terdaftar."
      else
        echo -e " ${WHITE}Profil tersedia:${NC} ${CYAN}${profs}${NC}"
        read -rp " Masukkan nama profil target: " target_prof
        if [[ -n "$target_prof" ]]; then
          echo ""
          ui_rule
          ui_label "PILIH PRESET YANG INGIN DIHAPUS"
          ui_opt 1 "Streaming"
          ui_opt 2 "Malaysia"
          ui_opt 3 "Indonesia"
          ui_opt 4 "Bypass IP Check"
          ui_opt 5 "Google & YouTube"
          ui_rule
          ui_opt 0 "Batal"
          ui_foot
          read -rp " Pilihan [1-5]: " p_choice
          case "$p_choice" in
            1) bash "$RDNS_MGR" remove-preset "$target_prof" "streaming" ;;
            2) bash "$RDNS_MGR" remove-preset "$target_prof" "malaysia" ;;
            3) bash "$RDNS_MGR" remove-preset "$target_prof" "indonesia" ;;
            4) bash "$RDNS_MGR" remove-preset "$target_prof" "ipcheck" ;;
            5) bash "$RDNS_MGR" remove-preset "$target_prof" "google" ;;
            0) info "Batal." ;;
            *) err "Pilihan tidak valid." ;;
          esac
        fi
      fi
      ui_foot
      ui_back
      menu_rdns
      ;;

    6)
      clear
      ui_header "TAMBAH CUSTOM DOMAIN RULE"
      ui_kv "Credit" "github: @risqinf" "$PINK"
      ui_rule
      local profs; profs=$(get_profile_list)
      if [[ -z "$profs" ]]; then
        err "Belum ada profil Exit Node. Silakan pair terlebih dahulu."
      else
        echo -e " ${WHITE}Profil tersedia:${NC} ${CYAN}${profs}${NC}"
        read -rp " Masukkan nama profil target: " target_prof
        if [[ -n "$target_prof" ]]; then
          echo ""
          echo -e " ${WHITE}Masukkan domain (bisa single atau multi dipisah tanda koma):${NC}"
          echo -e " ${YELLOW}Contoh: openai.com, chatgpt.com, claude.ai${NC}"
          read -rp " Domain: " raw_doms
          if [[ -n "$raw_doms" ]]; then
            bash "$RDNS_MGR" add-rule "$target_prof" "$raw_doms"
            ok "Domain rule berhasil ditambahkan ke profil '${target_prof}'."
          fi
        fi
      fi
      ui_foot
      ui_back
      menu_rdns
      ;;

    7)
      clear
      ui_header "HAPUS CUSTOM DOMAIN RULE"
      ui_kv "Credit" "github: @risqinf" "$PINK"
      ui_rule
      local profs; profs=$(get_profile_list)
      if [[ -z "$profs" ]]; then
        warn "Belum ada profil terdaftar."
      else
        echo -e " ${WHITE}Profil tersedia:${NC} ${CYAN}${profs}${NC}"
        read -rp " Masukkan nama profil: " target_prof
        if [[ -n "$target_prof" ]]; then
          read -rp " Masukkan domain yang ingin dihapus (bisa pisah koma): " raw_doms
          if [[ -n "$raw_doms" ]]; then
            bash "$RDNS_MGR" remove-rule "$target_prof" "$raw_doms"
            ok "Domain rule berhasil dihapus."
          fi
        fi
      fi
      ui_foot
      ui_back
      menu_rdns
      ;;

    8)
      clear
      ui_header "ROUTING RULES AKTIF"
      ui_kv "Credit" "github: @risqinf" "$PINK"
      ui_rule
      bash "$RDNS_MGR" list-rules
      ui_foot
      ui_back
      menu_rdns
      ;;

    9)
      clear
      ui_header "TEST ROUTING DOMAIN"
      ui_kv "Credit" "github: @risqinf" "$PINK"
      ui_rule
      echo -e " ${WHITE}Uji apakah suatu domain akan dilewatkan ke Exit Node tertentu${NC}"
      echo -e " ${WHITE}menggunakan algoritma Longest-Suffix Matching.${NC}"
      echo ""
      read -rp " Masukkan domain yang akan diuji (contoh: fast.com, bca.co.id): " test_dom
      if [[ -n "$test_dom" ]]; then
        echo ""
        bash "$RDNS_MGR" test-domain "$test_dom"
      fi
      ui_foot
      ui_back
      menu_rdns
      ;;

    10)
      clear
      ui_header "RESTART / RELOAD RDNS SERVICE"
      ui_kv "Credit" "github: @risqinf" "$PINK"
      ui_rule
      info "Reloading / restarting rdns-client..."
      systemctl restart rdns-client 2>/dev/null || true
      sleep 1
      if systemctl is-active rdns-client &>/dev/null; then
        ok "rdns-client berhasil direstart dan berjalan aktif!"
      else
        warn "rdns-client tidak aktif. Cek log dengan: journalctl -u rdns-client -n 20"
      fi
      ui_foot
      ui_back
      menu_rdns
      ;;

    0|x|X)
      clear
      if command -v menu &>/dev/null; then
        menu
      elif [[ -x /usr/local/sbin/menu ]]; then
        /usr/local/sbin/menu
      fi
      exit 0
      ;;

    *)
      err "Pilihan tidak valid."
      sleep 1
      menu_rdns
      ;;
  esac
}

# Run menu if called directly
menu_rdns
