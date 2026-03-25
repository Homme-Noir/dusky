#!/bin/bash
# -----------------------------------------------------------------------------
# hypr_songrec.sh - Shazam-like audio recognition for Hyprland/Wayland
# -----------------------------------------------------------------------------

set -euo pipefail

# -----------------------------------------------------------------------------
# Constants & Configuration (readonly for safety)
# -----------------------------------------------------------------------------
readonly SCRIPT_NAME="${0##*/}"
readonly TIMEOUT_SECS=20
readonly INTERVAL=4
readonly LOCK_FILE="/tmp/hypr_songrec.lock"

# Map commands to their Arch Linux package names.
declare -Ar RELIES_ON=(
    ["ffmpeg"]="ffmpeg"
    ["notify-send"]="libnotify"
    ["jq"]="jq"
    ["pactl"]="libpulse"
    ["parec"]="libpulse"      # parec is also from libpulse (or pipewire-pulse)
    ["songrec"]="songrec"
)

# These will be set by setup_environment()
TMP_DIR=""
RAW_FILE=""
MP3_FILE=""
REC_PID=""

# -----------------------------------------------------------------------------
# Utility Functions
# -----------------------------------------------------------------------------
log_info() {
    printf '[%s] INFO: %s\n' "$SCRIPT_NAME" "$1" >&2
}

log_error() {
    printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$1" >&2
}

die() {
    log_error "$1"
    exit "${2:-1}"
}

# -----------------------------------------------------------------------------
# 0. Auto-Install Dependencies
# -----------------------------------------------------------------------------
install_dependencies() {
    local -a to_install=()
    local cmd pkg

    for cmd in "${!RELIES_ON[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            pkg="${RELIES_ON[$cmd]}"
            # Avoid adding duplicates to the install list
            local already_queued=0
            for queued_pkg in "${to_install[@]+"${to_install[@]}"}"; do
                [[ "$queued_pkg" == "$pkg" ]] && { already_queued=1; break; }
            done
            if (( !already_queued )); then
                log_info "Command '$cmd' not found. Queueing package '$pkg'..."
                to_install+=("$pkg")
            fi
        fi
    done

    if (( ${#to_install[@]} > 0 )); then
        log_info "Installing missing dependencies: ${to_install[*]}"
        # Using an array correctly quotes each element.
        if sudo pacman -S --needed "${to_install[@]}"; then
            log_info "Dependencies installed successfully."
        else
            log_error "Failed to install dependencies via pacman."
            log_error "Note: 'songrec' is an AUR package. Try 'yay -S songrec' or 'paru -S songrec'."
            return 1
        fi
    fi
    return 0
}

# -----------------------------------------------------------------------------
# 1. Singleton Lock (Atomic using flock)
# -----------------------------------------------------------------------------
acquire_lock() {
    # Open a file descriptor on the lock file.
    # This is atomic and survives the lifetime of the script.
    exec 200>"$LOCK_FILE"

    if ! flock -n 200; then
        # Another instance holds the lock. Exit silently.
        exit 0
    fi

    # Lock acquired. Write PID for debugging purposes.
    printf '%d\n' "$$" >&200
}

# -----------------------------------------------------------------------------
# 2. Setup & Cleanup Trap
# -----------------------------------------------------------------------------
setup_environment() {
    # Use mktemp for a secure, unpredictable temporary directory.
    TMP_DIR=$(mktemp -d "/tmp/hypr_songrec.XXXXXX")
    RAW_FILE="${TMP_DIR}/recording.raw"
    MP3_FILE="${TMP_DIR}/recording.mp3"
}

cleanup() {
    # Capture exit code immediately.
    local exit_code=$?

    # Disable errexit to ensure all cleanup commands run.
    set +e

    # Kill the recording process if it's running.
    # Using ${VAR:-} syntax to handle unset variables safely with `set -u`.
    if [[ -n "${REC_PID:-}" ]] && kill -0 "$REC_PID" 2>/dev/null; then
        kill "$REC_PID" 2>/dev/null
        wait "$REC_PID" 2>/dev/null
    fi

    # Remove the temporary directory.
    [[ -d "${TMP_DIR:-}" ]] && rm -rf "$TMP_DIR"

    # The flock on fd 200 is released automatically on exit.
    # We still clean up the lock file itself.
    rm -f "$LOCK_FILE"

    exit "$exit_code"
}

# -----------------------------------------------------------------------------
# 3. Audio Detection Functions
# -----------------------------------------------------------------------------
get_monitor_source() {
    local default_sink

    if ! default_sink=$(pactl get-default-sink 2>/dev/null) || [[ -z "$default_sink" ]]; then
        die "Failed to get default audio sink from pactl."
    fi

    printf '%s.monitor' "$default_sink"
}

start_recording() {
    local monitor_source="$1"

    parec -d "$monitor_source" --format=s16le --rate=44100 --channels=2 > "$RAW_FILE" 2>/dev/null &
    REC_PID=$!

    # A short sleep to allow parec to fail fast if the source is invalid.
    sleep 0.2
    if ! kill -0 "$REC_PID" 2>/dev/null; then
        die "Failed to start audio recording with parec on source '$monitor_source'."
    fi
}

convert_to_mp3() {
    # Only attempt conversion if the raw file has data.
    if [[ ! -s "$RAW_FILE" ]]; then
        return 1
    fi

    ffmpeg -f s16le -ar 44100 -ac 2 -i "$RAW_FILE" \
        -vn -acodec libmp3lame -q:a 2 -y -loglevel error "$MP3_FILE" 2>/dev/null
}

recognize_song() {
    local json

    if ! json=$(songrec audio-file-to-recognized-song "$MP3_FILE" 2>/dev/null); then
        return 1
    fi

    [[ -z "$json" ]] && return 1

    # Combine validation and parsing into a single jq call.
    # `jq -e` will return a non-zero exit code if .track is null.
    # We output title and artist as tab-separated values.
    local parsed
    if ! parsed=$(printf '%s' "$json" | jq -re '.track | [.title, .subtitle] | @tsv' 2>/dev/null); then
        return 1
    fi

    local title artist
    IFS=$'\t' read -r title artist <<< "$parsed"

    # If title is empty, it's not a valid match.
    [[ -z "$title" ]] && return 1

    # --- Success ---
    notify-send -u normal -t 10000 \
        -h string:x-canonical-private-synchronous:songrec \
        "Song Detected" "<b>${title}</b>\n${artist}"

    printf 'Found: %s by %s\n' "$title" "$artist"
    return 0
}

# -----------------------------------------------------------------------------
# 4. Main Recognition Loop
# -----------------------------------------------------------------------------
recognition_loop() {
    # Using the Bash 5.0+ built-in $EPOCHSECONDS instead of $(date +%s)
    local start_time=$EPOCHSECONDS

    while true; do
        sleep "$INTERVAL"

        local elapsed=$(( EPOCHSECONDS - start_time ))

        if (( elapsed >= TIMEOUT_SECS )); then
            notify-send -u low -t 3000 \
                -h string:x-canonical-private-synchronous:songrec \
                "SongRec" "No match found."
            return 1
        fi

        # Attempt to convert and recognize. Failures are expected and handled.
        # The `if` block prevents `set -e` from triggering on these failures.
        if convert_to_mp3 && recognize_song; then
            return 0
        fi
    done
}

# -----------------------------------------------------------------------------
# Main Entry Point
# -----------------------------------------------------------------------------
main() {
    install_dependencies || exit 1
    acquire_lock

    setup_environment
    trap cleanup EXIT HUP INT TERM

    local monitor_source
    monitor_source=$(get_monitor_source)

    notify-send -u low -t 3000 \
        -h string:x-canonical-private-synchronous:songrec \
        "SongRec" "Listening..."

    start_recording "$monitor_source"
    recognition_loop
}

main "$@"
