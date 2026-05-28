#!/usr/bin/env bash
# ==============================================================================
# Script: 151_systemd_bootloader.sh
# Description: Automated, dynamically-mapped systemd-boot configuration.
# Architecture: UEFI -> systemd-boot -> LUKS2 (sd-encrypt) -> BTRFS -> Plymouth
# Standard: systemd v260+ (UAPI.1 Boot Loader Specification)
# ==============================================================================

set -euo pipefail
export LC_ALL=C

# --- Visuals ---
readonly C_BOLD=$'\033[1m'
readonly C_RESET=$'\033[0m'
readonly C_BLUE=$'\033[1;34m'
readonly C_GREEN=$'\033[1;32m'
readonly C_YELLOW=$'\033[1;33m'
readonly C_RED=$'\033[1;31m'

log_info()    { printf "${C_BLUE}[INFO]${C_RESET} %s\n" "$*"; }
log_success() { printf "${C_GREEN}[OK]${C_RESET} %s\n" "$*"; }
log_warn()    { printf "${C_YELLOW}[WARN]${C_RESET} %s\n" "$*" >&2; }
log_error()   { printf "${C_RED}[ERROR]${C_RESET} %s\n" "$*" >&2; }

cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_error "Script failed at line ${BASH_LINENO[0]} (Exit Code: $exit_code)."
    fi
}
trap cleanup EXIT

# ==============================================================================
# 1. Environment & Pre-Flight Checks
# ==============================================================================

if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root within the arch-chroot."
    exit 1
fi

if [[ ! -d /sys/firmware/efi/efivars ]]; then
    log_error "No UEFI variables found. systemd-boot strictly requires UEFI mode."
    exit 1
fi

# Ensure systemd-boot is managing the correct ESP (Arch default is /boot)
ESP_MNT="/boot"
if ! mountpoint -q "$ESP_MNT"; then
    log_error "$ESP_MNT is NOT a mountpoint. Ensure your FAT32 ESP is mounted."
    exit 1
fi

ESP_FSTYPE=$(findmnt -n -o FSTYPE "$ESP_MNT" 2>/dev/null || true)
if [[ ! "$ESP_FSTYPE" =~ ^(vfat|fat32)$ ]]; then
    log_error "$ESP_MNT is formatted as $ESP_FSTYPE, but systemd-boot requires FAT32."
    exit 1
fi

log_info "Ensuring necessary bootloader packages..."
pacman -S --needed --noconfirm efibootmgr gawk >/dev/null

# ==============================================================================
# 2. Dynamic Topology Traversal (LUKS + BTRFS)
# ==============================================================================

log_info "Analyzing filesystem topology..."

# 2a. Determine Root Filesystem
RAW_ROOT_MNT=$(findmnt -n -e -o SOURCE -T /)
ROOT_BLK_DEV="${RAW_ROOT_MNT%%\[*}"
ROOT_UUID=$(findmnt -n -e -o UUID -T / || true)

if [[ -z "$ROOT_UUID" || "$ROOT_UUID" == "-" ]]; then
    ROOT_UUID=$(blkid -s UUID -o value "$ROOT_BLK_DEV")
fi
[[ -z "$ROOT_UUID" ]] && { log_error "Could not resolve root BTRFS UUID."; exit 1; }

# 2b. Determine BTRFS Subvolume (Native Bash Regex - 100% reliable)
ROOT_OPTS=$(findmnt -n -e -o OPTIONS -T /)
ROOT_SUBVOL=""
if [[ "$ROOT_OPTS" =~ subvol=([^,]+) ]]; then
    ROOT_SUBVOL="${BASH_REMATCH[1]}"
fi

# 2c. Evaluate Effective Mkinitcpio Hooks (Strict Subshell Evaluation)
HOOKS_STR=$(env -i bash -c '
    source /etc/mkinitcpio.conf >/dev/null 2>&1 || true
    shopt -s nullglob
    for conf in /etc/mkinitcpio.conf.d/*.conf; do
        source "$conf" >/dev/null 2>&1 || true
    done
    echo "${HOOKS[*]:-}"
')

# 2d. Trace LUKS Ancestor & Configure Core Command Line
CRYPT_DEV=$(lsblk -nrspo PATH,TYPE -s -- "$ROOT_BLK_DEV" | awk '$2 == "crypt" { print $1; exit }')
CMDLINE_BASE="rw rootfstype=btrfs"

if [[ -n "$CRYPT_DEV" ]]; then
    log_info "LUKS2 Encryption detected on root device."
    MAPPER_NAME="${CRYPT_DEV##*/}"
    BACKING_DEV=$(cryptsetup status "$MAPPER_NAME" | awk '/^[[:space:]]*device:/ { print $2; exit }')
    [[ -z "$BACKING_DEV" ]] && { log_error "Could not determine backing device for $MAPPER_NAME."; exit 1; }
    
    LUKS_UUID=$(blkid -s UUID -o value "$BACKING_DEV")
    [[ -z "$LUKS_UUID" ]] && { log_error "Could not determine LUKS UUID for $BACKING_DEV."; exit 1; }

    # Map parameters based strictly on active hook configuration
    if [[ " $HOOKS_STR " == *" sd-encrypt "* ]]; then
        log_info "Systemd encryption hook (sd-encrypt) detected."
        CMDLINE_BASE="rd.luks.name=${LUKS_UUID}=${MAPPER_NAME} rd.luks.options=discard root=UUID=${ROOT_UUID} ${CMDLINE_BASE}"
    elif [[ " $HOOKS_STR " == *" encrypt "* ]]; then
        log_info "Legacy encryption hook (encrypt) detected."
        CMDLINE_BASE="cryptdevice=UUID=${LUKS_UUID}:${MAPPER_NAME}:allow-discards root=/dev/mapper/${MAPPER_NAME} ${CMDLINE_BASE}"
    else
        log_error "LUKS detected, but neither 'sd-encrypt' nor 'encrypt' hook found in mkinitcpio configs."
        exit 1
    fi
else
    log_info "No LUKS layer detected. Configuring for plain BTRFS."
    CMDLINE_BASE="root=UUID=${ROOT_UUID} ${CMDLINE_BASE}"
fi

# 2e. Append Subvolume Parameter
if [[ -n "$ROOT_SUBVOL" ]]; then
    CMDLINE_BASE="${CMDLINE_BASE} rootflags=subvol=${ROOT_SUBVOL}"
fi

log_success "Topology mapped securely. Base kernel command line established."

# ==============================================================================
# 3. Systemd-Boot Installation & Entropy Seeding
# ==============================================================================

log_info "Deploying systemd-boot to $ESP_MNT..."

# Explicitly use --variables=yes to override the default container/chroot block in systemd 258+
if bootctl is-installed --esp-path="$ESP_MNT" >/dev/null 2>&1; then
    log_info "Existing systemd-boot detected. Performing update..."
    bootctl update --esp-path="$ESP_MNT" --variables=yes
else
    log_info "Performing fresh systemd-boot installation..."
    if ! bootctl install --esp-path="$ESP_MNT" --variables=yes; then
        log_warn "Installation returned non-zero (common on restricted firmware). Verifying deployment..."
        if ! bootctl is-installed --esp-path="$ESP_MNT" >/dev/null 2>&1; then
             log_error "bootctl installation failed completely."
             exit 1
        fi
    fi
fi

# Systemd 243+ Security standard: Initialize Early-Boot Random Seed in ESP
log_info "Initializing cryptographic random seed for early-boot entropy..."
bootctl random-seed --esp-path="$ESP_MNT" --variables=yes || log_warn "Could not store EFI system token (normal on locked firmware)."

log_success "systemd-boot binaries deployed and random seed generated."

# Configure the main loader (default @saved enables pressing 'd' in menu to lock a default kernel)
LOADER_CONF="$ESP_MNT/loader/loader.conf"
cat > "$LOADER_CONF" <<EOF
default  @saved
timeout  2
console-mode max
editor   no
EOF

# ==============================================================================
# 4. UAPI.1 Boot Loader Specification Entry Generation
# ==============================================================================

log_info "Scanning for installed kernels and microcode..."

shopt -s nullglob
KERNELS=("$ESP_MNT"/vmlinuz-*)
UCODES=("$ESP_MNT"/*-ucode.img)
shopt -u nullglob

if (( ${#KERNELS[@]} == 0 )); then
    log_error "No kernels found in $ESP_MNT. Did pacstrap complete successfully?"
    exit 1
fi

# Ensure the BLS entries directory exists
mkdir -p "$ESP_MNT/loader/entries"

# Define Plymouth specific parameters
PLYMOUTH_ARGS="quiet splash loglevel=3 rd.udev.log_level=3 vt.global_cursor_default=0 nowatchdog"

for kernel_path in "${KERNELS[@]}"; do
    # Pure native bash string manipulation (avoids spawning `sed` subprocesses)
    kbase="${kernel_path##*/}"
    KNAME="${kbase#vmlinuz-}"
    
    ENTRY_FILE="$ESP_MNT/loader/entries/arch-${KNAME}.conf"
    FALLBACK_FILE="$ESP_MNT/loader/entries/arch-${KNAME}-fallback.conf"
    
    log_info "Generating BLS Type #1 entries for: Arch Linux ($KNAME)"

    # --- Primary Entry (With Plymouth Graphical Splash) ---
    {
        printf "title   Arch Linux (%s)\n" "$KNAME"
        printf "linux   /%s\n" "$kbase"
        
        # Microcode must precede the initramfs in systemd-boot configs
        for ucode in "${UCODES[@]}"; do
            printf "initrd  /%s\n" "${ucode##*/}"
        done
        
        printf "initrd  /initramfs-%s.img\n" "$KNAME"
        printf "options %s %s\n" "$CMDLINE_BASE" "$PLYMOUTH_ARGS"
    } > "$ENTRY_FILE"

    # --- Fallback Entry (Recovery Mode, No Splash) ---
    if [[ -f "$ESP_MNT/initramfs-${KNAME}-fallback.img" ]]; then
        {
            printf "title   Arch Linux (%s - Fallback Recovery)\n" "$KNAME"
            printf "linux   /%s\n" "$kbase"
            
            for ucode in "${UCODES[@]}"; do
                printf "initrd  /%s\n" "${ucode##*/}"
            done
            
            printf "initrd  /initramfs-%s-fallback.img\n" "$KNAME"
            # Exclude PLYMOUTH_ARGS to ensure terminal output is completely visible during a kernel panic
            printf "options %s\n" "$CMDLINE_BASE"
        } > "$FALLBACK_FILE"
    fi
done

# ==============================================================================
# 5. Lifecycle Hooks
# ==============================================================================

log_info "Enabling systemd-boot-update.service (Auto-updates bootloader)..."
systemctl enable systemd-boot-update.service >/dev/null 2>&1 || true

log_success "Systemd-Boot orchestration complete. Your system is ready to boot."
