#!/usr/bin/env bash
# ==============================================================================
# build_dusky_iso.sh - THE MASTER FACTORY ISO GENERATOR (Combined)
# Description: Orchestrates ZRAM setup, dotfile injection, and offline ISO build.
# Payload: Overrides GitHub dotfiles with local, secure assets.
# ==============================================================================
set -euo pipefail

# Enforce strict POSIX locale for predictable parsing
export LC_ALL=C
export LANG=C

# --- 1. PRIVILEGE ESCALATION & PATH RESOLUTION ---
if (( EUID != 0 )); then
    echo "[INFO] Root privileges required. Auto-elevating..."
    exec sudo "$0" "$@"
fi

# Securely resolve the original user's home directory even under sudo
if [[ -n "${SUDO_USER:-}" ]]; then
    REAL_HOME=$(getent passwd "${SUDO_USER}" | cut -d: -f6)
else
    REAL_HOME="${HOME}"
fi

# --- 2. CONFIGURATION & CONSTANTS ---
readonly FINAL_DEST_DIR="/mnt/zram1"
readonly SOURCE_DIR="${REAL_HOME}/user_scripts/arch_iso_scripts/offline_iso"
readonly WORKSPACE="${FINAL_DEST_DIR}/dusky_iso"
readonly PROFILE_DIR="${WORKSPACE}/profile"
readonly WORK_DIR="${WORKSPACE}/work"
readonly OUT_DIR="${WORKSPACE}/out"

# Repo Merge Paths
readonly OFFLINE_REPO_BASE="/srv/offline-repo"
readonly OFFLINE_REPO_OFFICIAL="${OFFLINE_REPO_BASE}/official"
readonly OFFLINE_REPO_AUR="${OFFLINE_REPO_BASE}/aur"

readonly MKARCHISO_CUSTOM="${WORKSPACE}/mkarchiso_dusky"
readonly PATCH_FILE="${WORKSPACE}/repo_inject.patch"
readonly FINAL_ISO_NAME="dusky_$(date +%m_%y).iso"

echo -e "\n\e[1;34m==>\e[0m \e[1mINITIATING DUSKY ARCH ISO FACTORY BUILD\e[0m\n"

# --- 3. PRE-FLIGHT FORENSICS ---
if [[ -z "${WORKSPACE}" || "${WORKSPACE}" == "/" ]]; then
    echo "[!] FATAL: Workspace variable is unsafe (${WORKSPACE}). Aborting."
    exit 1
fi

if [[ ! -d "${OFFLINE_REPO_OFFICIAL}" || ! -d "${OFFLINE_REPO_AUR}" ]]; then
    echo "[!] FATAL: Offline repository directories missing at ${OFFLINE_REPO_BASE}."
    exit 1
fi

# Visual confirmation of payload integrity (Restored from 022_prep)
echo "      Official directory object count: $(ls -lah "${OFFLINE_REPO_OFFICIAL}/" | wc -l)"
echo "      AUR directory object count:      $(ls -lah "${OFFLINE_REPO_AUR}/" | wc -l)"

# Strict dependency checks (Restored from 030_build_iso)
if ! command -v git &>/dev/null; then
    echo "[ERR] git is required but not installed." >&2
    exit 1
fi

if ! grep -q '^_build_iso_image() {' /usr/bin/mkarchiso; then
    echo "[!] FATAL: Could not locate '_build_iso_image() {' in /usr/bin/mkarchiso."
    exit 1
fi

# --- 4. ZRAM CLEAN ROOM & ARCHISO SETUP ---
echo "  -> Enforcing archiso dependency..."
pacman -S --needed --noconfirm archiso >/dev/null

if [[ -d "${WORKSPACE}" ]]; then
    echo "  -> Purging existing workspace at ${WORKSPACE} for idempotency..."
    rm -rf "${WORKSPACE}"
fi

echo "  -> Forcefully deleting previously built ISOs from ${FINAL_DEST_DIR} to free RAM..."
rm -f "${FINAL_DEST_DIR}/dusky_"*.iso

mkdir -p "${WORKSPACE}"

echo "  -> Cloning 'releng' blueprint..."
cp -a /usr/share/archiso/configs/releng "${PROFILE_DIR}"

# --- 5. STAGING ORCHESTRATION PAYLOADS ---
echo "  -> Injecting airootfs staging directory and scripts..."
mkdir -p "${PROFILE_DIR}/airootfs/root/arch_install"

shopt -s dotglob nullglob
cp -a "${SOURCE_DIR}/"* "${PROFILE_DIR}/airootfs/root/arch_install/"
shopt -u dotglob nullglob

echo "  -> Injecting predefined packages.x86_64 asset..."
cp -a "${SOURCE_DIR}/assets/iso_temp_packages/packages.x86_64" "${PROFILE_DIR}/packages.x86_64"

# --- 6. LIVE ENVIRONMENT HOOKS (Auto-Start) ---
echo "  -> Configuring Auto-Start Payload and SSH Access..."
cat << 'EOF' > "${PROFILE_DIR}/airootfs/root/.automated_script.sh"
#!/usr/bin/env bash

if [[ "$(tty)" == "/dev/tty1" ]]; then
    echo "root:0000" | chpasswd
    echo -e "\e[1;32m[INFO]\e[0m Root password set to 0000. SSH is available."

    echo -e "\e[1;34m[INFO]\e[0m Bootstrapping environment..."
    systemctl is-system-running >/dev/null 2>&1 || true

    chmod -R +x /root/arch_install/
    clear
    cd /root/arch_install/
    ./000_dusky_arch_install.sh
fi
EOF
chmod +x "${PROFILE_DIR}/airootfs/root/.automated_script.sh"

# --- 7. SKELETON DIRECTORY (The Dotfile & Hyprland Payload) ---
echo "  -> Preparing pristine workspace for dotfiles..."
SKEL_DIR="${PROFILE_DIR}/airootfs/etc/skel"
rm -rf "${SKEL_DIR}"
mkdir -p "${SKEL_DIR}"

sed -i '/^# --- DUSKY PERMISSIONS START ---/,/^# --- DUSKY PERMISSIONS END ---/d' "${PROFILE_DIR}/profiledef.sh"
sed -i '/^grml-zsh-config$/d' "${PROFILE_DIR}/packages.x86_64" || true

echo "  -> Fetching GitHub dotfiles (Clean Clone Method)..."
# Wipe temp directory to prevent 'already exists' git fatal errors on re-runs
rm -rf "/tmp/dusky_dots" 

for attempt in {1..3}; do
    if git clone --depth 1 "https://github.com/dusklinux/dusky" "/tmp/dusky_dots"; then
        break
    fi
    if (( attempt == 3 )); then echo "[ERR] Git clone failed." >&2; exit 1; fi
    echo "[WARN] Git clone failed. Retrying in 5s..."
    rm -rf "/tmp/dusky_dots" # Clear partial downloads before retrying
    sleep 5
done

echo "  -> Migrating repo into /etc/skel and scrubbing git database..."
cp -a /tmp/dusky_dots/. "${SKEL_DIR}/"
rm -rf "${SKEL_DIR}/.git"
rm -rf "/tmp/dusky_dots"

# ==============================================================================
# THE OVERRIDE: Replacing GitHub hyprland.lua with the local version
# ==============================================================================
echo "  -> Structuring directory and injecting local hyprland.lua override..."
mkdir -p "${SKEL_DIR}/.config/hypr"
cp -a "${SOURCE_DIR}/assets/hyprland/hyprland.lua" "${SKEL_DIR}/.config/hypr/hyprland.lua"
# ==============================================================================

echo "  -> Locking in executable permissions for /etc/skel scripts..."
echo "# --- DUSKY PERMISSIONS START ---" >> "${PROFILE_DIR}/profiledef.sh"
while IFS= read -r -d '' exec_file; do
    rel_path="/${exec_file#${PROFILE_DIR}/airootfs/}"
    echo "file_permissions+=([\"${rel_path}\"]=\"0:0:0755\")" >> "${PROFILE_DIR}/profiledef.sh"
done < <(find "${SKEL_DIR}" -type f -executable -print0)
echo "# --- DUSKY PERMISSIONS END ---" >> "${PROFILE_DIR}/profiledef.sh"

# --- 8. DYNAMIC MKARCHISO PATCHING ---
echo "  -> Mapping offline repositories to pacman.conf..."
awk -v off="${OFFLINE_REPO_OFFICIAL}" -v aur="${OFFLINE_REPO_AUR}" '
/^\[options\]/ { print; print "CacheDir = " off; print "CacheDir = " aur; print "CacheDir = /var/cache/pacman/pkg"; next }
{print}
' "${PROFILE_DIR}/pacman.conf" > "${PROFILE_DIR}/pacman.conf.tmp" && mv "${PROFILE_DIR}/pacman.conf.tmp" "${PROFILE_DIR}/pacman.conf"

echo "  -> Generating injection patch for offline repositories..."
cp /usr/bin/mkarchiso "$MKARCHISO_CUSTOM"
chmod +x "$MKARCHISO_CUSTOM"

cat << EOF > "$PATCH_FILE"
    _msg_info ">>> INJECTING & MERGING REPOSITORIES DIRECTLY INTO ISO <<<"
    local repo_target="\${isofs_dir}/\${install_dir}/repo"
    mkdir -p "\${repo_target}"
    cp -a "${OFFLINE_REPO_OFFICIAL}/." "\${repo_target}/"
    if [[ -d "${OFFLINE_REPO_AUR}" ]]; then cp -a "${OFFLINE_REPO_AUR}/." "\${repo_target}/"; fi
    rm -f "\${repo_target}/archrepo.db"* "\${repo_target}/archrepo.files"*
    
    local _nullglob_state; shopt -q nullglob && _nullglob_state=1 || _nullglob_state=0
    shopt -s nullglob
    local all_files=("\${repo_target}/"*.pkg.tar.*)
    local pkg_files=()
    for f in "\${all_files[@]}"; do [[ "\$f" == *.sig ]] && continue; pkg_files+=("\$f"); done
    (( _nullglob_state )) || shopt -u nullglob
    
    if (( \${#pkg_files[@]} > 0 )); then
        repo-add -q "\${repo_target}/archrepo.db.tar.gz" "\${pkg_files[@]}"
    else
        echo "[ERR] No packages found to merge inside ISO!" >&2; return 1
    fi
EOF

sed -i '/^_build_iso_image() {/r '"$PATCH_FILE"'' "$MKARCHISO_CUSTOM"

if ! grep -q 'INJECTING & MERGING REPOSITORIES DIRECTLY INTO ISO' "$MKARCHISO_CUSTOM"; then
    echo "[ERR] Patch was NOT injected — the sed pattern failed to match." >&2
    exit 1
fi
echo "  -> Patch verified successfully."

rm -f "$PATCH_FILE"

# --- 9. ISO GENERATION ---
echo -e "\n\e[1;32m==>\e[0m \e[1mSTARTING BUILD PROCESS\e[0m"
rm -rf "$WORK_DIR" "$OUT_DIR"
"$MKARCHISO_CUSTOM" -v -m iso -w "$WORK_DIR" -o "$OUT_DIR" "$PROFILE_DIR"

# --- 10. CLEANUP & ARTIFACT RELOCATION ---
echo "  -> Relocating final ISO to root of ZRAM drive (${FINAL_DEST_DIR}/)..."
mv "${OUT_DIR}"/*.iso "${FINAL_DEST_DIR}/${FINAL_ISO_NAME}"

if [[ -n "${SUDO_UID:-}" && -n "${SUDO_GID:-}" ]]; then
    echo "  -> Restoring ownership of the final ISO to original user ID..."
    chown "${SUDO_UID}:${SUDO_GID}" "${FINAL_DEST_DIR}/${FINAL_ISO_NAME}"
fi

echo -e "\n\e[1;32m[SUCCESS]\e[0m \e[1mISO generation complete!\e[0m"
echo "Bootable ISO located at: ${FINAL_DEST_DIR}/${FINAL_ISO_NAME}"
