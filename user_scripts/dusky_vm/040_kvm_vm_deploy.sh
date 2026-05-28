#!/usr/bin/env bash
# ==============================================================================
# 040_kvm_vm_deploy.sh
# Purpose: Dynamic KVM XML architect. Builds a perfectly optimized hardware 
#          topology depending on OS type, TPM requirements, and GPU logic.
# ==============================================================================
set -euo pipefail

CYAN='\033[1;36m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m'

log_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# --- Sudo Validation & Keep-Alive ---
log_info "Validating administrative privileges..."
sudo -v || log_error "Sudo authentication failed."
while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &

echo -e "${CYAN}====================================================${NC}"
echo -e "${CYAN}          Intelligent VM Provisioning Engine        ${NC}"
echo -e "${CYAN}====================================================${NC}"

# 1. Retrieve Storage Environment
if [ -f /tmp/kvm_storage_env ]; then
    source /tmp/kvm_storage_env
else
    log_warn "Storage environment file not found. Defaulting to /var/lib/libvirt/images"
    KVM_TARGET_DIR="/var/lib/libvirt/images"
fi

# 2. Collect VM Specifications
read -rp "Enter Virtual Machine Name (e.g., archlinux, win11): " VM_NAME
VM_NAME=${VM_NAME:-archlinux}

echo -e "\nSelect Operating System:"
echo "  [1] Arch Linux (Bleeding Edge)"
echo "  [2] Windows 10 / 11 (Includes TPM 2.0 & Hyper-V Enlightenments)"
read -rp "Choice [1-2] (Default 1): " OS_CHOICE
OS_CHOICE=${OS_CHOICE:-1}

echo -e "\nSelect Graphics / GPU Topology:"
echo "  [1] Basic / Simple (Standard QXL or Virtio 2D)"
echo "  [2] GPU Acceleration (Virtio 3D with Virgil / OpenGL)"
echo "  [3] GPU Passthrough (VFIO Isolation + Looking Glass Shmem)"
read -rp "Choice [1-3] (Default 1): " GPU_CHOICE
GPU_CHOICE=${GPU_CHOICE:-1}

read -rp "Enter RAM size in GiB (Default 8): " RAM_GIB
RAM_GIB=${RAM_GIB:-8}
RAM_KIB=$((RAM_GIB * 1024 * 1024))

read -rp "Enter vCPU Core Count (Default 6): " VCPU_COUNT
VCPU_COUNT=${VCPU_COUNT:-6}

read -rp "Enter Disk Size in GiB (Default 50): " DISK_GIB
DISK_GIB=${DISK_GIB:-50}

VM_UUID=$(uuidgen)
MAC_ADDR=$(printf '52:54:00:%02x:%02x:%02x' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))

# 3. Dynamic XML Module Generation
FEATURES_XML="<acpi/><apic/><vmport state='off'/>"
TPM_XML=""
CDROM_XML="
    <disk type='file' device='cdrom'>
      <target dev='sda' bus='sata'/>
      <readonly/>
    </disk>"

if [ "$OS_CHOICE" == "2" ]; then
    FEATURES_XML="
    <acpi/><apic/><vmport state='off'/>
    <hyperv>
      <relaxed state='on'/>
      <vapic state='on'/>
      <spinlocks state='on' retries='8191'/>
      <vpindex state='on'/>
      <runtime state='on'/>
      <synic state='on'/>
      <stimer state='on'/>
      <frequencies state='on'/>
      <tlbflush state='on'/>
      <ipi state='on'/>
      <evmcs state='on'/>
      <avic state='on'/>
    </hyperv>"
    
    TPM_XML="
    <tpm model='tpm-crb'>
      <backend type='emulator' version='2.0'/>
    </tpm>"

    CDROM_XML="
    <disk type='file' device='cdrom'>
      <target dev='sda' bus='sata'/>
      <readonly/>
    </disk>
    <disk type='file' device='cdrom'>
      <target dev='sdb' bus='sata'/>
      <readonly/>
    </disk>"
fi

GRAPHICS_XML=""
case $GPU_CHOICE in
    1) # Basic
        GRAPHICS_XML="
        <graphics type='spice' port='-1' autoport='yes'>
          <image compression='off'/>
        </graphics>
        <video><model type='virtio'/></video>"
        ;;
    2) # Acceleration (Virtio 3D)
        GRAPHICS_XML="
        <graphics type='spice'>
          <listen type='none'/>
          <image compression='off'/>
          <gl enable='yes' rendernode='/dev/dri/renderD128'/>
        </graphics>
        <video>
          <model type='virtio' heads='1' primary='yes'>
            <acceleration accel3d='yes'/>
          </model>
        </video>"
        ;;
    3) # VFIO Passthrough
        echo -e "\n${YELLOW}GPU Passthrough Configuration${NC}"
        log_info "Run 'lspci' in another terminal if you don't know your bus IDs."
        log_info "Assuming Video is function 0x0 and Audio is function 0x1."
        read -rp "Enter the PCI Bus ID of the GPU (e.g., '01'): " PCI_BUS
        read -rp "Enter the PCI Slot ID of the GPU (e.g., '00'): " PCI_SLOT
        
        GRAPHICS_XML="
        <video><model type='none'/></video>
        <hostdev mode='subsystem' type='pci' managed='yes'>
          <source><address domain='0x0000' bus='0x${PCI_BUS}' slot='0x${PCI_SLOT}' function='0x0'/></source>
        </hostdev>
        <hostdev mode='subsystem' type='pci' managed='yes'>
          <source><address domain='0x0000' bus='0x${PCI_BUS}' slot='0x${PCI_SLOT}' function='0x1'/></source>
        </hostdev>
        <shmem name='looking-glass'>
          <model type='ivshmem-plain'/>
          <size unit='M'>32</size>
        </shmem>"
        ;;
esac

# 4. Provision Disk Image
DISK_PATH="${KVM_TARGET_DIR}/${VM_NAME}.qcow2"
log_info "Provisioning virtual disk at: $DISK_PATH"
sudo qemu-img create -f qcow2 "$DISK_PATH" "${DISK_GIB}G" > /dev/null
# CRITICAL FIX: Ensure qemu daemon user can actually read/write the newly created disk
sudo chown qemu:qemu "$DISK_PATH" || true

# 5. Assemble Master XML
XML_PAYLOAD="/tmp/${VM_NAME}_deploy.xml"
log_info "Assembling dynamic XML payload..."

cat <<EOF > "$XML_PAYLOAD"
<domain type="kvm">
  <name>${VM_NAME}</name>
  <uuid>${VM_UUID}</uuid>
  <memory unit="KiB">${RAM_KIB}</memory>
  <currentMemory unit="KiB">${RAM_KIB}</currentMemory>
  <memoryBacking>
    <source type="memfd"/>
    <access mode="shared"/>
  </memoryBacking>
  <vcpu placement="static">${VCPU_COUNT}</vcpu>
  <os firmware="efi">
    <type arch="x86_64" machine="q35">hvm</type>
    <boot dev="hd"/>
    <boot dev="cdrom"/>
  </os>
  <features>
    ${FEATURES_XML}
  </features>
  <cpu mode="host-passthrough" check="none" migratable="on"/>
  <clock offset="$( [ "$OS_CHOICE" == "2" ] && echo "localtime" || echo "utc" )">
    <timer name="rtc" tickpolicy="catchup"/>
    <timer name="pit" tickpolicy="delay"/>
    <timer name="hpet" present="no"/>
    $( [ "$OS_CHOICE" == "2" ] && echo '<timer name="hypervclock" present="yes"/>' )
  </clock>
  <pm>
    <suspend-to-mem enabled="no"/>
    <suspend-to-disk enabled="no"/>
  </pm>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <disk type="file" device="disk">
      <driver name="qemu" type="qcow2" cache="none" discard="unmap"/>
      <source file="${DISK_PATH}"/>
      <target dev="vda" bus="virtio"/>
    </disk>
    ${CDROM_XML}
    <controller type="usb" model="qemu-xhci" ports="15"/>
    <controller type="pci" model="pcie-root"/>
    <interface type="bridge">
      <mac address="${MAC_ADDR}"/>
      <source bridge="virbr0"/>
      <model type="virtio"/>
    </interface>
    <channel type="unix">
      <target type="virtio" name="org.qemu.guest_agent.0"/>
    </channel>
    <channel type="spicevmc">
      <target type="virtio" name="com.redhat.spice.0"/>
    </channel>
    <input type="tablet" bus="usb"/>
    <input type="mouse" bus="ps2"/>
    <input type="keyboard" bus="ps2"/>
    <sound model="ich9"/>
    <rng model="virtio">
      <backend model="random">/dev/urandom</backend>
    </rng>
    ${TPM_XML}
    ${GRAPHICS_XML}
  </devices>
</domain>
EOF

# 6. Define in libvirt
log_info "Defining VM in libvirt from generated payload..."
sudo virsh -c qemu:///system define "$XML_PAYLOAD"

# Cleanup
rm "$XML_PAYLOAD"

log_success "Virtual Machine '${VM_NAME}' successfully configured and imported!"
if [ "$OS_CHOICE" == "2" ]; then
    echo -e "${YELLOW}Note: Open Virt-Manager, attach your Windows ISO to SATA CDROM 1, and the virtio-win.iso to SATA CDROM 2.${NC}"
else
    echo -e "${YELLOW}Note: Open Virt-Manager, attach your Linux ISO to the SATA CDROM, and begin OS installation.${NC}"
fi
