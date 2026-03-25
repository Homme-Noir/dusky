#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# MODULE: PACSTRAP (VERIFIED HARDWARE & FIXED REGEX)
# AUTHOR: Elite DevOps Setup
# -----------------------------------------------------------------------------
set -euo pipefail

# --- Colors ---
if [[ -t 1 ]]; then
    readonly C_BOLD=$'\033[1m'
    readonly C_GREEN=$'\033[32m'
    readonly C_YELLOW=$'\033[33m'
    readonly C_RED=$'\033[31m'
    readonly C_RESET=$'\033[0m'
else
    readonly C_BOLD="" C_GREEN="" C_YELLOW="" C_RED="" C_RESET=""
fi

# --- Configuration ---
readonly MOUNT_POINT="/mnt"
USE_GENERIC_FIRMWARE=0
LSPCI_CACHE=""

# Base packages every system needs
FINAL_PACKAGES=(
    base base-devel linux linux-headers
    neovim btrfs-progs dosfstools git
    networkmanager yazi
)

# --- Logging Helpers ---
log_info() { echo -e "${C_GREEN}[INFO]${C_RESET} $*"; }
log_warn() { echo -e "${C_YELLOW}[WARN]${C_RESET} $*"; }
log_err()  { echo -e "${C_RED}[ERROR]${C_RESET} $*"; }

# --- Helper: Check if package exists in Arch Repos ---
package_exists() {
    pacman -Si "$1" &>/dev/null
}

# --- Helper: Cached lspci output ---
get_lspci_cache() {
    if [[ -z "$LSPCI_CACHE" ]]; then
        LSPCI_CACHE=$(lspci -mm 2>/dev/null) || LSPCI_CACHE=""
    fi
    printf '%s\n' "$LSPCI_CACHE"
}

# --- Helper: Detect Hardware & Add Package ---
detect_and_add() {
    local name="$1"
    local pattern="$2"
    local pkg="$3"

    # Skip if already fell back to generic
    ((USE_GENERIC_FIRMWARE)) && return 0

    echo -ne "   > Scanning for ${name}... "

    if get_lspci_cache | grep -iEq "$pattern"; then
        echo -e "${C_GREEN}FOUND${C_RESET}"

        if package_exists "$pkg"; then
            echo -e "     -> Queuing Verified Package: ${C_BOLD}${pkg}${C_RESET}"
            FINAL_PACKAGES+=("$pkg")
        else
            echo -e "     -> ${C_YELLOW}Hardware found, but package '$pkg' missing in repo.${C_RESET}"
            echo -e "     -> Switching to Safe Mode (Generic Firmware)."
            USE_GENERIC_FIRMWARE=1
        fi
    else
        echo "NO"
    fi
}

# ==============================================================================
# 1. SAFETY PRE-FLIGHT CHECKS
# ==============================================================================
echo -e "${C_BOLD}=== PACSTRAP: HARDWARE-VERIFIED EDITION ===${C_RESET}"

# Check Root
if ((EUID != 0)); then
    log_err "This script must be run as root."
    exit 1
fi

# Check Mount
if ! mountpoint -q "$MOUNT_POINT"; then
    log_err "$MOUNT_POINT is not a mountpoint. Mount your partitions first."
    exit 1
fi

# Check Network (WITH TIMEOUT - fixes the hang!)
echo -ne "[....] Checking network connectivity..."
if ! ping -c 1 -W 3 archlinux.org &>/dev/null; then
    echo -e "\r[${C_RED}FAIL${C_RESET}] Checking network connectivity"
    log_err "No internet connection. Cannot install packages."
    exit 1
fi
echo -e "\r[${C_GREEN} OK ${C_RESET}] Checking network connectivity"

# Sync DB (Crucial for package_exists check)
log_info "Syncing package databases..."
pacman -Sy --noconfirm &>/dev/null

# ==============================================================================
# 2. CPU MICROCODE
# ==============================================================================
CPU_VENDOR=$(awk -F': ' '/^vendor_id/{print $2; exit}' /proc/cpuinfo)

case "$CPU_VENDOR" in
    GenuineIntel)
        log_info "CPU: Intel Detected"
        FINAL_PACKAGES+=("intel-ucode")
        detect_and_add "Intel Chipset/WiFi" "intel" "linux-firmware-intel"
        ;;
    AuthenticAMD)
        log_info "CPU: AMD Detected"
        FINAL_PACKAGES+=("amd-ucode")
        ;;
    *)
        log_warn "Unknown CPU Vendor ($CPU_VENDOR). VM Environment?"
        ;;
esac

# ==============================================================================
# 3. PERIPHERAL DETECTION
# ==============================================================================
log_info "Scanning PCI Bus..."

# Ensure lspci is available
if ! command -v lspci &>/dev/null; then
    log_warn "'lspci' not found. Installing pciutils temporarily..."
    pacman -S --noconfirm pciutils &>/dev/null
fi

# Prime the cache
get_lspci_cache >/dev/null

# -- GRAPHICS --
detect_and_add "Nvidia GPU"        "nvidia"                 "linux-firmware-nvidia"
detect_and_add "AMD GPU (Modern)"  "amdgpu|navi|rdna"       "linux-firmware-amdgpu"
detect_and_add "AMD GPU (Legacy)"  "\b(radeon|ati)\b"       "linux-firmware-radeon"

# -- NETWORKING --
detect_and_add "Mediatek WiFi/BT"  "mediatek"               "linux-firmware-mediatek"
detect_and_add "Broadcom WiFi"     "broadcom"               "linux-firmware-broadcom"
detect_and_add "Atheros WiFi"      "atheros"                "linux-firmware-atheros"
detect_and_add "Realtek Eth/WiFi"  "realtek|\brtl"          "linux-firmware-realtek"

# ==============================================================================
# 4. FINAL PACKAGE ASSEMBLY
# ==============================================================================
if ((USE_GENERIC_FIRMWARE)); then
    log_warn "Fallback Triggered: Installing generic linux-firmware."

    # Filter out specific firmware packages
    CLEAN_LIST=()
    for pkg in "${FINAL_PACKAGES[@]}"; do
        [[ "$pkg" == linux-firmware-* ]] || CLEAN_LIST+=("$pkg")
    done
    FINAL_PACKAGES=("${CLEAN_LIST[@]}" "linux-firmware")
else
    # Add the license file required by split packages
    FINAL_PACKAGES+=("linux-firmware-whence")
fi

# ==============================================================================
# 5. EXECUTION
# ==============================================================================
echo ""
echo -e "${C_BOLD}Final Package List:${C_RESET}"
printf '%s\n' "${FINAL_PACKAGES[@]}"
echo ""

read -r -p "Ready to run pacstrap? [Y/n] " confirm
if [[ ! "${confirm,,}" =~ ^(y|yes|)$ ]]; then
    log_warn "Aborted by user."
    exit 0
fi

echo "Installing..."
pacstrap -K "$MOUNT_POINT" "${FINAL_PACKAGES[@]}" --needed

echo -e "\n${C_GREEN}Pacstrap Complete.${C_RESET}"
