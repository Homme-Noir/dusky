#!/usr/bin/env python3
from python.frontend.core_types import ConfigItem

# =============================================================================
# 1. CORE APPLICATION ROUTING
# =============================================================================
ENGINE_TYPE = "cmdline"                       
TARGET_FILE = "/etc/kernel/cmdline"           
APP_TITLE = "Kernel Parameter Editor"         
REQUIRE_ROOT = True                           

# =============================================================================
# 2. UI & ENVIRONMENT BEHAVIOR
# =============================================================================
DEFAULT_MODE = "batch"                        
THEME_FILE = "~/.config/matugen/generated/dusky_tui.json"
ENABLE_USER_PRESETS = False                   

TAB_NOTICES = {
    0: {"level": "info", "message": "Remember to run your bootloader update command (e.g. limine-update) after modifying these parameters."},
}

# =============================================================================
# 3. TABS DEFINITION
# =============================================================================
TABS = [
    "Performance",
    "Hardware",
    "Debug",
    "Misc"
]

# =============================================================================
# 4. SCHEMA DEFINITION
# =============================================================================

SCHEMA = {
    # -------------------------------------------------------------------------
    # TAB 0: PERFORMANCE
    # -------------------------------------------------------------------------
    0: [
        ConfigItem(
            label="Mitigations",
            key="mitigations",
            scope="DEFAULT",
            type_="cycle",
            options=["unset", "auto", "off"],
            default="unset",
            group="CPU",
            extended_help="**CPU Vulnerability Mitigations**\n\nControls optional mitigations for CPU side-channel vulnerabilities (like Spectre and Meltdown).\n\n- `auto`: System default (usually enabled).\n- `off`: Disables all optional CPU mitigations, which can significantly improve system performance at the expense of local security.\n- `unset`: Removes the parameter, relying on the kernel's compile-time defaults."
        ),
        ConfigItem(
            label="Intel P-State",
            key="intel_pstate",
            scope="DEFAULT",
            type_="cycle",
            options=["unset", "disable", "passive", "force"],
            default="unset",
            group="CPU",
            extended_help="**Intel Frequency Scaling**\n\nConfigures the hardware P-State scaling driver for Intel processors.\n\n- `disable`: Disables the active intel_pstate driver and falls back to acpi-cpufreq.\n- `passive`: Uses the passive governor to allow user-space tools more control over frequency.\n- `force`: Forces the driver to be used even on unsupported platforms."
        ),
        ConfigItem(
            label="ZSwap Enabled",
            key="zswap.enabled",
            scope="DEFAULT",
            type_="cycle",
            options=["unset", "0", "1"],
            default="unset",
            group="Memory",
            extended_help="**ZSwap Compression**\n\nZSwap intercepts memory pages that are being swapped out and attempts to compress them into a dynamically sized RAM-based pool.\n\n- `1`: Enables ZSwap, significantly improving responsiveness during heavy memory pressure.\n- `0`: Explicitly disables ZSwap."
        ),
        ConfigItem(
            label="Trans. Hugepages",
            key="transparent_hugepage",
            scope="DEFAULT",
            type_="cycle",
            options=["unset", "always", "madvise", "never"],
            default="unset",
            group="Memory",
            extended_help="**Transparent Hugepages (THP)**\n\nAllows the kernel to dynamically allocate memory in larger block sizes (hugepages) to reduce Translation Lookaside Buffer (TLB) overhead.\n\n- `always`: Enabled globally for all processes.\n- `madvise`: Only enabled for applications that explicitly request it.\n- `never`: Completely disables THP."
        ),
        ConfigItem(
            label="NUMA Balancing",
            key="numa_balancing",
            scope="DEFAULT",
            type_="cycle",
            options=["unset", "enable", "disable"],
            default="unset",
            group="Memory",
            extended_help="**Automatic NUMA Balancing**\n\nOptimizes thread and memory placement on multi-node NUMA architectures (such as dual-socket boards or large Threadripper systems).\n\n- `enable`: Automatically moves memory to the local node of the CPU executing the thread.\n- `disable`: Prevents automatic rebalancing, useful for rigid workload isolation."
        ),
        ConfigItem(
            label="Disable Watchdog",
            key="nowatchdog",
            scope="DEFAULT",
            type_="bool",
            default=False,
            group="Kernel",
            extended_help="**NMI Watchdog**\n\nThe Non-Maskable Interrupt (NMI) watchdog detects hardware hang states.\n\nEnabling this flag (`nowatchdog`) disables the watchdog entirely, which can slightly reduce system interrupts and improve power efficiency on consumer laptops/desktops where kernel panics aren't mission-critical."
        ),
        ConfigItem(
            label="Thread IRQs",
            key="threadirqs",
            scope="DEFAULT",
            type_="bool",
            default=False,
            group="Kernel",
            extended_help="**Threaded Interrupts**\n\nForces hardware interrupt handlers to run inside kernel threads instead of hard IRQ context. This can significantly improve real-time responsiveness and audio latency at the cost of a slight increase in overall overhead."
        ),
    ],

    # -------------------------------------------------------------------------
    # TAB 1: HARDWARE
    # -------------------------------------------------------------------------
    1: [
        ConfigItem(
            label="Intel IOMMU",
            key="intel_iommu",
            scope="DEFAULT",
            type_="cycle",
            options=["unset", "on", "off"],
            default="unset",
            group="IOMMU",
            extended_help="**Intel IOMMU / VT-d**\n\nControls the Intel Input/Output Memory Management Unit.\n\n- `on`: Enables VT-d to allow advanced features like VFIO PCIe Passthrough for virtual machines.\n- `off`: Disables Intel IOMMU."
        ),
        ConfigItem(
            label="AMD IOMMU",
            key="amd_iommu",
            scope="DEFAULT",
            type_="cycle",
            options=["unset", "off", "fullflush", "force_isolation"],
            default="unset",
            group="IOMMU",
            extended_help="**AMD IOMMU / AMD-Vi**\n\nControls the AMD IOMMU implementation.\n\n- `force_isolation`: Forces strict device isolation.\n- `fullflush`: Flushes IOTLB completely on unmap."
        ),
        ConfigItem(
            label="IOMMU Mode",
            key="iommu",
            scope="DEFAULT",
            type_="cycle",
            options=["unset", "pt", "off", "force"],
            default="unset",
            group="IOMMU",
            extended_help="**Generic IOMMU Subsystem**\n\n- `pt`: Passthrough mode. Devices use an identity-mapped translation by default, which improves DMA performance for host devices while still allowing VM passthrough.\n- `force`: Forces IOMMU initialization."
        ),
        ConfigItem(
            label="PCIE ASPM",
            key="pcie_aspm",
            scope="DEFAULT",
            type_="cycle",
            options=["unset", "default", "force", "off"],
            default="unset",
            group="PCIe",
            extended_help="**Active State Power Management**\n\nPCIe power saving configuration.\n\n- `force`: Forces ASPM on even if the BIOS says it's unsupported (can save power on laptops but may cause instability).\n- `off`: Disables ASPM entirely to prevent latency spikes or hardware crashes."
        ),
        ConfigItem(
            label="USB Autosuspend",
            key="usbcore.autosuspend",
            scope="DEFAULT",
            type_="cycle",
            options=["unset", "-1", "1"],
            default="unset",
            group="USB",
            extended_help="**USB Core Autosuspend**\n\nControls the delay (in seconds) before an idle USB device is suspended.\n\n- `-1`: Completely disables USB autosuspend, which can fix issues with external audio DACs, mice, or keyboards disconnecting randomly."
        ),
        ConfigItem(
            label="Memory Limit",
            key="mem",
            scope="DEFAULT",
            type_="cycle",
            options=["unset", "6G", "8G", "16G", "32G"],
            default="unset",
            group="Hardware",
            extended_help="**Force Memory Limit**\n\nRestricts the kernel to using only the specified amount of RAM. Useful for simulating lower-memory environments during debugging."
        ),
        ConfigItem(
            label="Clock Source",
            key="clocksource",
            scope="DEFAULT",
            type_="cycle",
            options=["unset", "tsc", "hpet", "acpi_pm"],
            default="unset",
            group="Hardware",
            extended_help="**Hardware Clock Source**\n\nForces the kernel to use a specific clock source for timekeeping.\n\n- `tsc`: Time Stamp Counter (fastest and preferred for modern systems).\n- `hpet`: High Precision Event Timer (older fallback)."
        ),
        ConfigItem(
            label="ACPI Backlight",
            key="acpi_backlight",
            scope="DEFAULT",
            type_="cycle",
            options=["unset", "video", "vendor", "native"],
            default="unset",
            group="ACPI",
            extended_help="**Backlight Driver Selection**\n\nOverrides the default ACPI backlight driver selection. Changing this to `vendor` or `native` can often resolve issues with non-working brightness hotkeys on laptops."
        ),
    ],

    # -------------------------------------------------------------------------
    # TAB 2: DEBUG
    # -------------------------------------------------------------------------
    2: [
        ConfigItem(
            label="Quiet Boot",
            key="quiet",
            scope="DEFAULT",
            type_="bool",
            default=False,
            group="Logging",
            extended_help="**Quiet Mode**\n\nSuppresses the vast majority of normal kernel initialization messages during the boot process, resulting in a cleaner, faster-scrolling screen or a seamless splash screen."
        ),
        ConfigItem(
            label="Log Level",
            key="loglevel",
            scope="DEFAULT",
            type_="int",
            min_val=0,
            max_val=7,
            step=1,
            default=3,
            group="Logging",
            extended_help="**Console Loglevel**\n\nDefines the severity threshold for printing messages to the console.\n\n- `0`: KERN_EMERG (Only emergencies)\n- `3`: KERN_ERR (Errors and worse, normal desktop standard)\n- `7`: KERN_DEBUG (Extremely verbose)"
        ),
        ConfigItem(
            label="Ignore Loglevel",
            key="ignore_loglevel",
            scope="DEFAULT",
            type_="bool",
            default=False,
            group="Logging",
            extended_help="**Force Verbose Logs**\n\nForces the kernel to print all messages to the console regardless of the `loglevel` setting. Useful for deep debugging of driver initialization failures."
        ),
        ConfigItem(
            label="Always Enable SysRq",
            key="sysrq_always_enabled",
            scope="DEFAULT",
            type_="bool",
            default=False,
            group="Kernel",
            extended_help="**Magic SysRq Key**\n\nEnables all functions of the Magic SysRq key combinations (Alt+SysRq+<Key>), allowing you to gracefully recover, reboot (REISUB), or dump state from a totally frozen system."
        ),
        ConfigItem(
            label="Initcall Debug",
            key="initcall_debug",
            scope="DEFAULT",
            type_="bool",
            default=False,
            group="Kernel",
            extended_help="**Initcall Timing Debug**\n\nTraces every single function called during kernel initialization and prints how long it took. Invaluable for profiling slow boot times."
        ),
        ConfigItem(
            label="Panic Timeout (s)",
            key="panic",
            scope="DEFAULT",
            type_="int",
            min_val=-1,
            max_val=60,
            step=1,
            default=0,
            group="Kernel",
            extended_help="**Reboot on Panic**\n\nSets the timeout in seconds before automatically rebooting the system after a kernel panic.\n\n- `0`: Wait forever (halt).\n- `-1`: Reboot immediately."
        ),
    ],

    # -------------------------------------------------------------------------
    # TAB 3: MISC
    # -------------------------------------------------------------------------
    3: [
        ConfigItem(
            label="AppArmor",
            key="apparmor",
            scope="DEFAULT",
            type_="cycle",
            options=["unset", "0", "1"],
            default="unset",
            group="Security",
            extended_help="**AppArmor MAC**\n\nMandatory Access Control module.\n\n- `1`: Enables the AppArmor security module.\n- `0`: Disables it."
        ),
        ConfigItem(
            label="SELinux",
            key="selinux",
            scope="DEFAULT",
            type_="cycle",
            options=["unset", "0", "1"],
            default="unset",
            group="Security",
            extended_help="**SELinux MAC**\n\nSecurity-Enhanced Linux module.\n\n- `1`: Enables SELinux.\n- `0`: Disables SELinux completely at boot."
        ),
        ConfigItem(
            label="Audit Subsystem",
            key="audit",
            scope="DEFAULT",
            type_="cycle",
            options=["unset", "0", "1"],
            default="unset",
            group="Security",
            extended_help="**Kernel Audit Subsystem**\n\n- `1`: Enables the kernel auditing subsystem used by tools like auditd.\n- `0`: Disables auditing to slightly reduce overhead and log spam if you don't use it."
        ),
        ConfigItem(
            label="FSCK Mode",
            key="fsck.mode",
            scope="DEFAULT",
            type_="cycle",
            options=["unset", "auto", "skip"],
            default="unset",
            group="Boot",
            extended_help="**File System Check**\n\nControls when `fsck` is executed on root file systems at boot time.\n\n- `skip`: Skips checking the root file system entirely (speeds up boot but risks mounting a dirty filesystem)."
        ),
        ConfigItem(
            label="Console Blank (s)",
            key="consoleblank",
            scope="DEFAULT",
            type_="int",
            min_val=0,
            max_val=3600,
            step=60,
            default=600,
            group="Console",
            extended_help="**TTY Screen Blanking**\n\nTime in seconds before a virtual TTY console will blank its screen to prevent burn-in.\n\n- `0`: Disables screen blanking entirely.\n- `600`: Defaults to 10 minutes."
        ),
        ConfigItem(
            label="Update Bootloader",
            key="action_update_bootloader",
            scope="DEFAULT",
            type_="action",
            default="if command -v limine-update >/dev/null; then limine-update; elif command -v grub-mkconfig >/dev/null; then grub-mkconfig -o /boot/grub/grub.cfg; else echo 'No known bootloader tool found'; sleep 3; fi",
            group="Actions",
            extended_help="**Apply Kernel Changes**\n\nRunning this action executes an update script to apply your saved `/etc/kernel/cmdline` parameters to the active bootloader. It automatically attempts to use `limine-update` or `grub-mkconfig` depending on what is installed."
        )
    ]
}
