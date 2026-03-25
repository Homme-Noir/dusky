#!/usr/bin/env bash
# ==============================================================================
#  DUSKY SMART RESTORE & STASH MANAGER (v2.5 - Message Clarity Fix)
#  Description: Intelligent interface for managing dotfile backups and stashes.
#               Distinguishes between auto-updates, recovery snapshots, and
#               manual edits. Safely restores states even with dirty work trees.
#  Context:     Arch Linux / Hyprland / Bash 5+ / UWSM Compliant
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# CONFIGURATION
# ------------------------------------------------------------------------------
readonly DOTFILES_GIT_DIR="${HOME}/dusky"
readonly WORK_TREE="${HOME}"
readonly RESTORE_DIR_BASE="${HOME}/Documents/dusky_restores"

# Validate git binary at script startup to prevent runtime failures
# Exit code 127 is the standard "command not found" code
readonly GIT_BIN="$(command -v git)" || { printf 'FATAL: git is not installed.\n' >&2; exit 127; }

# State: Populated by list_stashes(), consumed by main()
declare -a STASH_LIST=()

# ------------------------------------------------------------------------------
# VISUAL CONFIGURATION
# ------------------------------------------------------------------------------
if [[ -t 1 ]]; then
    readonly C_RESET=$'\e[0m'
    readonly C_BOLD=$'\e[1m'
    readonly C_DIM=$'\e[2m'
    readonly C_RED=$'\e[31m'
    readonly C_GREEN=$'\e[32m'
    readonly C_YELLOW=$'\e[33m'
    readonly C_BLUE=$'\e[34m'
    readonly C_MAGENTA=$'\e[35m'
    readonly C_CYAN=$'\e[36m'
else
    readonly C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN=''
    readonly C_YELLOW='' C_BLUE='' C_MAGENTA='' C_CYAN=''
fi

# ------------------------------------------------------------------------------
# UTILITIES
# ------------------------------------------------------------------------------
log_info() { printf '%s[INFO]%s  %s\n' "${C_BLUE}" "${C_RESET}" "$1"; }
log_ok()   { printf '%s[OK]%s    %s\n' "${C_GREEN}" "${C_RESET}" "$1"; }
log_warn() { printf '%s[WARN]%s  %s\n' "${C_YELLOW}" "${C_RESET}" "$1"; }
log_err()  { printf '%s[ERR]%s   %s\n' "${C_RED}" "${C_RESET}" "$1" >&2; }

# Wrapper for bare repository commands
dotgit() {
    "${GIT_BIN}" --git-dir="${DOTFILES_GIT_DIR}" --work-tree="${WORK_TREE}" "$@"
}

# ------------------------------------------------------------------------------
# PRE-FLIGHT CHECKS
# ------------------------------------------------------------------------------
if [[ ! -d "${DOTFILES_GIT_DIR}" ]]; then
    log_err "Repository not found at ${DOTFILES_GIT_DIR}"
    exit 1
fi

if [[ -f "${DOTFILES_GIT_DIR}/index.lock" ]]; then
    log_err "Git is locked (index.lock exists)."
    log_warn "Run: rm -f ${DOTFILES_GIT_DIR}/index.lock"
    exit 1
fi

# CRITICAL: Enforce execution from the Work Tree.
# This ensures 'git stash apply' and relative paths function correctly.
cd "${WORK_TREE}" || { log_err "Failed to change directory to WORK_TREE: ${WORK_TREE}"; exit 1; }

# ------------------------------------------------------------------------------
# UI COMPONENTS
# ------------------------------------------------------------------------------
print_header() {
    # Clear screen using ANSI escape sequences (faster/safer than spawning 'clear')
    printf '\033[2J\033[H'
    printf '%s================================================================%s\n' "${C_BLUE}" "${C_RESET}"
    printf '%s   DUSKY SMART RESTORE UTILITY%s\n' "${C_BOLD}${C_MAGENTA}" "${C_RESET}"
    printf '%s   Review, Export, and Restore your System Snapshots%s\n' "${C_DIM}" "${C_RESET}"
    printf '%s================================================================%s\n\n' "${C_BLUE}" "${C_RESET}"
}

# ------------------------------------------------------------------------------
# STASH PARSING & LISTING
# ------------------------------------------------------------------------------
list_stashes() {
    mapfile -t STASH_LIST < <(dotgit stash list)

    if [[ ${#STASH_LIST[@]} -eq 0 ]]; then
        printf '  %sNo stashes found. Your git stack is clean.%s\n\n' "${C_YELLOW}" "${C_RESET}"
        exit 0
    fi

    printf '  %s%-5s %-12s %-25s %s%s\n' "${C_DIM}" "ID" "TYPE" "TIMESTAMP/ID" "MESSAGE" "${C_RESET}"
    printf '  %s----------------------------------------------------------------%s\n' "${C_DIM}" "${C_RESET}"

    local line msg_raw msg
    local label color time_display clean_msg
    local tmp_date
    local stash_count=${#STASH_LIST[@]}

    # C-style loop for clearer integer handling
    for ((i = 0; i < stash_count; i++)); do
        line="${STASH_LIST[i]}"

        # --- Pure Bash Parsing ---
        # 1. Strip stash ref "stash@{0}: "
        msg_raw="${line#*: }"
        # 2. Strip branch info "On main: "
        msg="${msg_raw#*: }"

        # 3. Trim leading whitespace using parameter expansion
        msg="${msg#"${msg%%[![:space:]]*}"}"

        # --- Heuristic Analysis ---
        label=""
        color=""
        time_display=""
        clean_msg="${msg}"

        if [[ "${msg}" =~ orchestrator-auto-([0-9_-]+) ]]; then
            label="UPDATE"
            color="${C_CYAN}"
            time_display="${BASH_REMATCH[1]}"
            clean_msg="Auto-Backup during system update"
        elif [[ "${msg}" =~ recovery-backup-([0-9]+) ]]; then
            label="RECOVER"
            color="${C_RED}"
            if tmp_date=$(date -d "@${BASH_REMATCH[1]}" +'%Y-%m-%d %H:%M' 2>/dev/null); then
                time_display="${tmp_date}"
            else
                time_display="${BASH_REMATCH[1]}"
            fi
            clean_msg="Emergency snapshot from Force Sync"
        elif [[ "${msg_raw}" == "WIP on "* || "${msg_raw}" == "On "* ]]; then
            label="MANUAL"
            color="${C_BLUE}"
            time_display="--"
            # FIX: Use the actual message we parsed, or fallback if empty
            if [[ -n "${msg}" ]]; then
                clean_msg="${msg}"
            else
                clean_msg="Manual Save state / Work in Progress"
            fi
        else
            label="CUSTOM"
            color="${C_MAGENTA}"
            time_display="--"
        fi

        printf '  %s[%d]%s   %s%-10s%s   %-25s %s%s%s\n' \
            "${C_BOLD}" "${i}" "${C_RESET}" \
            "${color}" "${label}" "${C_RESET}" \
            "${time_display:0:24}" \
            "${C_DIM}" "${clean_msg:0:40}" "${C_RESET}"
    done
    printf '\n'
}

# ------------------------------------------------------------------------------
# CORE LOGIC
# ------------------------------------------------------------------------------

get_stash_hash() {
    local idx="$1"
    local sha
    if ! sha=$(dotgit rev-parse "stash@{${idx}}" 2>/dev/null); then
        log_err "Failed to resolve stash@{${idx}}. It may have been dropped."
        return 1
    fi
    printf '%s' "${sha}"
}

# Bare-Repo Safe Export: Extracts ONLY modified files directly from Object DB
export_stash() {
    local stash_sha="$1"
    local restore_path="${RESTORE_DIR_BASE}/restored_backup_$(date +%Y%m%d_%H%M%S)"
    local -a changed_files=()
    local file target_dir

    printf '\n%s[EXPORT MODE]%s\n' "${C_BLUE}" "${C_RESET}"
    log_info "Analyzing stash contents (${stash_sha:0:12})..."

    # 1. Get the list of modified files in this stash (delta only)
    mapfile -t changed_files < <(dotgit stash show --name-only "${stash_sha}" 2>/dev/null)

    if [[ ${#changed_files[@]} -eq 0 ]]; then
        log_warn "This stash appears to be empty or contains no tracked file changes."
        return 0
    fi

    if ! mkdir -p "${restore_path}"; then
        log_err "Failed to create base directory: ${restore_path}"
        return 1
    fi

    log_info "Exporting ${#changed_files[@]} modified file(s)..."

    for file in "${changed_files[@]}"; do
        # 2. Check if file exists in the stash (it might be a deletion)
        if ! dotgit cat-file -e "${stash_sha}:${file}" 2>/dev/null; then
            log_warn "File '${file}' was deleted in this stash. Skipping export."
            continue
        fi

        # 3. Create directory structure (Pure Bash Optimization)
        # Only attempt mkdir if the file is in a subdirectory
        if [[ "${file}" == */* ]]; then
            target_dir="${restore_path}/${file%/*}"
            if ! mkdir -p "${target_dir}"; then
                log_err "Failed to create directory: ${target_dir}"
                continue
            fi
        fi

        # 4. Dump content from the Object DB
        if dotgit show "${stash_sha}:${file}" > "${restore_path}/${file}"; then
            printf '    %s•%s %s\n' "${C_DIM}" "${C_RESET}" "${file}"
        else
            log_err "Failed to export: ${file}"
        fi
    done

    log_ok "Export successful!"
    printf '\n%s Files are located at:%s\n' "${C_GREEN}" "${C_RESET}"
    printf '  %s%s%s\n\n' "${C_BOLD}" "${restore_path}" "${C_RESET}"

    local open_choice
    read -r -p "  View exported files? [y/N] " open_choice
    if [[ "${open_choice}" =~ ^[Yy]$ ]]; then
        if command -v yazi &>/dev/null; then
            yazi "${restore_path}"
        elif command -v ranger &>/dev/null; then
            ranger "${restore_path}"
        elif command -v thunar &>/dev/null; then
            uwsm-app -- thunar "${restore_path}" &
            disown
        else
            ls -lR "${restore_path}"
        fi
    fi
}

apply_stash() {
    local stash_sha="$1"
    local confirm

    printf '\n%s[RESTORE MODE]%s\n' "${C_RED}" "${C_RESET}"
    printf '  You are about to overwrite your current configuration with an older snapshot.\n'

    # Check for dirty state using bare repo wrapper
    if ! dotgit diff-index --quiet HEAD --; then
        printf '  %s[!] Local changes detected in your working directory.%s\n' "${C_YELLOW}" "${C_RESET}"
        printf '      Applying a stash now would normally fail or cause conflicts.\n'
        printf '      %sDusky Auto-Safety%s will stash these changes for you first.\n\n' "${C_GREEN}" "${C_RESET}"

        read -r -p "  Proceed with Safety Stash & Restore? [y/N] " confirm
        if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
            log_info "Aborted by user."
            return 0
        fi

        log_info "Creating Safety Stash of current state..."
        if dotgit stash push -m "Safety-Stash-Before-Restore-$(date +%s)"; then
            log_ok "Current state saved. Working directory is clean."
        else
            log_err "Failed to create safety stash. Aborting to protect data."
            return 1
        fi
    else
        read -r -p "  Proceed with Restore? [y/N] " confirm
        if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
            log_info "Aborted by user."
            return 0
        fi
    fi

    log_info "Applying snapshot (${stash_sha:0:12})..."

    if dotgit stash apply "${stash_sha}"; then
        printf '\n'
        log_ok "Configuration successfully restored!"
        printf '  The stash entry was kept in the list for safety.\n'
    else
        printf '\n'
        log_warn "Restore completed with CONFLICTS."
        printf '  Git could not auto-merge some files.\n'
        printf '  Check "git status" to see conflicted files.\n'
    fi
}

# ------------------------------------------------------------------------------
# MAIN EXECUTION
# ------------------------------------------------------------------------------
main() {
    print_header
    list_stashes

    local stash_count=${#STASH_LIST[@]}
    local idx

    printf 'Select a stash ID [0-%d] or "q" to quit: ' "$((stash_count - 1))"
    read -r idx

    [[ "${idx}" == "q" ]] && exit 0

    if [[ ! "${idx}" =~ ^[0-9]+$ ]] || ((idx >= stash_count)); then
        log_err "Invalid selection: '${idx}'"
        exit 1
    fi

    local target_sha
    if ! target_sha=$(get_stash_hash "${idx}"); then
        exit 1
    fi

    printf '\n%sSelected Stash:%s %s\n' "${C_BOLD}" "${C_RESET}" "${STASH_LIST[idx]}"
    printf 'Action:\n'
    printf '  %s[1]%s Overwrite/Restore System Config  %s(Safe Apply)%s\n' "${C_RED}" "${C_RESET}" "${C_DIM}" "${C_RESET}"
    printf '  %s[2]%s Export to Directory              %s(Inspect Files)%s\n' "${C_GREEN}" "${C_RESET}" "${C_DIM}" "${C_RESET}"
    printf '  %s[q]%s Quit\n' "${C_DIM}" "${C_RESET}"

    local action
    read -r -p "Choice > " action

    case "${action}" in
        1) apply_stash "${target_sha}" ;;
        2) export_stash "${target_sha}" ;;
        q) exit 0 ;;
        *) log_err "Invalid action: '${action}'"; exit 1 ;;
    esac
}

main
