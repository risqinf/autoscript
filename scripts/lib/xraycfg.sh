#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: Pure-JSON Xray config management (jq + atomic + rollback)
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
[[ -n "${__AS_XRAYCFG_LOADED:-}" ]] && return 0
__AS_XRAYCFG_LOADED=1

[[ -n "${__AS_COMMON_LOADED:-}" ]] || . "$(dirname "${BASH_SOURCE[0]}")/common.sh"

AS_XRAY_BIN="/usr/local/bin/xray"

# Map protocol -> inbound tag in config.json
cfg_tag() {
  case "$1" in
    vless)  echo "vless-ws"  ;;
    vmess)  echo "vmess-ws"  ;;
    trojan) echo "trojan-ws" ;;
    *) echo "" ;;
  esac
}

# Apply a jq filter atomically under flock: write temp, validate JSON, xray -test, then
# replace. Rolls back on any failure. Args: jq_filter [jq_args...]
cfg_apply() {
  local filter="$1"; shift
  local lockfile="/run/autoscript-xraycfg.lock"
  mkdir -p /run 2>/dev/null
  (
    flock -w 15 200 || { err "timeout waiting for xray config lock"; exit 1; }
    local tmp bak
    tmp="$(mktemp)"; chmod 600 "$tmp" 2>/dev/null
    bak="${AS_CONFIG}.bak.$$"

    if ! jq "$@" "$filter" "$AS_CONFIG" > "$tmp" 2>/dev/null; then
      rm -f "$tmp"; err "jq transform failed"; exit 1
    fi
    if ! jq -e . "$tmp" >/dev/null 2>&1; then
      rm -f "$tmp"; err "resulting config is not valid JSON"; exit 1
    fi

    cp -pf "$AS_CONFIG" "$bak"
    cp -f "$tmp" "$AS_CONFIG"
    chmod 600 "$AS_CONFIG" 2>/dev/null
    rm -f "$tmp"

    if [[ -x "$AS_XRAY_BIN" ]]; then
      if ! "$AS_XRAY_BIN" -test -config "$AS_CONFIG" >/dev/null 2>&1; then
        mv -f "$bak" "$AS_CONFIG"
        err "xray -test failed; configuration rolled back"
        exit 1
      fi
    fi
    rm -f "$bak"
    exit 0
  ) 200>"$lockfile"
}

# Does a client email exist in any inbound?
cfg_client_exists() {
  local user="$1"
  local c
  c=$(jq --arg u "$user" '[.inbounds[].settings.clients[]? | select(.email==$u)] | length' "$AS_CONFIG" 2>/dev/null)
  [[ "${c:-0}" -gt 0 ]]
}

# Is a uuid/password already used (id for vless/vmess, password for trojan)?
cfg_secret_exists() {
  local secret="$1"
  local c
  c=$(jq --arg s "$secret" '[.inbounds[].settings.clients[]? | select((.id==$s) or (.password==$s))] | length' "$AS_CONFIG" 2>/dev/null)
  [[ "${c:-0}" -gt 0 ]]
}

# Add a client to all inbounds for a protocol (WS, HTTPUpgrade, XHTTP, gRPC).
# Args: protocol username secret
cfg_add_client() {
  local proto="$1" user="$2" secret="$3"
  case "$proto" in
    vless|vmess|trojan) ;;
    *) err "unknown protocol: $proto"; return 1 ;;
  esac

  local client
  case "$proto" in
    vless)  client="$(jq -n --arg id "$secret" --arg e "$user" '{id:$id, email:$e}')" ;;
    vmess)  client="$(jq -n --arg id "$secret" --arg e "$user" '{id:$id, alterId:0, email:$e}')" ;;
    trojan) client="$(jq -n --arg pw "$secret" --arg e "$user" '{password:$pw, email:$e}')" ;;
  esac

  cfg_apply '
    (.inbounds[] | select(.protocol==$proto and .settings.clients != null) | .settings.clients) += [$client]
  ' --arg proto "$proto" --argjson client "$client"
}

# Remove a client (by email) from all inbounds for a protocol.
cfg_del_client() {
  local proto="$1" user="$2"
  case "$proto" in
    vless|vmess|trojan) ;;
    *) err "unknown protocol: $proto"; return 1 ;;
  esac

  cfg_apply '
    (.inbounds[] | select(.protocol==$proto and .settings.clients != null) | .settings.clients)
      |= map(select(.email != $u))
  ' --arg proto "$proto" --arg u "$user"
}

# Batch-add an array of pre-built JSON client objects to all inbounds for a protocol
# in one atomic write + single xray -test validation.
# Args: protocol json_clients_array
cfg_add_clients_batch() {
  local proto="$1" clients_json="$2"
  case "$proto" in
    vless|vmess|trojan) ;;
    *) err "unknown protocol: $proto"; return 1 ;;
  esac
  [[ -z "$clients_json" || "$clients_json" == "[]" ]] && return 0

  cfg_apply '
    (.inbounds[] | select(.protocol==$proto and .settings.clients != null) | .settings.clients) += $clients
  ' --arg proto "$proto" --argjson clients "$clients_json"
}

