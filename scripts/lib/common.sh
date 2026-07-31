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

# Modern, widely-supported light rule (U+2500). Renders cleanly on phone
# terminals (Termux), PuTTY, and desktop terminals alike.
line() { echo -e "${CYAN}$(ui_rep '─' "$(ui_width)")${NC}"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()   { echo -e "${RED}[ERROR]${NC} $1"; }

# --- Consistent UI primitives (used by every menu/script) ---
# A single modern horizontal rule (the one separator style used everywhere).
ui_rule() { echo -e "${CYAN}$(ui_rep '─' "$(ui_width)")${NC}"; }
# A heavier rule used to frame headers (top/bottom of a panel).
ui_edge() { echo -e "${BICyan}$(ui_rep '━' "$(ui_width)")${NC}"; }
# Centered title framed by heavy rules (clean, width-adaptive, no side bars so
# it never breaks on narrow phone terminals). Arg: title text.
ui_header() {
  local t="$1" w; w=$(ui_width)
  local deco="• ${t} •"
  (( ${#deco} > w )) && deco="${t}"
  (( ${#deco} > w )) && deco="${deco:0:w}"
  local pad=$(( (w - ${#deco}) / 2 )); (( pad < 0 )) && pad=0
  ui_edge
  printf "${BICyan}%*s%s${NC}\n" "$pad" "" "$deco"
  ui_edge
}
ui_sep()  { ui_rule; }
ui_foot() { ui_edge; }
# Centered title line only (no rules around it). Arg: title.
ui_center() {
  local t="$1" w; w=$(ui_width)
  (( ${#t} > w )) && t="${t:0:w}"
  local pad=$(( (w - ${#t}) / 2 )); (( pad < 0 )) && pad=0
  printf "${WHITE}%*s%s${NC}\n" "$pad" "" "$t"
}
# Section label (left aligned, bright). Arg: text.
ui_label() { echo -e " ${BIWhite}» $1${NC}"; }
# A numbered menu option row. Args: number text.
ui_opt() { printf "  ${BICyan}%2s${NC} ${WHITE}│${NC} %s\n" "$1" "$2"; }
# Standard "back to menu" prompt used everywhere.
ui_back() { echo ""; read -n 1 -s -r -p " Press any key to return..."; }
# Aligned "label : value" row used by all detail/output panels.
# Args: label value [value-color]
ui_kv() {
  local label="$1" value="$2" vcol="${3:-$GREEN}"
  printf " ${WHITE}%-12s${NC} ${CYAN}:${NC} ${vcol}%s${NC}\n" "$label" "$value"
}
# Service status row: name left, colored bracketed badge after a colon.
# Args: name badge(pre-colored string)
ui_status() { printf " ${WHITE}%-12s${NC} ${CYAN}:${NC} %b\n" "$1" "$2"; }

# --- Service status helpers (used by menu + status checker) ---
# Returns 0 if the unit is active.
svc_active() { systemctl is-active --quiet "$1" 2>/dev/null; }
# Bracketed colored ON/OFF badge for a single unit. Arg: unit name.
svc_badge() {
  if svc_active "$1"; then echo -e "${GREEN}[ ON ]${NC}"; else echo -e "${RED}[ OFF ]${NC}"; fi
}
# Combined SSH tunnel badge (dropbear + ssh-ws). 3 states:
#   both up   -> green [ ON ]
#   one up    -> yellow [ WARN ]
#   none up   -> red [ OFF ]
ssh_stack_badge() {
  local a=0 b=0
  svc_active dropbear && a=1
  svc_active ssh-ws  && b=1
  if   (( a==1 && b==1 )); then echo -e "${GREEN}[ ON ]${NC}"
  elif (( a==1 || b==1 )); then echo -e "${YELLOW}[ WARN ]${NC}"
  else echo -e "${RED}[ OFF ]${NC}"
  fi
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
