#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Script: reinstall_wayclick.sh
# Description: Safely resets the 'wayclick' environment.
#              1. Stops running instances.
#              2. Removes the container directory.
#              3. Triggers the setup script.
# Environment: Arch Linux (Hyprland + UWSM)
# Author: Elite DevOps (Generated & Optimized)
# -----------------------------------------------------------------------------

set -euo pipefail

# 1. Aesthetics & Logging (TTY Aware)
# -----------------------------------
# Only define colors if outputting to a terminal. 
# Prevents garbage characters in log files.
if [[ -t 1 ]]; then
    readonly C_RESET=$'\033[0m'
    readonly C_GREEN=$'\033[1;32m'
    readonly C_BLUE=$'\033[1;34m'
    readonly C_RED=$'\033[1;31m'
    readonly C_YELLOW=$'\033[1;33m'
else
    readonly C_RESET='' C_GREEN='' C_BLUE='' C_RED='' C_YELLOW=''
fi

log_info()    { printf "%s[INFO]%s %s\n" "${C_BLUE}" "${C_RESET}" "$1"; }
log_success() { printf "%s[OK]%s %s\n" "${C_GREEN}" "${C_RESET}" "$1"; }
log_warn()    { printf "%s[WARN]%s %s\n" "${C_YELLOW}" "${C_RESET}" "$1"; }
log_error()   { printf "%s[ERROR]%s %s\n" "${C_RED}" "${C_RESET}" "$1" >&2; }

# 2. Cleanup Trap
# ---------------
# Captures exit code to ensure we don't swallow errors during cleanup
cleanup() {
    local exit_code=$?
    # Reset terminal colors if they were set
    [[ -n "${C_RESET}" ]] && printf "%s" "${C_RESET}"
    exit "${exit_code}"
}
trap cleanup EXIT

# 3. Configuration
# ----------------
readonly APP_NAME="wayclick"
readonly DIR_TO_DELETE="${HOME}/contained_apps/uv/${APP_NAME}"
readonly SETUP_SCRIPT="${HOME}/user_scripts/arch_setup_scripts/scripts/081_key_sound_wayclick_setup.sh"

# 4. Core Logic
# -------------
main() {
    # -- Privilege Guard --
    # Using Arithmetic context for integer comparison is cleaner
    if (( EUID == 0 )); then
        log_error "This script manages user-level files in HOME."
        log_error "Do NOT run with sudo. Run as your regular user."
        exit 1
    fi

    log_info "Initializing ${APP_NAME} reset procedure..."

    # -- Pre-flight: Validation --
    if [[ ! -f "${SETUP_SCRIPT}" ]]; then
        log_error "Setup script missing. Cannot proceed with reinstall."
        log_error "File expected: ${SETUP_SCRIPT}"
        exit 1
    fi

    if [[ ! -x "${SETUP_SCRIPT}" ]]; then
        log_warn "Fixing permissions on setup script..."
        chmod +x "${SETUP_SCRIPT}"
    fi

    # -- Step 1: Stop Running Instances --
    # Use EUID for reliable process matching.
    # Redirect stderr to void to keep output clean if no process found.
    if pgrep -u "${EUID}" -x "${APP_NAME}" >/dev/null 2>&1; then
        log_info "Stopping running ${APP_NAME} instances..."
        
        # 1. Polite Kill (SIGTERM)
        pkill -u "${EUID}" -x "${APP_NAME}" 2>/dev/null || true
        
        # 2. Wait Loop (Fixed: Logic prevents 'set -e' crash)
        # We use a for loop to avoid manual increment math errors
        for _ in {1..3}; do
            if ! pgrep -u "${EUID}" -x "${APP_NAME}" >/dev/null 2>&1; then
                break
            fi
            sleep 1
        done

        # 3. Force Kill (SIGKILL) if still stubborn
        if pgrep -u "${EUID}" -x "${APP_NAME}" >/dev/null 2>&1; then
            log_warn "Process stubborn. Forcing kill..."
            pkill -9 -u "${EUID}" -x "${APP_NAME}" 2>/dev/null || true
            sleep 0.5 # Give kernel a moment to release file handles
        fi
        
        log_success "Processes stopped."
    fi

    # -- Step 2: Delete Directory --
    # Safety Check: strict validation to ensure we are inside HOME
    # This prevents disasters if variables are somehow malformed.
    if [[ -z "${DIR_TO_DELETE}" ]] || \
       [[ "${DIR_TO_DELETE}" == "/" ]] || \
       [[ "${DIR_TO_DELETE}" == "${HOME}" ]] || \
       [[ "${DIR_TO_DELETE}" != "${HOME}/"* ]]; then
         log_error "Safety Guard Triggered: Invalid delete target."
         log_error "Path: ${DIR_TO_DELETE:-EMPTY}"
         exit 1
    fi

    if [[ -d "${DIR_TO_DELETE}" ]]; then
        log_info "Removing directory: ${DIR_TO_DELETE}"
        rm -rf "${DIR_TO_DELETE}"
        log_success "Cleaned up old installation."
    else
        log_info "Directory already clean."
    fi

    # -- Step 3: Execute Setup --
    log_info "Triggering setup script..."
    log_info "---------------------------------------------------"
    
    # Run the setup script
    "${SETUP_SCRIPT}"

    log_info "---------------------------------------------------"
    log_success "Reset sequence complete."
}

main "$@"
