#!/usr/bin/env bash
# =============================================================================
# Dusk Wallpaper Installer for Arch/Hyprland
# - Idempotent: safe to re-run (cleans old, resumes partial downloads)
# - Bandwidth-Optimized: byte-level resume via curl -C -
# - Robust: Correct terminal handling, atomic moves, safe globbing
# =============================================================================

set -euo pipefail

# --- Configuration -----------------------------------------------------------
readonly ZIP_URL="https://github.com/dusklinux/images/archive/refs/heads/main.zip"
readonly TARGET_PARENT="${HOME:?HOME not set}/Pictures"
readonly WALLPAPERS_DIR="${TARGET_PARENT}/wallpapers"
readonly CACHE_DIR="${TARGET_PARENT}/.dusk-wallpapers-cache"
readonly CACHE_FILE="${CACHE_DIR}/dusk-wallpapers.zip"

# --- Terminal Setup (graceful degradation) -----------------------------------
if [[ -t 1 ]]; then
    readonly RST=$'\033[0m' BOLD=$'\033[1m'
    readonly RED=$'\033[31m' GRN=$'\033[32m' YEL=$'\033[33m' BLU=$'\033[34m'
    readonly CLR=$'\033[K'  # ANSI Code: Clear to end of line
    readonly IS_TTY=1
else
    readonly RST='' BOLD='' RED='' GRN='' YEL='' BLU='' CLR=''
    readonly IS_TTY=0
fi

# --- Logging -----------------------------------------------------------------
log_info()  { printf '%s[INFO]%s %s\n' "${BLU}" "${RST}" "$*"; }
log_ok()    { printf '%s[ OK ]%s %s\n' "${GRN}" "${RST}" "$*"; }
log_warn()  { printf '%s[WARN]%s %s\n' "${YEL}" "${RST}" "$*" >&2; }
log_error() { printf '%s[ERR]%s  %s\n' "${RED}" "${RST}" "$*" >&2; }

# --- Status Indicator --------------------------------------------------------
# This replaces the background spinner. It uses Carriage Return (\r) to 
# overwrite the current line, ensuring the terminal never gets garbled.

declare -g CURRENT_STATUS=""

status_begin() {
    CURRENT_STATUS="$1"
    if (( IS_TTY )); then
        # Print [....] Task Name...
        printf '\r%s[....]%s %s%s' "${BLU}" "${RST}" "${CURRENT_STATUS}" "${CLR}"
    fi
    # If not TTY (logs), we wait until the end to print to avoid noise.
}

status_end() {
    local -r rc=$1
    if (( IS_TTY )); then
        if (( rc == 0 )); then
            # Overwrite with [ OK ]
            printf '\r%s[ OK ]%s %s%s\n' "${GRN}" "${RST}" "${CURRENT_STATUS}" "${CLR}"
        else
            # Overwrite with [FAIL]
            printf '\r%s[FAIL]%s %s%s\n' "${RED}" "${RST}" "${CURRENT_STATUS}" "${CLR}"
        fi
    else
        # Non-TTY Fallback
        if (( rc == 0 )); then
            log_ok "${CURRENT_STATUS}"
        else
            log_error "${CURRENT_STATUS}"
        fi
    fi
    CURRENT_STATUS=""
}

# --- Cleanup Trap ------------------------------------------------------------
cleanup() {
    local -r exit_code=$?

    # If we are interrupting a status line, print a newline so the prompt is clean
    if [[ -n "${CURRENT_STATUS}" ]] && (( IS_TTY )); then
        printf '\n'
    fi

    # Report failure (ignoring standard success 0 and user interrupt 130)
    if (( exit_code != 0 && exit_code != 130 )); then
        log_error "Script failed (exit ${exit_code})."
        if [[ -f "${CACHE_FILE}" ]]; then
            log_info "Partial download preserved: ${CACHE_FILE}"
        fi
    fi
}
trap cleanup EXIT

# --- Dependency Verification -------------------------------------------------
check_deps() {
    local -a missing=()
    local dep

    for dep in curl unzip; do
        command -v "${dep}" &>/dev/null || missing+=("${dep}")
    done

    if (( ${#missing[@]} > 0 )); then
        log_error "Missing dependencies: ${missing[*]}"
        log_error "Install with: sudo pacman -S ${missing[*]}"
        return 1
    fi
    return 0
}

# --- Download with Resume Support --------------------------------------------
download_archive() {
    local curl_rc=0

    # Calculate resume size
    if [[ -f "${CACHE_FILE}" ]]; then
        local file_bytes
        file_bytes=$(stat -c%s "${CACHE_FILE}" 2>/dev/null) || file_bytes=0
        # Convert to MB (bytes / 1024^2)
        local -r size_mb=$(( file_bytes / 1048576 ))
        
        if (( size_mb > 0 )); then
            log_info "Resuming partial download (${size_mb} MB cached)..."
        else
            log_info "Restarting download (empty cache file)..."
        fi
    else
        log_info "Starting fresh download..."
    fi

    # We hand control to CURL here. It handles the progress bar.
    # -f: Fail on HTTP error
    # -L: Follow redirects
    # -C -: Auto-Resume (The Critical Feature)
    # --retry: Robustness against network blips
    curl -fL -C - --retry 10 --retry-delay 5 \
         -o "${CACHE_FILE}" "${ZIP_URL}" || curl_rc=$?

    case ${curl_rc} in
        0)
            log_ok "Download complete."
            ;;
        33|36)
            # Exit 33: HTTP Range not supported
            # Exit 36: Bad resume offset (e.g. file is already bigger than source)
            # This usually means the file is already 100% done.
            status_begin "Verifying existing file"
            if unzip -tq "${CACHE_FILE}" &>/dev/null; then
                status_end 0
                log_ok "Archive already complete. Skipping re-download."
                return 0
            fi
            status_end 1
            
            log_warn "Resume failed (server file changed?). Re-downloading from scratch..."
            rm -f -- "${CACHE_FILE}"
            curl -fL --retry 10 --retry-delay 5 -o "${CACHE_FILE}" "${ZIP_URL}"
            log_ok "Download complete."
            ;;
        *)
            log_error "Download failed (curl exit: ${curl_rc})."
            return 1
            ;;
    esac
    return 0
}

# --- Archive Extraction ------------------------------------------------------
extract_archive() {
    status_begin "Verifying archive integrity"
    if ! unzip -tq "${CACHE_FILE}" &>/dev/null; then
        status_end 1
        log_error "Archive corrupted. Deleting to allow fresh download on next run."
        rm -f -- "${CACHE_FILE}"
        return 1
    fi
    status_end 0

    status_begin "Extracting wallpapers"
    if ! unzip -qo "${CACHE_FILE}" -d "${CACHE_DIR}"; then
        status_end 1
        log_error "Extraction failed."
        return 1
    fi
    status_end 0
    return 0
}

# --- Locate Extracted Directory ----------------------------------------------
find_extracted_root() {
    local result

    # Run inside subshell ( ) to isolate 'shopt' changes.
    # This prevents 'nullglob' from leaking into the rest of the script.
    result=$(
        shopt -s nullglob
        candidates=("${CACHE_DIR}"/images-*/)
        (( ${#candidates[@]} > 0 )) && printf '%s' "${candidates[0]%/}"
        true # Ensure exit code 0 so the script doesn't die here
    )

    if [[ -z "${result}" ]]; then
        log_error "Extracted folder not found in ${CACHE_DIR}."
        return 1
    fi

    printf '%s' "${result}"
}

# --- Install Wallpapers ------------------------------------------------------
install_wallpapers() {
    local -r src="$1"
    local count=0

    log_info "Installing wallpapers..."

    # mv -T (Target is file) ensures we don't accidentally move the folder 
    # *inside* an existing folder if the cleanup failed.
    
    if [[ -d "${src}/dark" ]]; then
        mv -T -- "${src}/dark" "${WALLPAPERS_DIR}/active_theme"
        log_ok "Installed: dark → wallpapers/active_theme"
        (( ++count ))
    else
        log_warn "'dark' directory not found in archive."
    fi

    if [[ -d "${src}/light" ]]; then
        mv -T -- "${src}/light" "${TARGET_PARENT}/light"
        log_ok "Installed: light → Pictures/light"
        (( ++count ))
    else
        log_warn "'light' directory not found in archive."
    fi

    if (( count == 0 )); then
        log_error "No wallpapers were installed."
        return 1
    fi
    return 0
}

# --- Main Entry Point --------------------------------------------------------
main() {
    printf '%s:: Dusk Wallpaper Installer%s\n' "${BOLD}" "${RST}"
    printf '   Download curated wallpaper collection? (~1.7 GB)\n'

    if [[ ! -t 0 ]]; then
        log_error "Interactive terminal required for confirmation prompt."
        return 1
    fi

    local response
    read -r -p "   [y/N] > " response
    case "${response,,}" in
        y|yes) ;;
        *)     log_info "Aborted by user."; return 0 ;;
    esac

    check_deps

    mkdir -p -- "${TARGET_PARENT}" "${WALLPAPERS_DIR}" "${CACHE_DIR}"

    status_begin "Removing old wallpaper directories"
    rm -rf -- "${TARGET_PARENT}/dark" \
              "${TARGET_PARENT}/light" \
              "${WALLPAPERS_DIR}/active_theme" \
              "${WALLPAPERS_DIR}/dark" \
              "${WALLPAPERS_DIR}/light"
    status_end 0

    download_archive
    extract_archive

    local extracted_root
    extracted_root=$(find_extracted_root)
    install_wallpapers "${extracted_root}"

    rm -rf -- "${CACHE_DIR}"

    log_ok "Installation complete."
    # Use ~ instead of full home path for cleaner output
    log_info "Location: ${TARGET_PARENT/#"${HOME}"/\~}"
    return 0
}

main "$@"
