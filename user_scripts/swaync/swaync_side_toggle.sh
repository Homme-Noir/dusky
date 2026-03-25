#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Script: swaync_toggle.sh
# Description: Toggle SwayNC position (Left/Right) and Hyprland slide animation
# Context: Arch Linux / Hyprland / UWSM
# -----------------------------------------------------------------------------

# Options:
#  -l, --left      Set position to Left
#  -r, --right     Set position to Right
#  -t, --toggle    Toggle (flip) position
#  -s, --status    Show current position
#  -h, --help      Show this help

set -euo pipefail

# --- Configuration ---
readonly SWAYNC_CONFIG="${HOME:?HOME is not set}/.config/swaync/config.json"
readonly HYPR_RULES="${HOME}/.config/hypr/source/window_rules.conf"

# --- Colors (TTY-aware) ---
if [[ -t 1 && -t 2 ]]; then
    readonly BOLD=$'\e[1m' RED=$'\e[31m' GREEN=$'\e[32m'
    readonly BLUE=$'\e[34m' YELLOW=$'\e[33m' CYAN=$'\e[36m' NC=$'\e[0m'
else
    readonly BOLD='' RED='' GREEN='' BLUE='' YELLOW='' CYAN='' NC=''
fi

# --- Logging Helpers ---
die()     { printf '%s[ERROR]%s %s\n' "${RED}${BOLD}" "$NC" "$1" >&2; exit 1; }
info()    { printf '%s[INFO]%s %s\n' "${BLUE}${BOLD}" "$NC" "$1"; }
warn()    { printf '%s[WARN]%s %s\n' "${YELLOW}${BOLD}" "$NC" "$1" >&2; }
success() { printf '%s[SUCCESS]%s %s\n' "${GREEN}${BOLD}" "$NC" "$1"; }

# --- Pre-flight Checks ---
check_dependencies() {
    command -v jq &>/dev/null || die "'jq' is not installed"

    [[ -f "$SWAYNC_CONFIG" ]] || die "SwayNC config not found: $SWAYNC_CONFIG"
    [[ -r "$SWAYNC_CONFIG" ]] || die "SwayNC config not readable: $SWAYNC_CONFIG"
    [[ -w "$SWAYNC_CONFIG" ]] || die "SwayNC config not writable: $SWAYNC_CONFIG"

    [[ -f "$HYPR_RULES" ]] || die "Hyprland rules not found: $HYPR_RULES"
    [[ -r "$HYPR_RULES" ]] || die "Hyprland rules not readable: $HYPR_RULES"
    [[ -w "$HYPR_RULES" ]] || die "Hyprland rules not writable: $HYPR_RULES"
}

# --- Core Functions ---

get_current_position() {
    local pos
    pos=$(jq -re '.positionX // empty' "$SWAYNC_CONFIG" 2>/dev/null) ||
        die "Failed to read 'positionX' from $SWAYNC_CONFIG"
    printf '%s' "$pos"
}

reload_services() {
    local target_side="$1"
    
    if command -v swaync-client &>/dev/null; then
        swaync-client --reload-config &>/dev/null || warn "SwayNC config reload failed (is swaync running?)"
        swaync-client --reload-css &>/dev/null    || warn "SwayNC CSS reload failed"
    else
        warn "swaync-client not found. Restart SwayNC manually."
    fi

    if command -v hyprctl &>/dev/null; then
        hyprctl reload &>/dev/null || warn "Hyprland reload failed"
    else
        warn "hyprctl not found. Session restart required for animation changes."
    fi

    success "Position updated to ${BOLD}${target_side^^}${NC}"
}

apply_changes() {
    local target_side="${1:-}"

    # Validation
    [[ "$target_side" =~ ^(left|right)$ ]] ||
        die "Invalid side: '$target_side'. Use 'left' or 'right'"

    info "Switching to ${YELLOW}${target_side^^}${NC}..."

    # 1. Update SwayNC (Surgical SED edit to preserve formatting)
    sed -i 's/\("positionX"[[:space:]]*:[[:space:]]*\)"[^"]*"/\1"'"$target_side"'"/' "$SWAYNC_CONFIG" ||
        die "Failed to update SwayNC config"

    # 2. Verify the change (Trust but Verify)
    local actual
    actual=$(get_current_position)
    [[ "$actual" == "$target_side" ]] ||
        die "Verification failed! Config did not update. Check file permissions or JSON syntax."

    # 3. Update Hyprland Rules (Surgical SED edit)
    if grep -q 'name = swaync_slide' "$HYPR_RULES" 2>/dev/null; then
        sed -i "/name = swaync_slide/,/}/ s/animation = slide .*/animation = slide $target_side/" "$HYPR_RULES" ||
            warn "Failed to update Hyprland animation rule"
    else
        warn "Block 'swaync_slide' not found in $HYPR_RULES. Animation not updated."
    fi

    # 4. Reload
    reload_services "$target_side"
}

toggle_position() {
    local current
    current=$(get_current_position)
    case "$current" in
        left)  apply_changes "right" ;;
        right) apply_changes "left" ;;
        *)     die "Unknown current position: '$current'" ;;
    esac
}

show_status() {
    local current
    current=$(get_current_position)
    printf 'Current position: %s%s%s\n' "${GREEN}${BOLD}" "${current^}" "$NC"
}

# --- TUI ---
show_tui() {
    local current choice
    current=$(get_current_position)

    clear
    printf '\n%s╔══════════════════════════════════════╗%s\n' "${CYAN}${BOLD}" "$NC"
    printf '%s║      SwayNC Position Controller      ║%s\n' "${CYAN}${BOLD}" "$NC"
    printf '%s╚══════════════════════════════════════╝%s\n\n' "${CYAN}${BOLD}" "$NC"

    printf 'Current Position: %s%s%s\n\n' "${GREEN}${BOLD}" "${current^}" "$NC"

    printf 'Select Action:\n'
    printf '  %s1)%s Switch to Left\n' "$BOLD" "$NC"
    printf '  %s2)%s Switch to Right\n' "$BOLD" "$NC"
    printf '  %st)%s Toggle\n' "$BOLD" "$NC"
    printf '  %sq)%s Quit\n\n' "$BOLD" "$NC"

    read -rp "Enter choice [1/2/t/q]: " choice
    printf '\n'

    case "${choice,,}" in
        1|l|left)   apply_changes "left" ;;
        2|r|right)  apply_changes "right" ;;
        t|toggle)   toggle_position ;;
        q|quit|'')  printf 'Exiting.\n' ;;
        *)          die "Invalid option: '$choice'" ;;
    esac
}

show_help() {
    cat <<EOF
Usage: ${0##*/} [OPTION]

Options:
  -l, --left      Set position to Left
  -r, --right     Set position to Right
  -t, --toggle    Toggle (flip) position
  -s, --status    Show current position
  -h, --help      Show this help

Running without arguments opens the Interactive Menu.
EOF
}

# --- Main ---
main() {
    check_dependencies

    # If no arguments, show TUI
    (( $# )) || { show_tui; return; }

    case "$1" in
        -l|--left)   apply_changes "left" ;;
        -r|--right)  apply_changes "right" ;;
        -t|--toggle) toggle_position ;;
        -s|--status) show_status ;;
        -h|--help)   show_help ;;
        *)           die "Unknown option: '$1'. Use --help." ;;
    esac
}

main "$@"
