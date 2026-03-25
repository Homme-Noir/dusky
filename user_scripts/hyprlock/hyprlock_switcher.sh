#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# Script: Hyprlock Theme Manager (htm)
# Description: Enterprise-grade configuration management for Hyprlock themes.
#              Optimized for Arch/Hyprland/UWSM ecosystems.
# Features:    Source-based loading, XDG compliance, ANSI-safe UI, Smart Detection.
# -----------------------------------------------------------------------------

set -uo pipefail

# --- Bash Version Check ---
if (( BASH_VERSINFO[0] < 5 )); then
    printf 'Error: Bash 5.0+ required (current: %s)\n' "$BASH_VERSION" >&2
    exit 1
fi

# --- Configuration & Constants ---
# Use distinct name to avoid shadowing the environment variable
readonly _CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
readonly CONFIG_ROOT="${_CONFIG_HOME}/hypr"
readonly THEMES_ROOT="${CONFIG_ROOT}/hyprlock_themes"

# State variables (Integers for boolean efficiency)
declare -i SELECTED_IDX=0
declare -i TOGGLE_MODE=0
declare -i PREVIEW_MODE=0
declare -i IN_ALTERNATE_SCREEN=0

# Global theme arrays
declare -a THEME_PATHS=()
declare -a THEME_NAMES=()

# --- Colors & Styling ---
readonly R=$'\033[0;31m'
readonly G=$'\033[0;32m'
readonly Y=$'\033[1;33m'
readonly B=$'\033[0;34m'
readonly C=$'\033[0;36m'
readonly NC=$'\033[0m'
readonly BOLD=$'\033[1m'
readonly DIM=$'\033[2m'

# --- Logging ---
log_info()    { printf '%s[INFO]%s %s\n' "$B" "$NC" "$*"; }
log_success() { printf '%s[SUCCESS]%s %s\n' "$G" "$NC" "$*"; }
log_warn()    { printf '%s[WARN]%s %s\n' "$Y" "$NC" "$*" >&2; }
log_err()     { printf '%s[ERROR]%s %s\n' "$R" "$NC" "$*" >&2; }

# --- Usage ---
usage() {
    cat <<EOF
${BOLD}Hyprlock Theme Manager${NC}

Usage: ${0##*/} [OPTIONS]

Options:
  --toggle      Cycle to the next theme (outputs name for notifications)
  --preview     Show config preview in interactive mode
  -h, --help    Show this help message

Theme path: ${THEMES_ROOT}/<theme>/hyprlock.conf
EOF
}

# --- Cleanup & Traps ---
cleanup() {
    # 1. Exit alternate screen (restore buffer)
    # 2. Restore cursor visibility
    # stderr silenced to prevent noise during shutdown errors
    if (( IN_ALTERNATE_SCREEN )); then
        tput rmcup 2>/dev/null || true
        tput cnorm 2>/dev/null || true
    fi
}
# Only trap EXIT; INT/TERM will trigger EXIT automatically. 
trap cleanup EXIT

# --- Dependencies ---
check_deps() {
    # 'head' removed (pure bash used instead), 'find', 'sort', 'tput', 'realpath' required
    local -a deps=(tput realpath find sort)
    local -a missing=()
    local cmd

    for cmd in "${deps[@]}"; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done

    if (( ${#missing[@]} )); then
        log_err "Missing core dependencies: ${missing[*]}"
        exit 1
    fi

    command -v jq &>/dev/null || \
        log_warn "jq not found; theme.json metadata will be ignored."
}

# --- Initialization ---
init() {
    if (( EUID == 0 )); then
        log_err "Do not run as root. User configuration only."
        exit 1
    fi

    if [[ ! -d "$THEMES_ROOT" ]]; then
        log_err "Themes directory not found: $THEMES_ROOT"
        log_info "Create it and add subdirectories containing 'hyprlock.conf'."
        exit 1
    fi

    check_deps
}

# --- Theme Discovery ---
discover_themes() {
    local config_file dir name

    # Optimization: Use process substitution + read loop to avoid subshells
    while IFS= read -r -d '' config_file; do
        # Optimization: Bash Parameter Expansion is 100x faster than $(dirname)
        dir="${config_file%/*}"
        THEME_PATHS+=("$dir")

        name=""
        # Parse theme.json if jq is available
        if [[ -f "${dir}/theme.json" ]] && command -v jq &>/dev/null; then
            name=$(jq -r '.name // empty' "${dir}/theme.json" 2>/dev/null) || true
        fi

        # Fallback to directory name
        if [[ -z "$name" ]]; then
             name="${dir##*/}"
        fi
        THEME_NAMES+=("$name")

    done < <(find "$THEMES_ROOT" -mindepth 2 -maxdepth 2 \
                  -name "hyprlock.conf" -print0 2>/dev/null | sort -z)

    if (( ${#THEME_PATHS[@]} == 0 )); then
        log_err "No themes found in $THEMES_ROOT"
        exit 1
    fi
}

# --- Detect Current Theme ---
detect_current_theme() {
    local target="${CONFIG_ROOT}/hyprlock.conf"
    local real_target=""
    local real_theme_dir candidate_resolved
    local -i i

    # If target doesn't exist, we default to index 0
    [[ -e "$target" ]] || return 0

    if [[ -L "$target" ]]; then
        # Handle legacy symlink detection
        real_target=$(realpath -- "$target" 2>/dev/null) || return 0
    elif [[ -f "$target" ]]; then
        # Handle new 'source = path' detection (Pure Bash)
        while IFS='=' read -r key value || [[ -n "$key" ]]; do
            # Trim leading/trailing whitespace
            key="${key#"${key%%[![:space:]]*}"}"
            key="${key%"${key##*[![:space:]]}"}"
            
            if [[ "$key" == "source" ]]; then
                # Extract path and trim
                local path="$value"
                path="${path#"${path%%[![:space:]]*}"}"
                path="${path%"${path##*[![:space:]]}"}"
                
                # Expand tilde if present
                if [[ "$path" == "~"* ]]; then
                    path="${HOME}${path:1}"
                fi
                
                real_target=$(realpath -- "$path" 2>/dev/null)
                break
            fi
        done < "$target"
    fi

    # If we couldn't resolve a target path, return
    [[ -n "$real_target" ]] || return 0
    
    real_theme_dir="${real_target%/*}"

    for (( i = 0; i < ${#THEME_PATHS[@]}; i++ )); do
        # FAST PATH: Pure string comparison (no fork)
        if [[ "${THEME_PATHS[i]}" == "$real_theme_dir" ]]; then
            SELECTED_IDX=$i
            return 0
        fi

        # SLOW PATH: Resolve symlinks (forks 'realpath')
        candidate_resolved=$(realpath -- "${THEME_PATHS[i]}" 2>/dev/null) || continue
        if [[ "$candidate_resolved" == "$real_theme_dir" ]]; then
            SELECTED_IDX=$i
            return 0
        fi
    done
}

# --- UI Drawing ---
draw_ui() {
    local -i i 

    # Clear screen (ANSI) and home cursor. 
    printf '\033[H\033[2J'

    # Header
    printf '%s%sHyprlock Theme Manager%s\n' "$BOLD" "$B" "$NC"
    printf '%s↑/k ↓/j:Navigate  Enter:Apply  q:Quit%s\n\n' "$DIM" "$NC"

    # Theme list
    for (( i = 0; i < ${#THEME_NAMES[@]}; i++ )); do
        if (( i == SELECTED_IDX )); then
            printf ' %s▸ %s%s\n' "$G$BOLD" "${THEME_NAMES[i]}" "$NC"
        else
            printf '   %s%s%s\n' "$DIM" "${THEME_NAMES[i]}" "$NC"
        fi
    done

    # Preview pane
    if (( PREVIEW_MODE )); then
        local conf="${THEME_PATHS[SELECTED_IDX]}/hyprlock.conf"
        printf '\n%s── Preview ──%s\n' "$C" "$NC"
        
        if [[ -r "$conf" ]]; then
            local line
            local -i count=0
            # Read first 10 lines safely (Pure Bash 'head')
            while (( count < 10 )) && IFS= read -r line; do
                printf '  %s%s%s\n' "$DIM" "$line" "$NC"
                (( count++ ))
            done < "$conf"
        else
            printf '  %s(unable to read config)%s\n' "$DIM" "$NC"
        fi
    fi
}

# --- Apply Theme ---
apply_theme() {
    local theme_dir="$1"
    local theme_name="$2"
    local target="${CONFIG_ROOT}/hyprlock.conf"
    local source="${theme_dir}/hyprlock.conf"

    # Validate source exists and is readable
    if [[ ! -r "$source" ]]; then
        log_err "Cannot read theme config: $source"
        return 1
    fi

    local source_entry="${source/#$HOME/\~}"

    if ! printf 'source = %s\n' "$source_entry" > "$target"; then
        log_err "Failed to write config file: $target"
        return 1
    fi

    if (( TOGGLE_MODE )); then
        # Just print the name. Useful for: notify-send "Theme" "$(htm --toggle)"
        printf '%s\n' "$theme_name"
    else
        log_success "Applied theme: $theme_name"
    fi
}

# --- Interactive Mode ---
run_interactive() {
    local -i total=${#THEME_PATHS[@]}
    local key seq

    # Robustness: Check if we are actually connected to a terminal
    if [[ ! -t 0 ]]; then
        log_err "Interactive mode requires a terminal (stdin is not a TTY)"
        exit 1
    fi

    # Enter alternate screen buffer (silenced)
    tput smcup 2>/dev/null || true
    tput civis 2>/dev/null || true
    IN_ALTERNATE_SCREEN=1

    while true; do
        draw_ui

        # Read single keypress
        IFS= read -rsn1 key || break

        # Handle escape sequences (arrow keys)
        if [[ "$key" == $'\x1b' ]]; then
            # Wait 0.1s for rest of sequence (standard for human/ssh latency)
            IFS= read -rsn2 -t 0.1 seq || seq=""
            key+="$seq"
        fi

        case "$key" in
            $'\x1b[A' | k)  # Up arrow or k
                (( SELECTED_IDX = (SELECTED_IDX - 1 + total) % total ))
                ;;
            $'\x1b[B' | j)  # Down arrow or j
                (( SELECTED_IDX = (SELECTED_IDX + 1) % total ))
                ;;
            '')  # Enter key (empty string from read -n1)
                # Cleanup MUST happen before applying to ensure logging works
                cleanup
                IN_ALTERNATE_SCREEN=0
                apply_theme "${THEME_PATHS[SELECTED_IDX]}" "${THEME_NAMES[SELECTED_IDX]}"
                exit $?
                ;;
            q | Q)
                exit 0
                ;;
            # Ignore raw escape to prevent accidental exit
            $'\x1b') ;;
        esac
    done
}

# --- Main Entry Point ---
main() {
    while (( $# )); do
        case "$1" in
            --toggle)
                TOGGLE_MODE=1
                ;;
            --preview)
                PREVIEW_MODE=1
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            --)
                shift
                break
                ;;
            -*)
                log_err "Unknown option: $1"
                usage >&2
                exit 1
                ;;
            *)
                break
                ;;
        esac
        shift
    done

    init
    discover_themes
    detect_current_theme

    if (( TOGGLE_MODE )); then
        local -i total=${#THEME_PATHS[@]}
        (( SELECTED_IDX = (SELECTED_IDX + 1) % total ))
        apply_theme "${THEME_PATHS[SELECTED_IDX]}" "${THEME_NAMES[SELECTED_IDX]}"
    else
        run_interactive
    fi
}

main "$@"
