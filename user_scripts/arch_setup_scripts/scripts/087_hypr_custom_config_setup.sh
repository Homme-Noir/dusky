#!/usr/bin/env bash
# ==============================================================================
# Script Name: setup_hypr_overlay.sh
# Description: Initializes or validates the 'edit_here' user configuration 
#              overlay for Hyprland. Ensures all template files exist.
#              Designed for Arch Linux/Hyprland/UWSM environments.
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. Strict Mode & Configuration
# ------------------------------------------------------------------------------
set -euo pipefail

# --- ANSI Color Codes ---
readonly RED=$'\033[0;31m'
readonly GREEN=$'\033[0;32m'
readonly YELLOW=$'\033[0;33m'
readonly BLUE=$'\033[0;34m'
readonly RESET=$'\033[0m'

# --- Paths ---
readonly HYPR_DIR="${HOME}/.config/hypr"
readonly SOURCE_DIR="${HYPR_DIR}/source"
readonly EDIT_DIR="${HYPR_DIR}/edit_here"
readonly EDIT_SOURCE_DIR="${EDIT_DIR}/source"
readonly MAIN_CONF="${HYPR_DIR}/hyprland.conf"
readonly NEW_CONF="${EDIT_DIR}/hyprland.conf"

# The path string written into configs (Single quotes to prevent expansion)
readonly INCLUDE_PATH='~/.config/hypr/edit_here/hyprland.conf'

# ------------------------------------------------------------------------------
# 2. Helper Functions
# ------------------------------------------------------------------------------
log_info()    { printf '%s[INFO]%s %s\n' "${BLUE}" "${RESET}" "$1"; }
log_success() { printf '%s[OK]%s   %s\n' "${GREEN}" "${RESET}" "$1"; }
log_warn()    { printf '%s[WARN]%s %s\n' "${YELLOW}" "${RESET}" "$1"; }
log_error()   { printf '%s[ERR]%s  %s\n' "${RED}" "${RESET}" "$1" >&2; }

# ------------------------------------------------------------------------------
# 3. Privilege & Pre-flight Checks
# ------------------------------------------------------------------------------
if [[ ${EUID} -eq 0 ]]; then
    log_error "This script must NOT be run as root."
    log_error "It modifies user configuration files in ${HOME}."
    exit 1
fi

if [[ ! -d ${SOURCE_DIR} ]]; then
    log_error "Source directory not found: ${SOURCE_DIR}"
    log_error "Cannot populate the edit_here directory. Aborting."
    exit 1
fi

if [[ ! -f ${MAIN_CONF} ]]; then
    log_warn "Main Hyprland config not found at ${MAIN_CONF}. Creating empty file."
    mkdir -p -- "${HYPR_DIR}"
    touch -- "${MAIN_CONF}"
fi

# ------------------------------------------------------------------------------
# 4. Main Logic: Create or Verify Overlay
# ------------------------------------------------------------------------------
log_info "Initializing/Verifying Hyprland user configuration overlay..."

# 1. Ensure Directory Structure (Idempotent: mkdir -p won't fail if it exists)
if [[ ! -d "${EDIT_SOURCE_DIR}" ]]; then
    log_info "Creating directory: ${EDIT_SOURCE_DIR}"
    mkdir -p -- "${EDIT_SOURCE_DIR}"
else
    log_info "Directory exists: ${EDIT_SOURCE_DIR} (checking contents...)"
fi

# 2. Define list of required configuration files
readonly CONFIG_FILES=(
    "monitors.conf"
    "keybinds.conf"
    "appearance.conf"
    "autostart.conf"
    "plugins.conf"
    "window_rules.conf"
    "environment_variables.conf"
)

# 3. Iterate and Create Missing Files
for file in "${CONFIG_FILES[@]}"; do
    target_file="${EDIT_SOURCE_DIR}/${file}"

    if [[ -f "${target_file}" ]]; then
        # File exists, skip it to protect user data
        log_info "  - Exists: ${file}"
    else
        # File missing, create it
        log_warn "  - Missing: ${file} -> Creating template..."
        
        cat > "${target_file}" <<EOF
# ==============================================================================
# USER CONFIGURATION: ${file}
# ==============================================================================
# Add your custom settings for ${file%.*} here.
# These will override or add to the defaults found in ~/.config/hypr/source/${file}
# ==============================================================================

EOF
        log_success "    Created template: ${file}"
    fi
done

# 4. Generate the user's overlay config file (The loader)
# Check if the loader exists
if [[ -f "${NEW_CONF}" ]]; then
    log_info "Loader file exists: ${NEW_CONF}"
else
    log_warn "Loader file missing: ${NEW_CONF} -> Creating..."
    cat > "${NEW_CONF}" <<'EOF'
# ==============================================================================
# USER CONFIGURATION OVERLAY
# ==============================================================================
# This file sources all your custom configuration files.
# Edit the specific files in 'source/' to apply your changes.
# ==============================================================================

source = ~/.config/hypr/edit_here/source/monitors.conf
source = ~/.config/hypr/edit_here/source/keybinds.conf
source = ~/.config/hypr/edit_here/source/appearance.conf
source = ~/.config/hypr/edit_here/source/autostart.conf
source = ~/.config/hypr/edit_here/source/plugins.conf
source = ~/.config/hypr/edit_here/source/window_rules.conf
source = ~/.config/hypr/edit_here/source/environment_variables.conf
EOF
    log_success "Created '${NEW_CONF}'."
fi

# ------------------------------------------------------------------------------
# 5. Modify Main Configuration
# ------------------------------------------------------------------------------
log_info "Verifying main configuration at '${MAIN_CONF}'..."

if grep -Fq -- "source = ${INCLUDE_PATH}" "${MAIN_CONF}"; then
    log_success "Main config already sources the overlay. No changes needed."
else
    # Append the source line
    printf '\n# Source User Custom Config Overlay\nsource = %s\n' "${INCLUDE_PATH}" >> "${MAIN_CONF}"
    log_success "Appended source directive to '${MAIN_CONF}'."
fi

# ------------------------------------------------------------------------------
# 6. Completion
# ------------------------------------------------------------------------------
printf '\n'
log_success "Setup/Verification complete!"
log_info "Your custom configs are located in: ${EDIT_DIR}"
log_info "To apply changes, restart Hyprland or run 'hyprctl reload'."
