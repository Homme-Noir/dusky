#!/usr/bin/env bash
# ==============================================================================
# 020_kvm_storage_setup.sh
# Purpose: Interactive VM storage provisioner. Configures exact ACL permissions 
#          to prevent 'qemu' access denial on custom/ephemeral mounts (ZRAM).
# ==============================================================================
set -euo pipefail

CYAN='\033[1;36m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m'

# --- Sudo Validation & Keep-Alive ---
sudo -v || { echo -e "${RED}[ERROR] Sudo authentication failed.${NC}"; exit 1; }
while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &

DEFAULT_PATH="/var/lib/libvirt/images"

echo -e "${CYAN}====================================================${NC}"
echo -e "${CYAN}       Virtual Machine Storage Configuration        ${NC}"
echo -e "${CYAN}====================================================${NC}"
echo -e "Where would you like to store your Virtual Machine drives?"
echo -e "  [1] Persistent Storage (Default: ${DEFAULT_PATH})"
echo -e "  [2] Ephemeral / RAM Disk (e.g., /mnt/zram1 for SSD wear prevention)"
echo -e "  [3] Custom Path"
echo ""

read -rp "Select an option [1-3] (Default: 1): " STORAGE_CHOICE
STORAGE_CHOICE=${STORAGE_CHOICE:-1}

TARGET_DIR=""

case $STORAGE_CHOICE in
    1) TARGET_DIR="$DEFAULT_PATH" ;;
    2)
        read -ep "Enter your ephemeral drive path (Default: /mnt/zram1): " EPHEMERAL_PATH
        TARGET_DIR=${EPHEMERAL_PATH:-/mnt/zram1}
        ;;
    3)
        read -ep "Enter the absolute path to your custom directory: " TARGET_DIR
        if [[ "$TARGET_DIR" != /* ]]; then
            echo -e "${RED}[ERROR] Path must be absolute (start with '/'). Aborting.${NC}"
            exit 1
        fi
        ;;
    *)
        echo -e "${RED}[ERROR] Invalid selection. Aborting.${NC}"
        exit 1
        ;;
esac

if [ ! -d "$TARGET_DIR" ]; then
    echo -e "${YELLOW}[WARN] Directory $TARGET_DIR does not exist. Creating it...${NC}"
    sudo mkdir -p "$TARGET_DIR"
fi

echo -e "${CYAN}[INFO] Target storage directory set to: ${TARGET_DIR}${NC}"

# ACL Configuration for QEMU traverse permissions
if [ "$TARGET_DIR" != "$DEFAULT_PATH" ]; then
    echo -e "${CYAN}[INFO] Custom path detected. Configuring Access Control Lists (ACL) for QEMU...${NC}"
    CURRENT_PATH="$TARGET_DIR"
    while [ "$CURRENT_PATH" != "/" ] && [ "$CURRENT_PATH" != "" ]; do
        sudo setfacl -m u:qemu:x "$CURRENT_PATH" || true
        CURRENT_PATH=$(dirname "$CURRENT_PATH")
    done
    sudo setfacl -m u:qemu:rwx "$TARGET_DIR"
    sudo setfacl -d -m u:qemu:rwx "$TARGET_DIR"
    echo -e "${GREEN}[SUCCESS] ACLs configured successfully for $TARGET_DIR.${NC}"
fi

# Secure cross-script handoff via /tmp
echo "export KVM_TARGET_DIR=\"$TARGET_DIR\"" | sudo tee /tmp/kvm_storage_env > /dev/null
sudo chmod 666 /tmp/kvm_storage_env

echo -e "${GREEN}=== Storage Provisioning Complete ===${NC}"
