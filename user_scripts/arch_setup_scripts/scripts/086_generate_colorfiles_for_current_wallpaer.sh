#!/usr/bin/env bash
# Description: Queries the active swww wallpaper and regenerates the Matugen color scheme.
# Usage: Run manually or bind to a key/hook.
# Dependencies: swww, matugen, jq, hyprland (optional, for focused monitor detection)

set -euo pipefail

# ══════════════════════════════════════════════════════════════════════════════
# Configuration
# ══════════════════════════════════════════════════════════════════════════════

readonly MATUGEN_MODE="dark"  # Options: light, dark
# Use XDG_RUNTIME_DIR for user-specific runtime files (safer than /tmp)
readonly CACHE_FILE="${XDG_RUNTIME_DIR:-/tmp}/matugen_wallpaper_cache"

# ══════════════════════════════════════════════════════════════════════════════
# Helper Functions
# ══════════════════════════════════════════════════════════════════════════════

log() { printf '\033[34m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[WARN]\033[0m %s\n' "$*"; }
err() { printf '\033[31m[ERROR]\033[0m %s\n' "$*" >&2; }

# Try to auto-detect Hyprland/Wayland socket if running from SSH/TTY
detect_display_env() {
    if [[ -z "${WAYLAND_DISPLAY:-}" ]]; then
        # Try to find the first Wayland socket in /run/user/$UID/
        local w_display
        w_display=$(find "/run/user/${UID}" -name "wayland-*" 2>/dev/null | head -n1 || true)
        if [[ -n "$w_display" ]]; then
            export WAYLAND_DISPLAY="${w_display##*/}"
        fi
    fi

    if [[ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]]; then
        # Try to find the first active Hyprland socket in /tmp/hypr
        local instance
        instance=$(ls -t /tmp/hypr/ 2>/dev/null | grep -v '\.lock$' | head -n1 || true)
        if [[ -n "$instance" ]]; then
            export HYPRLAND_INSTANCE_SIGNATURE="$instance"
        fi
    fi
}

get_focused_monitor() {
    # Returns the focused Hyprland monitor name, or empty string if unavailable.
    if command -v hyprctl &>/dev/null && command -v jq &>/dev/null; then
        hyprctl monitors -j 2>/dev/null | jq -r '.[] | select(.focused) | .name' 2>/dev/null || true
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Main Logic
# ══════════════════════════════════════════════════════════════════════════════

main() {
    # 0. Attempt to fix environment for SSH/TTY users
    detect_display_env

    # 1. Verify swww-daemon is running
    if ! pgrep -x "swww-daemon" >/dev/null; then
        warn "swww-daemon is not running. Skipping color generation."
        exit 0
    fi

    # 2. Query swww for current wallpapers
    # Capture output, failing gracefully if swww query dies
    local swww_output
    if ! swww_output=$(swww query 2>/dev/null); then
        warn "swww query failed (No active session?). Skipping color generation."
        exit 0
    fi

    if [[ -z "$swww_output" ]]; then
        warn "swww query returned empty output. Skipping."
        exit 0
    fi

    # 3. Determine target monitor and parse wallpaper path
    local target_monitor raw_path=""
    target_monitor=$(get_focused_monitor)

    # Logic: If we found a focused monitor, try to find its specific line in swww output.
    if [[ -n "$target_monitor" ]] && grep -qF -- "$target_monitor" <<< "$swww_output"; then
        raw_path=$(grep -F -- "$target_monitor" <<< "$swww_output" | head -n1 | awk -F 'image: ' '{print $2}')
    else
        # Fallback: Just take the first image found
        raw_path=$(head -n1 <<< "$swww_output" | awk -F 'image: ' '{print $2}')
    fi

    # Trim leading/trailing whitespace
    local current_wallpaper
    current_wallpaper="${raw_path#"${raw_path%%[![:space:]]*}"}"
    current_wallpaper="${current_wallpaper%"${current_wallpaper##*[![:space:]]}"}"

    # 4. Validate the parsed path
    if [[ -z "$current_wallpaper" ]]; then
        warn "Could not parse wallpaper path from swww query. Skipping."
        exit 0
    fi

    if [[ ! -f "$current_wallpaper" ]]; then
        warn "Wallpaper file does not exist: $current_wallpaper. Skipping."
        exit 0
    fi

    # 5. Check cache to avoid redundant regeneration
    if [[ -f "$CACHE_FILE" ]] && [[ "$(<"$CACHE_FILE")" == "$current_wallpaper" ]]; then
        log "Colors already generated for this wallpaper. Skipping."
        exit 0
    fi

    # 6. Generate colors with matugen
    log "Detected: $current_wallpaper"
    log "Generating colors..."

    if matugen --mode "$MATUGEN_MODE" image "$current_wallpaper"; then
        # Atomic update of cache file using printf for safety
        printf '%s' "$current_wallpaper" > "$CACHE_FILE"
        log "Done."
    else
        err "Matugen failed to generate colors."
        exit 1
    fi
}

main "$@"
