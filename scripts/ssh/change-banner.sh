#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: SSH WebSocket Banner Editor (/etc/issue.net)
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
[[ -f /usr/local/sbin/lib/common.sh ]] && . /usr/local/sbin/lib/common.sh

BANNER_FILE="/etc/issue.net"
BANNER_BACKUP="/etc/issue.net.bak"
MAX_BANNER_LINES=40
MAX_BANNER_CHARS=4000

# ─────────────────────────────────────────────────────────────
# Show the current banner content
# ─────────────────────────────────────────────────────────────
show_current_banner() {
    clear
    ui_header "SSH WEBSOCKET BANNER"
    echo ""
    ui_label "Current banner  (/etc/issue.net)"
    ui_rule
    if [[ -f "$BANNER_FILE" && -s "$BANNER_FILE" ]]; then
        cat "$BANNER_FILE"
    else
        echo -e " ${YELLOW}(Banner is empty or file does not exist)${NC}"
    fi
    ui_rule
}

# ─────────────────────────────────────────────────────────────
# Validate that the candidate banner is not empty / too large
# Returns 0 if valid, 1 if invalid (prints reason to stderr).
# ─────────────────────────────────────────────────────────────
validate_banner() {
    local text="$1"

    # Strip whitespace-only content
    local stripped
    stripped="$(echo "$text" | sed '/^[[:space:]]*$/d')"
    if [[ -z "$stripped" ]]; then
        err "Banner cannot be empty or contain only blank lines." >&2
        return 1
    fi

    local line_count char_count
    line_count=$(echo "$text" | wc -l)
    char_count=${#text}

    if (( line_count > MAX_BANNER_LINES )); then
        err "Banner too long: ${line_count} lines (max ${MAX_BANNER_LINES})." >&2
        return 1
    fi

    if (( char_count > MAX_BANNER_CHARS )); then
        err "Banner too large: ${char_count} characters (max ${MAX_BANNER_CHARS})." >&2
        return 1
    fi

    return 0
}

# ─────────────────────────────────────────────────────────────
# Write the banner safely:
#   1. Backup the old file.
#   2. Write new content atomically (tmp + mv).
#   3. Set correct permissions.
# ─────────────────────────────────────────────────────────────
write_banner() {
    local content="$1"

    # Backup existing banner
    if [[ -f "$BANNER_FILE" ]]; then
        cp -f "$BANNER_FILE" "$BANNER_BACKUP" 2>/dev/null || true
    fi

    # Atomic write: write to tmp then rename to avoid partial reads by sshd
    local tmpfile
    tmpfile="$(mktemp /etc/issue.net.tmp.XXXXXX)"
    printf '%s\n' "$content" > "$tmpfile"
    chmod 644 "$tmpfile"
    mv -f "$tmpfile" "$BANNER_FILE"
}

# ─────────────────────────────────────────────────────────────
# Interactive multi-line banner input
# User types/pastes lines; ends input with a line containing
# only "END" (case-insensitive) or Ctrl-D.
# ─────────────────────────────────────────────────────────────
read_banner_input() {
    echo ""
    ui_rule
    echo -e " ${WHITE}Type or paste your banner below.${NC}"
    echo -e " ${CYAN}─ Supports plain text, HTML tags (for WebSocket clients), emoji.${NC}"
    echo -e " ${CYAN}─ When done, type ${WHITE}END${CYAN} on a new line and press Enter.${NC}"
    echo -e " ${CYAN}─ Or press ${WHITE}Ctrl+D${CYAN} to finish.${NC}"
    echo -e " ${YELLOW}─ Max ${MAX_BANNER_LINES} lines / ${MAX_BANNER_CHARS} characters.${NC}"
    ui_rule
    echo ""

    local lines=()
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Allow "END" as a sentinel to terminate input gracefully
        if [[ "${line^^}" == "END" ]]; then
            break
        fi
        lines+=("$line")
    done

    # Join lines with real newlines
    local result
    result="$(printf '%s\n' "${lines[@]}")"
    # Trim trailing blank lines
    result="$(echo "$result" | sed -e 's/[[:space:]]*$//' | awk 'BEGIN{ORS="\n"} /[^[:space:]]/{found=1} found{print}')"

    printf '%s' "$result"
}

# ─────────────────────────────────────────────────────────────
# Option 1 — Set a new banner (interactive input)
# ─────────────────────────────────────────────────────────────
do_set_banner() {
    show_current_banner
    echo ""
    echo -e " ${YELLOW}You are about to replace the SSH WebSocket banner.${NC}"

    local new_banner
    new_banner="$(read_banner_input)"

    echo ""
    if ! validate_banner "$new_banner"; then
        echo ""
        read -n 1 -s -r -p " Press any key to return..."
        change_banner
        return
    fi

    # Preview
    echo ""
    ui_rule
    echo -e " ${WHITE}Preview of new banner:${NC}"
    ui_rule
    echo "$new_banner"
    ui_rule
    echo ""
    read -rp " $(echo -e "${YELLOW}Apply this banner? [y/N]:${NC} ")" confirm
    case "${confirm,,}" in
        y|yes)
            write_banner "$new_banner"
            echo ""
            ok "Banner updated successfully → ${BANNER_FILE}"
            [[ -f "$BANNER_BACKUP" ]] && info "Previous banner backed up to ${BANNER_BACKUP}"
            ;;
        *)
            warn "Cancelled. Banner not changed."
            ;;
    esac

    echo ""
    read -n 1 -s -r -p " Press any key to return..."
    change_banner
}

# ─────────────────────────────────────────────────────────────
# Option 2 — Restore from backup
# ─────────────────────────────────────────────────────────────
do_restore_banner() {
    clear
    ui_header "RESTORE BANNER FROM BACKUP"
    echo ""

    if [[ ! -f "$BANNER_BACKUP" || ! -s "$BANNER_BACKUP" ]]; then
        warn "No backup found at ${BANNER_BACKUP}."
        echo ""
        read -n 1 -s -r -p " Press any key to return..."
        change_banner
        return
    fi

    info "Backup content:"
    ui_rule
    cat "$BANNER_BACKUP"
    ui_rule
    echo ""
    read -rp " $(echo -e "${YELLOW}Restore this backup? [y/N]:${NC} ")" confirm
    case "${confirm,,}" in
        y|yes)
            cp -f "$BANNER_BACKUP" "$BANNER_FILE"
            chmod 644 "$BANNER_FILE"
            ok "Banner restored from backup."
            ;;
        *)
            warn "Cancelled."
            ;;
    esac

    echo ""
    read -n 1 -s -r -p " Press any key to return..."
    change_banner
}

# ─────────────────────────────────────────────────────────────
# Option 3 — Clear / reset banner to default
# ─────────────────────────────────────────────────────────────
do_clear_banner() {
    clear
    ui_header "RESET SSH BANNER"
    echo ""
    warn "This will replace the banner with a minimal default."
    echo ""
    read -rp " $(echo -e "${YELLOW}Proceed? [y/N]:${NC} ")" confirm
    case "${confirm,,}" in
        y|yes)
            # Backup first
            [[ -f "$BANNER_FILE" ]] && cp -f "$BANNER_FILE" "$BANNER_BACKUP" 2>/dev/null || true
            local default_banner
            default_banner="Welcome to Autoscript VPN"
            write_banner "$default_banner"
            ok "Banner reset to default."
            [[ -f "$BANNER_BACKUP" ]] && info "Previous banner backed up to ${BANNER_BACKUP}"
            ;;
        *)
            warn "Cancelled."
            ;;
    esac

    echo ""
    read -n 1 -s -r -p " Press any key to return..."
    change_banner
}

# ─────────────────────────────────────────────────────────────
# Main change-banner menu
# ─────────────────────────────────────────────────────────────
change_banner() {
    clear
    ui_header "CHANGE SSH WEBSOCKET BANNER"
    echo ""

    # Show status of current banner
    if [[ -f "$BANNER_FILE" && -s "$BANNER_FILE" ]]; then
        local line_count char_count
        line_count=$(wc -l < "$BANNER_FILE")
        char_count=$(wc -c < "$BANNER_FILE")
        ui_kv "Banner file"   "${BANNER_FILE}"
        ui_kv "Current size"  "${line_count} lines / ${char_count} bytes"
    else
        ui_kv "Banner file"   "${BANNER_FILE} ${YELLOW}(empty)${NC}"
    fi

    [[ -f "$BANNER_BACKUP" ]] && ui_kv "Backup" "${BANNER_BACKUP} (available)"

    ui_rule
    ui_opt 1 "Set / Replace banner  (type or paste new banner)"
    ui_opt 2 "View current banner"
    ui_opt 3 "Restore from backup"
    ui_opt 4 "Reset to default banner"
    ui_rule
    ui_opt 0 "Back"
    ui_foot
    read -rp " Select option : " opt
    case "$opt" in
        1) do_set_banner ;;
        2) show_current_banner; echo ""; read -n 1 -s -r -p " Press any key to return..."; change_banner ;;
        3) do_restore_banner ;;
        4) do_clear_banner ;;
        0|x|X) menu-ssh ;;
        *) err "Invalid option."; sleep 1; change_banner ;;
    esac
}

change_banner
