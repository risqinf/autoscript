#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: Shared common helpers (colors, validation, IO)
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
# Source this file:  . /usr/local/sbin/lib/common.sh
# Guard against double-sourcing.
[[ -n "${__AS_COMMON_LOADED:-}" ]] && return 0
__AS_COMMON_LOADED=1

# --- Paths ---
export AS_ETC="/etc/xray"
export AS_DB="${AS_ETC}/xray.db"
export AS_CONFIG="${AS_ETC}/config.json"
export AS_DOMAIN_FILE="${AS_ETC}/domain"
export AS_BOTKEY="${AS_ETC}/bot.key"
export AS_CHATID="${AS_ETC}/client.id"
export AS_CLOUD_VAULT_URL="${AS_ETC}/cloudvault.url"
export AS_AUTOBACKUP_TYPE="${AS_ETC}/autobackup.type"
export AS_LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

get_cloud_vault_url() {
  if [[ -s "$AS_CLOUD_VAULT_URL" ]]; then
    cat "$AS_CLOUD_VAULT_URL" 2>/dev/null
  else
    echo ""
  fi
}

get_autobackup_type() {
  if [[ -s "$AS_AUTOBACKUP_TYPE" ]]; then
    cat "$AS_AUTOBACKUP_TYPE" 2>/dev/null
  else
    echo "zip"
  fi
}

download_cloudvault_archive() {
  local cv_url="$1"
  local cv_code="$2"
  local dest="$3"
  local target_url="${cv_url}/api/file/${cv_code}"

  info "Downloading backup archive from Cloud Vault (${cv_url})..."
  local cookie_file="/tmp/cv_cookie_$$.txt"
  rm -f "$cookie_file" "$dest"

  curl -sSL -c "$cookie_file" -b "$cookie_file" -o "$dest" "$target_url"

  if [[ ! -s "$dest" ]]; then
    err "Failed to download file from Cloud Vault (empty response)."
    rm -f "$cookie_file"
    return 1
  fi

  if grep -qi '<html' "$dest" || grep -qi '<!DOCTYPE' "$dest"; then
    local gdrive_id
    gdrive_id=$(grep -o 'name="id" value="[^"]*"' "$dest" | head -n1 | cut -d'"' -f4)
    if [[ -n "$gdrive_id" ]]; then
      info "Detected Google Drive virus scan warning, following download confirmation..."
      curl -sSL -c "$cookie_file" -b "$cookie_file" -o "$dest" "https://drive.usercontent.google.com/download?id=${gdrive_id}&export=download&confirm=t"
    fi
  fi

  rm -f "$cookie_file"

  if ! head -c 4 "$dest" 2>/dev/null | grep -q 'PK'; then
    err "Downloaded content is not a valid zip archive (Cloud Vault/Google Drive returned HTML or error)."
    return 1
  fi

  return 0
}


# --- Colors ---
export NC='\033[0m'
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export CYAN='\033[0;36m'
export WHITE='\033[1;37m'
export BICyan='\033[1;96m'
export BIWhite='\033[1;97m'
export ORANGE='\033[38;5;208m'
export PINK='\033[38;5;205m'
export PILL_TITLE='\033[30;107m'

# --- Adaptive width (tidy on small phone terminals: Termux/PuTTY) ---
# Detects the real terminal width and clamps it to a readable range so boxes
# never wrap on narrow screens nor stretch too wide on desktops.
ui_width() {
  local c
  c=$(tput cols 2>/dev/null)
  [[ "$c" =~ ^[0-9]+$ ]] || c="${COLUMNS:-56}"
  (( c < 30 )) && c=30
  (( c > 56 )) && c=56
  echo "$c"
}
# Repeat a character N times (portable, no seq/printf-pattern surprises).
ui_rep() { local ch="$1" n="$2" out=""; while (( n > 0 )); do out+="$ch"; ((n--)); done; printf '%s' "$out"; }

# SkyNode-inspired double-line rule (═)
line()    { echo -e "${CYAN}$(ui_rep '═' "$(ui_width)")${NC}"; }
ok()      { echo -e "${GREEN}[OK]${NC} $1"; }
info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()     { echo -e "${RED}[ERROR]${NC} $1"; }

# --- Consistent UI primitives (SkyNode-styled, high-contrast pills) ---
ui_rule() { echo -e "${CYAN}$(ui_rep '═' "$(ui_width)")${NC}"; }
ui_edge() { echo -e "${ORANGE}$(ui_rep '═' "$(ui_width)")${NC}"; }

# Centered title with SkyNode pill badge style
ui_header() {
  local t="$1" w; w=$(ui_width)
  local deco="[ ${t} ]"
  (( ${#deco} > w )) && deco="${t}"
  (( ${#deco} > w )) && deco="${deco:0:w}"
  local pad=$(( (w - ${#deco}) / 2 )); (( pad < 0 )) && pad=0
  ui_edge
  printf "%*s${PILL_TITLE}%s${NC}\n" "$pad" "" "$deco"
  ui_edge
}
ui_sep()  { ui_rule; }
ui_foot() { ui_edge; }
ui_center() {
  local t="$1" w; w=$(ui_width)
  (( ${#t} > w )) && t="${t:0:w}"
  local pad=$(( (w - ${#t}) / 2 )); (( pad < 0 )) && pad=0
  printf "${WHITE}%*s%s${NC}\n" "$pad" "" "$t"
}
# Section label with SkyNode pill format
ui_label() { echo -e "  ${PILL_TITLE}[ $1 ]${NC}"; }
# A numbered menu option row with SkyNode bullet formatting (•1)
ui_opt() { printf "  ${PINK}(•%2s)${NC} ${WHITE}│${NC} %b\n" "$1" "$2"; }
# Standard "back to menu" prompt used everywhere.
ui_back() { echo ""; read -n 1 -s -r -p " Press any key to return..."; }
# Aligned "label : value" row used by all detail/output panels.
ui_kv() {
  local label="$1" value="$2" vcol="${3:-$GREEN}"
  printf " ${WHITE}%-12s${NC} ${CYAN}:${NC} ${vcol}%b${NC}\n" "$label" "$value"
}
# Service status row: name left, colored bracketed badge after a colon.
ui_status() { printf " ${WHITE}%-12s${NC} ${CYAN}:${NC} %b\n" "$1" "$2"; }

# --- Service status helpers (SkyNode colored bracket badges) ---
svc_active() { systemctl is-active --quiet "$1" 2>/dev/null; }
svc_badge() {
  if svc_active "$1"; then
    echo -e "${PINK}[${GREEN} ON ${PINK}]${NC}"
  else
    echo -e "${PINK}[${RED} OFF ${PINK}]${NC}"
  fi
}
ssh_stack_badge() {
  local a=0 b=0
  svc_active dropbear && a=1
  svc_active ssh-ws  && b=1
  if   (( a && b )); then echo -e "${PINK}[${GREEN} ON ${PINK}]${NC}"
  elif (( a || b )); then echo -e "${PINK}[${YELLOW}WARN${PINK}]${NC}"
  else                    echo -e "${PINK}[${RED} OFF ${PINK}]${NC}"; fi
}

# Exact htop-aligned RAM calculation: (MemTotal - MemAvailable)
get_ram_info() {
  local total_kb avail_kb used_kb total_mb used_mb pct
  total_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null)
  avail_kb=$(awk '/MemAvailable/ {print $2}' /proc/meminfo 2>/dev/null)
  if [[ -z "$total_kb" || -z "$avail_kb" || "$total_kb" -eq 0 ]]; then
    free -h 2>/dev/null | grep "Mem:" | awk '{print $3 "/" $2}' || echo "N/A"
    return
  fi
  used_kb=$(( total_kb - avail_kb ))
  total_mb=$(( total_kb / 1024 ))
  used_mb=$(( used_kb / 1024 ))
  pct=$(( (used_kb * 100) / total_kb ))
  if (( total_mb >= 1024 )); then
    local u_gb t_gb
    u_gb=$(awk "BEGIN {printf \"%.1f\", $used_mb/1024}")
    t_gb=$(awk "BEGIN {printf \"%.1f\", $total_mb/1024}")
    echo "${u_gb} GB / ${t_gb} GB (${pct}%)"
  else
    echo "${used_mb} MB / ${total_mb} MB (${pct}%)"
  fi
}

# Accurate instantaneous CPU usage percentage
get_cpu_usage() {
  local cpu=""
  if [[ -r /proc/stat ]]; then
    local l1 l2
    l1=$(grep '^cpu ' /proc/stat 2>/dev/null)
    sleep 0.1 2>/dev/null || sleep 1
    l2=$(grep '^cpu ' /proc/stat 2>/dev/null)
    if [[ -n "$l1" && -n "$l2" ]]; then
      cpu=$(awk -v l1="$l1" -v l2="$l2" 'BEGIN {
        split(l1, a); split(l2, b);
        tot1=0; for(i=2; i<=8; i++) tot1+=a[i];
        tot2=0; for(i=2; i<=8; i++) tot2+=b[i];
        idle1=a[5]+a[6]; idle2=b[5]+b[6];
        dtot=tot2-tot1; didle=idle2-idle1;
        if (dtot > 0) {
          usage = (100 * (dtot - didle)) / dtot;
          if (usage < 0) usage = 0;
          if (usage > 100) usage = 100;
          printf "%d%%", usage;
        } else {
          print "0%";
        }
      }' 2>/dev/null)
    fi
  fi
  # Fallback to top if /proc/stat calculation was empty
  if [[ -z "$cpu" ]]; then
    cpu=$(top -bn1 2>/dev/null | grep -i "cpu" | head -1 | awk '{
      for(i=1; i<=NF; i++) {
        if ($i ~ /%?id/) {
          val = $(i-1);
          gsub(/[^0-9.]/, "", val);
          if (val != "") {
            printf "%d%%", (100 - val);
            exit;
          }
        }
      }
    }' 2>/dev/null)
  fi
  [[ -z "$cpu" ]] && cpu="0%"
  echo "$cpu"
}

# --- Domain / IP ---
get_domain() { cat "$AS_DOMAIN_FILE" 2>/dev/null || echo "not set"; }
get_ip() {
  if [[ -s /root/.ip ]]; then cat /root/.ip
  else hostname -I | awk '{print $1}'
  fi
}

# --- Validation (strict allowlists) ---
valid_username() { [[ "$1" =~ ^[a-zA-Z0-9_]{3,32}$ ]]; }
valid_prefix()   { [[ "$1" =~ ^[a-zA-Z0-9_]{1,16}$ ]]; }
valid_number()   { [[ "$1" =~ ^[0-9]+$ ]]; }
valid_days()     { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 3650 )); }
valid_duration() { [[ "$1" =~ ^[0-9]+[mhd]$ ]]; }
valid_uuid()     { [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; }
valid_password() {
  # Non-empty, no whitespace/control/colon (safe for chpasswd and configs)
  [[ -n "$1" ]] || return 1
  [[ "$1" == *[$'\n\r\t :']* ]] && return 1
  return 0
}
valid_domain()   { [[ "$1" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; }

gen_uuid() { cat /proc/sys/kernel/random/uuid; }
gen_pass() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-10}"; }

# Resolve the nologin shell path and ensure it is registered in /etc/shells.
# On Rocky Linux 9 the binary is /usr/sbin/nologin (with /sbin -> /usr/sbin).
# PAM's pam_shells rejects logins whose shell is not listed in /etc/shells,
# which surfaces to SSH/WS clients as "incorrect username or password".
ensure_nologin_shell() {
  local sh=""
  if [[ -x /usr/sbin/nologin ]]; then sh=/usr/sbin/nologin
  elif [[ -x /sbin/nologin ]]; then sh=/sbin/nologin
  fi
  [[ -z "$sh" ]] && { echo ""; return 1; }
  touch /etc/shells 2>/dev/null
  # Register both common paths so either resolves.
  grep -qxF "$sh" /etc/shells 2>/dev/null || echo "$sh" >> /etc/shells
  if [[ "$sh" == /usr/sbin/nologin ]] && [[ -e /sbin/nologin ]]; then
    grep -qxF "/sbin/nologin" /etc/shells 2>/dev/null || echo "/sbin/nologin" >> /etc/shells
  fi
  echo "$sh"
  return 0
}

# --- Duration -> seconds ---
duration_to_seconds() {
  local d="$1" v="${1%?}" u="${1: -1}"
  case "$u" in
    m) echo $(( v * 60 ));;
    h) echo $(( v * 3600 ));;
    d) echo $(( v * 86400 ));;
    *) echo 0;;
  esac
}

# --- Telegram ---
# Returns 0 if both bot token and chat id are configured.
tg_is_configured() {
  [[ -s "$AS_BOTKEY" && -s "$AS_CHATID" ]]
}

# Escape a string for Telegram HTML parse_mode. Per Telegram docs only &, <, >
# must be escaped (and & must be done first). Raw '&' inside vless/trojan
# share-links was making the API reject messages with HTTP 400.
html_escape() {
  local s="$1"
  s=${s//&/&amp;}
  s=${s//</&lt;}
  s=${s//>/&gt;}
  printf '%s' "$s"
}

# Low-level Telegram sendMessage. Args: body [parse_mode]. Echoes raw response.
_tg_raw() {
  local body="$1" mode="$2" token chat
  token=$(cat "$AS_BOTKEY" 2>/dev/null)
  chat=$(cat "$AS_CHATID" 2>/dev/null)
  [[ -z "$token" || -z "$chat" ]] && return 1
  local args=(-s --max-time 25 -X POST
    "https://api.telegram.org/bot${token}/sendMessage"
    -d chat_id="${chat}" -d disable_web_page_preview="true")
  [[ -n "$mode" ]] && args+=(-d parse_mode="$mode")
  args+=(--data-urlencode "text=${body}")
  curl "${args[@]}" 2>/dev/null
}

# Extract a numeric "retry_after" from a 429 response (default 2s).
_tg_retry_after() {
  local n; n=$(printf '%s' "$1" | grep -o '"retry_after":[0-9]\+' | grep -o '[0-9]\+')
  [[ "$n" =~ ^[0-9]+$ ]] && echo "$n" || echo 2
}

# Send a Telegram message. Tries HTML first; on rate-limit (429) it honours
# retry_after and retries; if HTML parsing still fails it falls back to plain
# text (tags stripped) so the content is delivered regardless. Returns 0 only
# when Telegram confirms "ok":true.
tg_send() {
  local text="$1" resp
  tg_is_configured || return 1
  # Accept both real newlines and literal %0A markers in the message body.
  text=${text//%0A/$'\n'}

  resp=$(_tg_raw "$text" "HTML")
  if [[ "$resp" == *'"error_code":429'* ]]; then
    sleep "$(_tg_retry_after "$resp")"
    resp=$(_tg_raw "$text" "HTML")
  fi
  [[ "$resp" == *'"ok":true'* ]] && return 0

  # Fallback: deliver as plain text (strip HTML tags) so it never silently drops.
  local plain; plain=$(printf '%s' "$text" | sed -e 's/<[^>]*>//g')
  resp=$(_tg_raw "$plain" "")
  if [[ "$resp" == *'"error_code":429'* ]]; then
    sleep "$(_tg_retry_after "$resp")"
    resp=$(_tg_raw "$plain" "")
  fi
  [[ "$resp" == *'"ok":true'* ]]
}

# --- Require root ---
require_root() {
  if [[ $EUID -ne 0 ]]; then err "This must be run as root."; exit 1; fi
}

# --- IP Geolocation & ASN Lookup (On-The-Fly / RAM Cached) ---
# Args: <ip>
# Returns: <asn_or_isp>|<location> (e.g. "AS4818 DiGi Telecommunications Sdn. Bhd.|Kuching, Sarawak, MY")
declare -gA __LIVE_IP_CACHE=()

lookup_ip_geo() {
  local ip="$1"
  [[ -z "$ip" ]] && { echo "Unknown|Unknown"; return; }

  # Strip port or CIDR if present
  ip="${ip%%:*}"
  ip="${ip%%/*}"

  # Handle loopback and private networks
  if [[ "$ip" =~ ^127\. || "$ip" == "::1" || "$ip" == "localhost" ]]; then
    echo "Localhost|Local System"
    return
  fi
  if [[ "$ip" =~ ^10\. || "$ip" =~ ^192\.168\. || "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]]; then
    echo "Private Network|LAN"
    return
  fi
  if [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && ! "$ip" =~ : ]]; then
    echo "Direct/Unknown|Unknown"
    return
  fi

  # Check in-memory process cache (avoid duplicate requests in the same screen)
  if [[ -n "${__LIVE_IP_CACHE[$ip]}" ]]; then
    echo "${__LIVE_IP_CACHE[$ip]}"
    return
  fi

  # Query Primary API: ip-api.com
  local res status as_name isp_name city region country loc_parts=()
  if command -v curl >/dev/null 2>&1; then
    res=$(curl -s --connect-timeout 2 --max-time 3 "http://ip-api.com/json/${ip}?fields=status,message,countryCode,regionName,city,as,isp" 2>/dev/null)
    if command -v jq >/dev/null 2>&1; then
      status=$(echo "$res" | jq -r '.status // empty' 2>/dev/null)
      if [[ "$status" == "success" ]]; then
        as_name=$(echo "$res" | jq -r '.as // empty' 2>/dev/null)
        isp_name=$(echo "$res" | jq -r '.isp // empty' 2>/dev/null)
        city=$(echo "$res" | jq -r '.city // empty' 2>/dev/null)
        region=$(echo "$res" | jq -r '.regionName // empty' 2>/dev/null)
        country=$(echo "$res" | jq -r '.countryCode // empty' 2>/dev/null)
      fi
    else
      status=$(echo "$res" | awk -F'"status": *"' '{split($2,a,"\""); print a[1]}')
      if [[ "$status" == "success" ]]; then
        as_name=$(echo "$res" | awk -F'"as": *"' '{split($2,a,"\""); print a[1]}')
        isp_name=$(echo "$res" | awk -F'"isp": *"' '{split($2,a,"\""); print a[1]}')
        city=$(echo "$res" | awk -F'"city": *"' '{split($2,a,"\""); print a[1]}')
        region=$(echo "$res" | awk -F'"regionName": *"' '{split($2,a,"\""); print a[1]}')
        country=$(echo "$res" | awk -F'"countryCode": *"' '{split($2,a,"\""); print a[1]}')
      fi
    fi

    # Fallback API: ipwho.is if primary returned no ASN / failed
    if [[ -z "$as_name" && -z "$isp_name" ]]; then
      res=$(curl -s --connect-timeout 2 --max-time 3 "https://ipwho.is/${ip}" 2>/dev/null)
      if command -v jq >/dev/null 2>&1; then
        if [[ $(echo "$res" | jq -r '.success // false' 2>/dev/null) == "true" ]]; then
          local asn org
          asn=$(echo "$res" | jq -r '.connection.asn // empty' 2>/dev/null)
          org=$(echo "$res" | jq -r '.connection.org // .connection.isp // empty' 2>/dev/null)
          [[ -n "$asn" && "$asn" != "null" ]] && as_name="AS${asn} ${org}" || as_name="$org"
          isp_name=$(echo "$res" | jq -r '.connection.isp // empty' 2>/dev/null)
          city=$(echo "$res" | jq -r '.city // empty' 2>/dev/null)
          region=$(echo "$res" | jq -r '.region // empty' 2>/dev/null)
          country=$(echo "$res" | jq -r '.country_code // empty' 2>/dev/null)
        fi
      else
        local succ asn org
        succ=$(echo "$res" | awk -F'"success":' '{split($2,a,"[,}]"); print a[1]}' | tr -d ' ')
        if [[ "$succ" == "true" ]]; then
          asn=$(echo "$res" | awk -F'"asn":' '{split($2,a,"[,}]"); print a[1]}' | tr -d ' ')
          org=$(echo "$res" | awk -F'"org": *"' '{split($2,a,"\""); print a[1]}')
          [[ -z "$org" ]] && org=$(echo "$res" | awk -F'"isp": *"' '{split($2,a,"\""); print a[1]}')
          [[ -n "$asn" && "$asn" != "null" && "$asn" != "0" ]] && as_name="AS${asn} ${org}" || as_name="$org"
          isp_name=$(echo "$res" | awk -F'"isp": *"' '{split($2,a,"\""); print a[1]}')
          city=$(echo "$res" | awk -F'"city": *"' '{split($2,a,"\""); print a[1]}')
          region=$(echo "$res" | awk -F'"region": *"' '{split($2,a,"\""); print a[1]}')
          country=$(echo "$res" | awk -F'"country_code": *"' '{split($2,a,"\""); print a[1]}')
        fi
      fi
    fi
  fi

  # Formulate ASN / ISP
  local asn_isp="Unknown ISP"
  if [[ -n "$as_name" && "$as_name" != "null" ]]; then
    asn_isp="$as_name"
  elif [[ -n "$isp_name" && "$isp_name" != "null" ]]; then
    asn_isp="$isp_name"
  fi

  # Formulate Location (City, Region, Country)
  local location=""
  [[ -n "$city" && "$city" != "null" ]] && loc_parts+=("$city")
  [[ -n "$region" && "$region" != "null" && "$region" != "$city" ]] && loc_parts+=("$region")
  [[ -n "$country" && "$country" != "null" ]] && loc_parts+=("$country")

  if [[ ${#loc_parts[@]} -gt 0 ]]; then
    location=$(printf ", %s" "${loc_parts[@]}")
    location="${location:2}"
  else
    location="Unknown Location"
  fi

  local result="${asn_isp}|${location}"
  __LIVE_IP_CACHE[$ip]="$result"
  echo "$result"
}
