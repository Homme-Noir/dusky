#!/usr/bin/env bash
# ==============================================================================
# TITLE:        User Service Toggler (Hyprland/UWSM)
# DESCRIPTION:  Interactive CLI to toggle user-level systemd services.
# AUTHOR:       System Architect
# TARGET:       Arch Linux / Hyprland / UWSM
# VERSION:      1.2.0
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. STRICT MODE & SAFETY
# ------------------------------------------------------------------------------
set -euo pipefail
IFS=$'\n\t'

# Global state for cleanup
declare -g CURSOR_HIDDEN=false

# Cleanup function: Restores cursor state safely
cleanup() {
    if [[ "$CURSOR_HIDDEN" == true ]]; then
        tput cnorm 2>/dev/null || true
    fi
}

# Trap EXIT only; signals (INT, TERM) will naturally trigger EXIT logic
trap cleanup EXIT

# ------------------------------------------------------------------------------
# 2. CONFIGURATION
# ------------------------------------------------------------------------------
# SYNTAX: "service_name.service|Friendly Description"
readonly SERVICES=(
    "hyprsunset.service|Night Light (Blue Light Filter)"
    "battery_notify.service|Battery Level Notifications"
    "network_meter.service|Waybar Network Traffic Monitor"
)

# ------------------------------------------------------------------------------
# 3. STYLING & CONSTANTS
# ------------------------------------------------------------------------------
# Use ANSI-C quoting ($'...') for strictly interpreted escape codes
readonly C_RESET=$'\033[0m'
readonly C_BOLD=$'\033[1m'
readonly C_GREEN=$'\033[32m'
readonly C_RED=$'\033[31m'
readonly C_CYAN=$'\033[36m'
readonly C_GRAY=$'\033[90m'

# ------------------------------------------------------------------------------
# 4. PRE-FLIGHT CHECKS
# ------------------------------------------------------------------------------

# Arithmetic context (( )) is faster for integer comparisons
if ((EUID == 0)); then
    printf '%s\n' "${C_RED}Error: This script manages USER services and should not be run as root.${C_RESET}" >&2
    printf '%s\n' "Please run as a standard user (without sudo)." >&2
    exit 1
fi

if ! command -v systemctl &>/dev/null; then
    printf '%s\n' "${C_RED}Error: systemd/systemctl is not installed.${C_RESET}" >&2
    exit 1
fi

if ((${#SERVICES[@]} == 0)); then
    printf '%s\n' "${C_RED}Error: No services configured in SERVICES array.${C_RESET}" >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# 5. HELPER FUNCTIONS
# ------------------------------------------------------------------------------

get_service_status() {
    local service_name="$1"
    # 2>/dev/null suppresses errors if the service unit file doesn't exist yet
    if systemctl --user is-active --quiet "$service_name" 2>/dev/null; then
        printf 'active'
    else
        printf 'inactive'
    fi
}

toggle_service() {
    local service_name="$1"
    local current_state result=0
    
    current_state=$(get_service_status "$service_name")

    # Using logical OR (||) to capture exit code avoids toggling 'set +e'
    if [[ "$current_state" == "active" ]]; then
        printf 'Stopping %s... ' "$service_name"
        systemctl --user disable --now "$service_name" &>/dev/null || result=$?
    else
        printf 'Starting %s... ' "$service_name"
        systemctl --user enable --now "$service_name" &>/dev/null || result=$?
    fi

    if ((result == 0)); then
        printf '%s\n' "${C_GREEN}Done.${C_RESET}"
    else
        printf '%s\n' "${C_RED}Failed!${C_RESET} (Check: systemctl --user status $service_name)"
        sleep 2
    fi
}

draw_ui() {
    clear
    # Use printf format strings instead of embedding vars for safety
    printf '%s\n' "${C_BOLD}Hyprland Service Manager${C_RESET}"
    printf '%s\n' "${C_GRAY}------------------------------------------------------------${C_RESET}"
    printf '%-4s %-12s %-30s %s\n' "ID" "STATUS" "SERVICE" "DESCRIPTION"
    printf '%s\n' "${C_GRAY}------------------------------------------------------------${C_RESET}"

    local idx=1 entry s_name s_desc status status_color status_icon
    
    for entry in "${SERVICES[@]}"; do
        s_name="${entry%%|*}"
        s_desc="${entry##*|}"
        status=$(get_service_status "$s_name")

        if [[ "$status" == "active" ]]; then
            status_color="$C_GREEN"
            status_icon="[ON]"
        else
            status_color="$C_RED"
            status_icon="[OFF]"
        fi

        printf '%s%-4s%s %s%-12s%s %-30s %s%s%s\n' \
            "$C_BOLD" "$idx)" "$C_RESET" \
            "$status_color" "$status_icon" "$C_RESET" \
            "$s_name" \
            "$C_GREEN" "$s_desc" "$C_RESET"
        
        # Use pre-increment to avoid potential 0-exit code issues with set -e
        ((++idx))
    done
    
    printf '%s\n' "${C_GRAY}------------------------------------------------------------${C_RESET}"
    printf '%s\n' "Type number to toggle, or 'q' to quit."
}

# ------------------------------------------------------------------------------
# 6. MAIN EXECUTION LOOP
# ------------------------------------------------------------------------------
main() {
    # Attempt to hide cursor. Fail silently if terminal doesn't support it.
    if tput civis 2>/dev/null; then
        CURSOR_HIDDEN=true
    fi

    local choice choice_num array_index selected_entry service_name
    local -r max_index=${#SERVICES[@]}

    while true; do
        draw_ui
        
        printf '\n%sAction: %s' "$C_CYAN" "$C_RESET"
        
        # 'if ! read' catches Ctrl+D (EOF) gracefully prevents crash
        if ! read -r choice; then
            break
        fi

        # Exit logic
        if [[ "$choice" =~ ^[qQ]$ ]]; then
            break
        fi

        # Empty input - just redraw
        [[ -z "$choice" ]] && continue

        # Validate: must be a positive integer
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
            # FORCE BASE-10: This prevents "08" or "09" from being interpreted as invalid octal
            choice_num=$((10#$choice))

            # Strict bounds checking
            if ((choice_num >= 1 && choice_num <= max_index)); then
                array_index=$((choice_num - 1))
                selected_entry="${SERVICES[$array_index]}"
                service_name="${selected_entry%%|*}"
                
                toggle_service "$service_name"
                sleep 0.5
            else
                printf '%s\n' "${C_RED}Invalid selection.${C_RESET}"
                sleep 1
            fi
        else
            printf '%s\n' "${C_RED}Invalid input.${C_RESET}"
            sleep 0.5
        fi
    done
}

main
