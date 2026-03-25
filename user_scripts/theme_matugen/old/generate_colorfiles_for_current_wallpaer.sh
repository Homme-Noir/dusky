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
err() { printf '\033[31m[ERROR]\033[0m %s\n' "$*" >&2; }

get_focused_monitor() {
    # Returns the focused Hyprland monitor name, or empty string if unavailable.
    # Suppresses errors to prevent script crash under 'set -e' if hyprctl fails.
    if command -v hyprctl &>/dev/null && command -v jq &>/dev/null; then
        hyprctl monitors -j 2>/dev/null | jq -r '.[] | select(.focused) | .name' 2>/dev/null || true
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Main Logic
# ══════════════════════════════════════════════════════════════════════════════

# 1. Verify swww-daemon is running
if ! pgrep -x "swww-daemon" >/dev/null; then
    err "swww-daemon is not running."
    exit 1
fi

# 2. Query swww for current wallpapers
# Capture output, failing gracefully if swww query dies
if ! swww_output=$(swww query); then
    err "swww query failed."
    exit 1
fi

if [[ -z "$swww_output" ]]; then
    err "swww query returned empty output."
    exit 1
fi

# 3. Determine target monitor and parse wallpaper path
target_monitor=$(get_focused_monitor)
raw_path=""

# Logic: If we found a focused monitor, try to find its specific line in swww output.
# Use grep -F (fixed string) to avoid issues with dots in monitor names.
if [[ -n "$target_monitor" ]] && grep -qF -- "$target_monitor" <<< "$swww_output"; then
    raw_path=$(grep -F -- "$target_monitor" <<< "$swww_output" | head -n1 | awk -F 'image: ' '{print $2}')
else
    # Fallback: Just take the first image found
    raw_path=$(head -n1 <<< "$swww_output" | awk -F 'image: ' '{print $2}')
fi

# Trim leading/trailing whitespace (Bash variable expansion magic)
# 1. Remove leading space
current_wallpaper="${raw_path#"${raw_path%%[![:space:]]*}"}"
# 2. Remove trailing space
current_wallpaper="${current_wallpaper%"${current_wallpaper##*[![:space:]]}"}"

# 4. Validate the parsed path
if [[ -z "$current_wallpaper" ]]; then
    err "Could not parse wallpaper path from swww query."
    exit 1
fi

if [[ ! -f "$current_wallpaper" ]]; then
    err "Wallpaper file does not exist: $current_wallpaper"
    exit 1
fi

# 5. Check cache to avoid redundant regeneration
# $(<file) is a faster bash builtin than $(cat file)
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
