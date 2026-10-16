#!/bin/bash
set -Eeuo pipefail

# dkms (and modprobe, depmod, ...) live in sbin, which isn't on a normal
# user's PATH on Debian. Without this, `dkms status` silently finds nothing.
export PATH="${PATH}:/usr/local/sbin:/usr/sbin:/sbin"

# RTW88 Driver Installation Script
# Installs Realtek WiFi 5 drivers (rtw88) with DKMS support
# Supports: RTL8723DE, RTL8812AE, RTL8814AE, RTL8821AE, RTL8821CE, RTL8822BE, RTL8822CE (PCIe),
#           RTL8723DU, RTL8811AU, RTL8811CU, RTL8812AU, RTL8812BU, RTL8812CU, RTL8814AU,
#           RTL8821AU, RTL8821CU, RTL8822BU, RTL8822CU (USB),
#           RTL8723CS, RTL8723DS, RTL8821CS, RTL8822BS, RTL8822CS (SDIO)
# Compatible with: Debian, Ubuntu, Kali Linux, Raspberry Pi OS, Arch-based distros

# Configuration
readonly REPO_URL="https://github.com/lwfinger/rtw88.git"
readonly INSTALL_URL="https://dandanilyuk.github.io/rtw88_driver_installer/install.sh"
readonly DKMS_MODULE_NAME="rtw88"
# DKMS_VERSION is auto-detected from dkms.conf after clone; fallback retained below.
DKMS_VERSION="0.6"
readonly SCRIPT_VERSION="1.4.0"
readonly STATUS_FILE="/var/lib/driver_install/status.flag"
readonly MODPROBE_CONF="/etc/modprobe.d/rtw88.conf"
# Reassigned by --log-file, or by start_logging() with a /tmp fallback if
# /var/log isn't writable.
LOG_FILE="/var/log/rtw88-install.log"

# Distro family detection (set during detect_distro)
DISTRO_FAMILY=""

# Color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# State tracking
SUDO_KEEPALIVE_PID=""
APT_UPDATE_DONE=false
DRY_RUN=false
UNATTENDED=false
UNINSTALL_MODE=false
LOG_FILE_EXPLICIT=false
LOG_TEE_PID=""
SECURE_BOOT_ENABLED=false
REPLACE_EXISTING=false
VERIFY_OK=true
# Private temp directory holding the clone; set by clone_repository() and
# removed by cleanup(). Nothing outside it is ever deleted on exit.
WORK_DIR=""
REPO_DIR=""

# Step counter (updated by step_begin). STEP_TOTAL must match the number of
# step_begin() calls in main(); bump this when adding or removing a phase.
STEP_TOTAL=9
STEP_CURRENT=0

# Avoid interactive apt prompts for config files
export DEBIAN_FRONTEND=noninteractive

# on_error <exit-code> <line> - report where an unexpected failure happened.
# `set -E` makes the trap fire inside functions too.
on_error() {
    local rc="$1" line="$2"
    echo -e "${RED}[ERROR]${NC} Script failed in ${FUNCNAME[1]:-main}() at line ${line} (exit code: ${rc})." >&2
    if [[ -n "$LOG_TEE_PID" ]]; then
        echo -e "${RED}[ERROR]${NC} See ${LOG_FILE} for the full log." >&2
    fi
}
trap 'on_error $? $LINENO' ERR

# --- Status & Logging Functions ---
# update_status <message> - append a timestamped line to STATUS_FILE.
# Best effort: a status-file problem never aborts the install.
update_status() {
    local message="$1" status_dir
    # Not `echo | run sudo tee`: in dry-run, run() never reads the pipe, so
    # echo dies of SIGPIPE and pipefail kills the script.
    if [[ "$DRY_RUN" == true ]]; then
        dry_run_note "record status: ${message}"
        return 0
    fi
    status_dir=$(dirname "$STATUS_FILE")
    [[ -d "$status_dir" ]] || sudo mkdir -p "$status_dir" || true
    echo "$(date +"%Y-%m-%d %T") - $message" | sudo tee -a "$STATUS_FILE" > /dev/null || true
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

# dry_run_note <text> - announce something dry-run mode is skipping. Goes to
# stderr so callers that redirect stdout still surface the notice.
dry_run_note() {
    echo -e "${YELLOW}[DRY-RUN]${NC} $*" >&2
}

# run <cmd> [args...] - execute a destructive command or, in dry-run mode,
# print what would have been executed without actually running it.
run() {
    if [[ "$DRY_RUN" == true ]]; then
        dry_run_note "$*"
        return 0
    fi
    "$@"
}

step_begin() {
    STEP_CURRENT=$((STEP_CURRENT + 1))
    echo ""
    echo -e "${BLUE}[${STEP_CURRENT}/${STEP_TOTAL}]${NC} $*"
}

# CLI Arguments
show_help() {
    cat <<EOF
Usage: ./install.sh [OPTIONS]
   or: /bin/bash -c "\$(curl -fsSL ${INSTALL_URL})" -- [OPTIONS]

Run as your normal user, not root. The script asks for sudo when it needs it.

Options:
  -h, --help           Show this help message
  -v, --version        Show script version
  -y, --yes            Skip confirmation prompts (unattended install; reboots when done)
  -u, --uninstall      Uninstall the driver and DKMS entries
  -n, --dry-run        Show what would run without making any changes
      --log-file PATH  Write the install log to PATH (default: /var/log/rtw88-install.log)

EOF
    exit "${1:-0}"
}

show_version() {
    echo "RTW88 Driver Installer v${SCRIPT_VERSION}"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            ;;
        -v|--version)
            show_version
            ;;
        -y|--yes)
            UNATTENDED=true
            shift
            ;;
        -u|--uninstall)
            UNINSTALL_MODE=true
            shift
            ;;
        -n|--dry-run)
            DRY_RUN=true
            shift
            ;;
        --log-file|--log-file=*)
            if [[ "$1" == *=* ]]; then
                LOG_FILE="${1#*=}"
                shift
            else
                LOG_FILE="${2:-}"
                shift $(( $# > 1 ? 2 : 1 ))
            fi
            if [[ -z "$LOG_FILE" ]]; then
                echo "Error: --log-file requires a PATH argument" >&2
                exit 1
            fi
            LOG_FILE_EXPLICIT=true
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "" >&2
            show_help 1 >&2
            ;;
    esac
done


# --- Helper Functions ---
apt_update_once() {
    if [[ "$APT_UPDATE_DONE" == true ]]; then
        return 0
    fi
    APT_UPDATE_DONE=true
    if ! run sudo apt-get update -qq; then
        log_warning "apt-get update failed, so package lists may be stale. If an install below fails, check your apt sources."
    fi
}

# pkg_installed <package> - returns 0 if installed, 1 otherwise.
pkg_installed() {
    local pkg="$1"
    if [[ "$DISTRO_FAMILY" == "arch" ]]; then
        pacman -Qi "$pkg" &>/dev/null
    else
        [[ "$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null || true)" == "install ok installed" ]]
    fi
}

# pkg_install <package...> - installs one or more packages non-interactively.
# On Debian, ensures `apt-get update` has run once this session.
pkg_install() {
    if [[ "$DISTRO_FAMILY" == "arch" ]]; then
        run sudo pacman -S --noconfirm --needed "$@"
    else
        apt_update_once
        run sudo apt-get install -y "$@"
    fi
}

# pkg_search_exact <package> - returns 0 if the exact package name is known
# to the configured repositories, 1 otherwise. The name is matched literally,
# so kernel versions with regex characters (e.g. 6.6.31+rpt-rpi-v8) work.
pkg_search_exact() {
    local pkg="$1"
    if [[ "$DISTRO_FAMILY" == "arch" ]]; then
        pacman -Si "$pkg" &>/dev/null
    else
        apt-cache pkgnames "$pkg" 2>/dev/null | grep -xF -- "$pkg" > /dev/null
    fi
}

print_banner() {
    # Box is 61 columns wide overall (59-char interior between ║ borders).
    local inner=59 border line
    border=$(printf '═%.0s' {1..59})

    echo -e "${GREEN}"
    echo "╔${border}╗"
    for line in "RTW88 WiFi 5 Driver Installer (v${SCRIPT_VERSION})" \
                "Automated DKMS setup for Linux"; do
        printf "║%*s%s%*s║\n" \
            $(( (inner - ${#line}) / 2 )) "" \
            "$line" \
            $(( inner - ${#line} - (inner - ${#line}) / 2 )) ""
    done
    echo "╚${border}╝"
    echo -e "${NC}"
}

# --- Distro Detection ---
detect_distro() {
    local id="" id_like="" pretty="" os_info

    if [[ -r /etc/os-release ]]; then
        # Read in a subshell so os-release's variables (NAME, VERSION, ...)
        # can't clobber the script's own.
        os_info=$(. /etc/os-release && printf '%s|%s|%s' "${ID:-}" "${ID_LIKE:-}" "${PRETTY_NAME:-}" || true)
        IFS='|' read -r id id_like pretty <<< "$os_info"
    fi

    case "$id" in
        arch|manjaro|endeavouros|garuda|artix|cachyos)
            DISTRO_FAMILY="arch"
            ;;
        debian|ubuntu|kali|linuxmint|pop|raspbian|zorin|elementary|parrot)
            DISTRO_FAMILY="debian"
            ;;
        *)
            # Check ID_LIKE for derivatives, then fall back to the package manager
            if [[ "$id_like" == *"arch"* ]]; then
                DISTRO_FAMILY="arch"
            elif [[ "$id_like" == *"debian"* ]] || [[ "$id_like" == *"ubuntu"* ]]; then
                DISTRO_FAMILY="debian"
            elif [[ -z "$id" ]] && command -v pacman &>/dev/null; then
                DISTRO_FAMILY="arch"
            elif [[ -z "$id" ]] && command -v apt-get &>/dev/null; then
                DISTRO_FAMILY="debian"
            else
                log_error "Unsupported distribution: ${id:-unknown} (${id_like:-unknown})"
                log_error "This script supports Debian/Ubuntu-based and Arch-based distros"
                exit 1
            fi
            ;;
    esac

    log_info "Detected ${pretty:-${id:-your system}} (${DISTRO_FAMILY} family)"
}

check_root() {
    if [[ $EUID -eq 0 ]]; then
        log_error "Do not run this script as root."
        log_info "Run as a normal user. The script will use sudo when needed."
        exit 1
    fi
}

check_sudo() {
    if ! sudo -n true 2>/dev/null; then
        log_info "This script requires sudo privileges"
        sudo -v || { log_error "Failed to obtain sudo privileges"; exit 1; }
    fi
    # Keep sudo alive during long builds. cleanup() kills the loop on exit, and
    # it also stops on its own if this script dies without running cleanup().
    # Its stdio goes to /dev/null so a leftover `sleep` can't hold the
    # script's output pipe open (e.g. `./install.sh | tee log`) after exit.
    local parent=$$
    ( while kill -0 "$parent" 2>/dev/null; do sudo -n true 2>/dev/null || exit 0; sleep 50; done ) \
        < /dev/null > /dev/null 2>&1 &
    SUDO_KEEPALIVE_PID=$!
}

check_network() {
    log_info "Checking network connectivity..."
    if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
        log_warning "Cannot verify network (no curl or wget). Continuing anyway..."
        return 0
    fi
    if curl -sf --max-time 10 https://github.com -o /dev/null 2>/dev/null \
        || wget -q --timeout=10 --spider https://github.com 2>/dev/null; then
        log_success "Network connectivity OK"
    else
        log_error "Cannot reach github.com. Check your internet connection."
        exit 1
    fi
}

# detect_chipset - scan for Realtek WiFi hardware via lspci, lsusb, and the
# SDIO bus, and report what was found. Does not abort if nothing is found;
# the user may be installing before plugging in the adapter.
detect_chipset() {
    local -x LC_ALL=C
    local chips="8723DE|8812AE|8813AE|8814AE|8821AE|8821CE|8822BE|8822CE|8723DU|8811AU|8811CU|8812AU|8812BU|8812CU|8814AU|8821AU|8821CU|8822BU|8822CU|88x2BU"
    local devices="" found_devices=() dev

    if ! command -v lspci &>/dev/null && ! command -v lsusb &>/dev/null; then
        log_warning "lspci and lsusb aren't installed, so hardware detection is skipped. Continuing."
        return 1
    fi

    # Realtek is PCIe vendor 10ec, USB vendor 0bda. Collected with `|| true`
    # so an empty result doesn't trip the ERR trap.
    devices=$(
        { lspci -nn 2>/dev/null || true; lsusb 2>/dev/null || true; } \
            | grep -iE "realtek|10ec:|0bda:" \
            | grep -iE "wireless|wlan|wi-?fi|802\.11|network|${chips}" || true
    )
    # SDIO cards don't show up in lspci/lsusb; Realtek's SDIO vendor ID is 0x024c.
    for dev in /sys/bus/sdio/devices/*; do
        [[ -r "$dev/vendor" ]] || continue
        if [[ "$(cat "$dev/vendor")" == "0x024c" ]]; then
            devices+="${devices:+$'\n'}SDIO ${dev##*/}: Realtek device [024c:$(cat "$dev/device" 2>/dev/null || echo "????")]"
        fi
    done

    if [[ -z "$devices" ]]; then
        log_warning "No Realtek WiFi adapter detected."
        log_info "That's OK if you haven't plugged in a USB adapter yet, or if you're installing ahead of time. Continuing."
        return 1
    fi

    mapfile -t found_devices <<< "$devices"
    local noun="devices"
    [[ ${#found_devices[@]} -eq 1 ]] && noun="device"
    log_success "Detected ${#found_devices[@]} Realtek WiFi ${noun}:"
    printf '  - %s\n' "${found_devices[@]}"
    return 0
}

# get_user_confirmation <prompt> [default y|n] - ask a yes/no question.
# Answers come from the terminal even when stdin is a pipe (curl | bash).
get_user_confirmation() {
    if [[ "$UNATTENDED" == true ]]; then
        return 0
    fi

    local prompt_msg="$1"
    local default="${2:-n}"
    local hint="[y/N]" reply tty_in="/dev/stdin"
    [[ "$default" == "y" ]] && hint="[Y/n]"

    if [[ ! -t 0 ]]; then
        if { : < /dev/tty; } 2>/dev/null; then
            tty_in="/dev/tty"
        else
            log_warning "No terminal to answer \"${prompt_msg}\", so using the default (${default}). Re-run with -y to accept every prompt."
            if [[ "$default" == "y" ]]; then
                return 0
            fi
            return 1
        fi
    fi

    while true; do
        if ! read -r -p "${prompt_msg} ${hint}: " reply < "$tty_in"; then
            # EOF (e.g. Ctrl+D): take the default answer.
            echo ""
            reply=""
        fi
        reply="${reply:-$default}"

        case "${reply,,}" in
            y|yes) return 0 ;;
            n|no) return 1 ;;
            *) log_warning "Invalid input. Please answer y or n." ;;
        esac
    done
}

check_secure_boot() {
    if command -v mokutil &>/dev/null && mokutil --sb-state 2>/dev/null | grep -q "SecureBoot enabled"; then
        SECURE_BOOT_ENABLED=true
        log_warning "Secure Boot is ENABLED"
        log_info "You may need to enroll a MOK (Machine Owner Key) after installation."
        log_info "The script will tell you at the end whether that's needed."
        return 0
    fi
    log_info "Secure Boot is disabled or not detected"
    return 1
}

# dkms_status_lines - print the `dkms status` lines for rtw88 only.
# Handles both `rtw88/0.6, <kernel>, ...` (dkms 3.x) and `rtw88, 0.6, ...`
# (dkms 2.x) formats.
dkms_status_lines() {
    dkms status 2>/dev/null | awk -F'[,/:] *' -v m="$DKMS_MODULE_NAME" '$1 == m' || true
}

# dkms_versions - print each rtw88 version registered with DKMS, one per line.
dkms_versions() {
    dkms_status_lines | awk -F'[,/:] *' '$2 != "" { print $2 }' | sort -u || true
}

check_existing_driver() {
    local found_issues=false out

    # Out-of-tree rtw88 modules are named rtw_*; the in-kernel driver uses
    # rtw88_* and is left alone (rtw88.conf blacklists it).
    out=$(lsmod 2>/dev/null | awk '/^rtw_/ {print "  - " $1}' || true)
    if [[ -n "$out" ]]; then
        log_warning "RTW88 driver module(s) currently loaded:"
        echo "$out"
        found_issues=true
    fi

    # Check DKMS installations
    out=$(dkms_status_lines)
    if [[ -n "$out" ]]; then
        log_warning "DKMS installation(s) found:"
        echo "$out" | sed 's/^/  - /'
        found_issues=true
    fi

    [[ "$found_issues" == true ]]
}

# check_conflicting_drivers - warn about other out-of-tree Realtek drivers
# (aircrack-ng/rtl8812au, morrownr/88x2bu, Kali's realtek-rtl88xxau-dkms, ...)
# that claim the same devices. rtw88.conf only blacklists the in-kernel rtw88
# modules, so these keep competing for the adapter. Warns only; never removes.
check_conflicting_drivers() {
    local -x LC_ALL=C
    local pattern='^(rtl|realtek-rtl)?(8812au|88xxau|8814au|8821au|8821cu|88x2bu|8822bu)$'
    local modules dkms_entries

    modules=$(lsmod 2>/dev/null | awk 'NR > 1 {print $1}' | grep -iE "$pattern" || true)
    dkms_entries=$(dkms status 2>/dev/null | awk -F'[,/:] *' '{print $1}' | grep -iE "$pattern" | sort -u || true)

    if [[ -z "$modules" && -z "$dkms_entries" ]]; then
        return 1
    fi

    log_warning "Found other Realtek drivers that can conflict with rtw88:"
    if [[ -n "$modules" ]]; then
        echo "$modules" | sed 's/^/  - loaded module: /'
    fi
    if [[ -n "$dkms_entries" ]]; then
        echo "$dkms_entries" | sed 's/^/  - DKMS package: /'
    fi
    log_info "If your adapter misbehaves after rebooting, remove them first (for example: 'sudo dkms remove <name>/<version> --all', or 'sudo apt remove realtek-rtl88xxau-dkms' on Kali)."
    return 0
}

# unload_modules - unload every loaded out-of-tree rtw88 module, dependents
# first. lsmod lists the most recently loaded module first, which is exactly
# the order they can be removed in.
unload_modules() {
    local modules=() module
    mapfile -t modules < <(lsmod 2>/dev/null | awk '/^rtw_/ {print $1}' || true)
    [[ ${#modules[@]} -gt 0 ]] || return 0

    log_info "Unloading rtw88 driver modules..."
    for module in "${modules[@]}"; do
        # modprobe -r also drops dependencies that became unused, so a module
        # later in the list may already be gone.
        [[ "$DRY_RUN" == true || -d "/sys/module/${module}" ]] || continue
        log_info "  Unloading: $module"
        run sudo modprobe -r "$module" 2>/dev/null \
            || log_warning "Could not unload $module (still in use?). It will be gone after a reboot."
    done
}

# remove_existing_driver [unload] - remove every registered rtw88 DKMS version,
# its source tree, and the modprobe config. Pass "true" to also unload the
# running modules (uninstall); a reinstall skips that so WiFi stays up.
remove_existing_driver() {
    local unload="${1:-false}"
    log_info "Removing existing driver installation..."

    if [[ "$unload" == true ]]; then
        unload_modules
    fi

    # Remove all DKMS versions
    local versions=() version
    mapfile -t versions < <(dkms_versions)
    if [[ ${#versions[@]} -gt 0 ]]; then
        log_info "Removing DKMS installation(s)..."
        for version in "${versions[@]}"; do
            log_info "  Removing: ${DKMS_MODULE_NAME}/${version}"
            run sudo dkms remove "${DKMS_MODULE_NAME}/${version}" --all < /dev/null \
                || log_warning "dkms remove ${DKMS_MODULE_NAME}/${version} reported an error. Continuing."
        done
        log_success "DKMS entries removed"
    fi

    # Clean up source directories for any rtw88-* version
    local src_dir
    for src_dir in "/usr/src/${DKMS_MODULE_NAME}-"*; do
        [[ -d "$src_dir" ]] || continue
        log_info "Cleaning up old source directory: $src_dir"
        run sudo rm -rf "$src_dir" || true
    done

    # Remove old config file if exists
    if [[ -f "$MODPROBE_CONF" ]]; then
        log_info "Removing configuration file..."
        run sudo rm -f "$MODPROBE_CONF"
    fi
}

is_raspberry_pi() {
    grep -q "^Model\s*:\s*Raspberry Pi" /proc/cpuinfo 2>/dev/null \
        || grep -qa "Raspberry Pi" /proc/device-tree/model 2>/dev/null
}

# headers_ready - true when the running kernel's build directory exists
# (always true in dry-run mode, where nothing is actually installed).
headers_ready() {
    [[ "$DRY_RUN" == true ]] || [[ -d "/lib/modules/$(uname -r)/build" ]]
}

# arch_headers_package <kernel-version> - name the headers package for the
# running kernel. Kernel packages record their name in pkgbase, which covers
# linux, linux-lts, linux-zen, Manjaro's linux66, and so on.
arch_headers_package() {
    local kernel_version="$1" base=""
    local moddir="/usr/lib/modules/${kernel_version}"

    if [[ -r "${moddir}/pkgbase" ]]; then
        base=$(head -n 1 "${moddir}/pkgbase")
    elif [[ -e "${moddir}/vmlinuz" ]]; then
        base=$(pacman -Qqo "${moddir}/vmlinuz" 2>/dev/null || true)
    fi

    if [[ -z "$base" ]]; then
        case "$kernel_version" in
            *-lts*) base="linux-lts" ;;
            *-zen*) base="linux-zen" ;;
            *-hardened*) base="linux-hardened" ;;
            *) base="linux" ;;
        esac
    fi
    echo "${base}-headers"
}

check_and_install_kernel_headers() {
    local kernel_version
    kernel_version=$(uname -r)

    log_info "Checking kernel headers for: $kernel_version"

    # Check if headers are already installed
    if [[ -d "/lib/modules/$kernel_version/build" ]]; then
        log_success "Kernel headers already installed"
        return 0
    fi

    log_warning "Kernel headers not found, attempting to install..."

    if [[ "$DISTRO_FAMILY" == "arch" ]]; then
        # NOTE: do NOT run `pacman -Sy` standalone (partial-upgrade anti-pattern);
        # if the package can't be found, a full `pacman -Syu` is the user's fix.
        local headers_pkg
        headers_pkg=$(arch_headers_package "$kernel_version")

        log_info "Installing ${headers_pkg}..."
        if pkg_install "$headers_pkg" && headers_ready; then
            log_success "Kernel headers installed"
            return 0
        fi

        log_error "Could not install headers for the running kernel ($kernel_version)"
        log_error "Run 'sudo pacman -Syu ${headers_pkg}', reboot into the updated kernel, then re-run this script."
        return 1
    fi

    # Debian-based path: the exact package for the running kernel first, then
    # the legacy Raspberry Pi headers, then the distro metapackages
    # (linux-headers-amd64 style on Debian/Kali, linux-headers-generic on Ubuntu).
    # A metapackage only helps if the running kernel is the newest one, so
    # every attempt is checked against /lib/modules/<kernel>/build.
    apt_update_once
    local candidates=("linux-headers-${kernel_version}")
    if is_raspberry_pi; then
        log_info "Raspberry Pi detected"
        candidates+=("raspberrypi-kernel-headers")
    fi
    candidates+=("linux-headers-$(dpkg --print-architecture)" "linux-headers-generic")

    local headers_pkg
    for headers_pkg in "${candidates[@]}"; do
        # Already installed means it didn't provide this kernel's build dir;
        # reinstalling won't change that (and would mark it manually installed).
        pkg_installed "$headers_pkg" && continue
        pkg_search_exact "$headers_pkg" || continue
        log_info "Trying ${headers_pkg}..."
        if pkg_install "$headers_pkg" && headers_ready; then
            log_success "Kernel headers installed (${headers_pkg})"
            return 0
        fi
    done

    log_error "Could not install headers for the running kernel ($kernel_version)"
    log_error "This usually means a newer kernel is installed but not running yet."
    log_error "Run 'sudo apt-get update && sudo apt-get full-upgrade', reboot, then re-run this script."
    return 1
}

install_packages() {
    log_info "Installing required packages..."

    local packages=()
    if [[ "$DISTRO_FAMILY" == "arch" ]]; then
        # base-devel is a package group; check for gcc as a proxy.
        packages=("dkms" "git" "base-devel")
    else
        packages=("dkms" "git" "build-essential")
    fi

    local missing_packages=() pkg probe
    for pkg in "${packages[@]}"; do
        probe="$pkg"
        if [[ "$pkg" == "base-devel" ]]; then
            probe="gcc"
        fi
        if ! pkg_installed "$probe"; then
            missing_packages+=("$pkg")
        fi
    done

    if [[ ${#missing_packages[@]} -eq 0 ]]; then
        log_success "All required packages already installed"
        return 0
    fi

    log_info "Installing: ${missing_packages[*]}"
    if pkg_install "${missing_packages[@]}"; then
        log_success "Packages installed successfully"
    else
        log_error "Failed to install required packages"
        return 1
    fi
}

# clone_repository - shallow-clone the driver into a fresh private temp
# directory, so nothing in the current directory is touched or deleted.
clone_repository() {
    log_info "Cloning rtw88 driver repository..."
    if [[ "$DRY_RUN" == true ]]; then
        REPO_DIR="${TMPDIR:-/tmp}/rtw88-install.XXXXXX/rtw88"
        dry_run_note "git clone --depth 1 ${REPO_URL} ${REPO_DIR}"
        log_info "Skipping DKMS version detection in dry-run (no source tree to read)."
        return 0
    fi

    if ! WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rtw88-install.XXXXXX"); then
        WORK_DIR=""
        log_error "Could not create a temporary directory"
        return 1
    fi
    REPO_DIR="${WORK_DIR}/rtw88"

    local clone_output
    if clone_output=$(git clone --depth 1 "$REPO_URL" "$REPO_DIR" 2>&1); then
        log_success "Repository cloned successfully"
        detect_dkms_version
        return 0
    else
        log_error "Failed to clone repository"
        log_error "$clone_output"
        return 1
    fi
}

detect_dkms_version() {
    local dkms_conf="${REPO_DIR}/dkms.conf"
    if [[ ! -f "$dkms_conf" ]]; then
        log_warning "dkms.conf not found; using fallback version ${DKMS_VERSION}"
        return 0
    fi

    local parsed
    parsed=$(sed -nE 's/^[[:space:]]*PACKAGE_VERSION[[:space:]]*=[[:space:]]*["'\'']?([^"'\''#]*).*$/\1/p' "$dkms_conf" \
        | head -n 1 | tr -d '[:space:]')

    if [[ -n "$parsed" ]]; then
        DKMS_VERSION="$parsed"
        log_info "Detected DKMS version from dkms.conf: ${DKMS_VERSION}"
    else
        log_warning "Could not parse PACKAGE_VERSION from dkms.conf (upstream format may have changed); using fallback ${DKMS_VERSION}. Installation should still work."
    fi
}

install_driver_via_dkms() {
    log_info "Installing rtw88 driver via DKMS..."
    log_info "  Kernel: $(uname -r)"
    log_info "  Architecture: $(uname -m)"

    if [[ "$DRY_RUN" == true ]]; then
        dry_run_note "sudo dkms install ${REPO_DIR}"
        dry_run_note "sudo make -C ${REPO_DIR} install_fw"
        dry_run_note "sudo cp ${REPO_DIR}/rtw88.conf ${MODPROBE_CONF}"
        return 0
    fi

    # Install via DKMS (copies the source to /usr/src/rtw88-<version>)
    if sudo dkms install "$REPO_DIR"; then
        log_success "Driver built and installed via DKMS"
    else
        log_error "DKMS build failed. Check the build log at /var/lib/dkms/${DKMS_MODULE_NAME}/${DKMS_VERSION}/build/make.log for compiler errors."
        return 1
    fi

    # Install firmware
    log_info "Installing firmware..."
    if sudo make -C "$REPO_DIR" install_fw; then
        log_success "Firmware installed"
    else
        log_warning "Firmware install reported errors. Usually harmless - if WiFi doesn't work after reboot, check 'dmesg | grep rtw' for missing firmware messages."
    fi

    # Copy configuration file
    log_info "Installing configuration file..."
    if sudo cp "${REPO_DIR}/rtw88.conf" "$MODPROBE_CONF"; then
        log_success "Configuration file installed"
    else
        log_warning "Could not install configuration file"
    fi
}

verify_installation() {
    log_info "Verifying installation..."

    if [[ "$DRY_RUN" == true ]]; then
        dry_run_note "Would verify DKMS module registration and ${MODPROBE_CONF}"
        return 0
    fi

    local kernel_version status
    kernel_version=$(uname -r)
    status=$(dkms status -m "$DKMS_MODULE_NAME" -k "$kernel_version" 2>/dev/null || true)
    if [[ "$status" == *": installed"* ]]; then
        log_success "DKMS module registered and installed for kernel ${kernel_version}:"
        echo "$status" | sed 's/^/  /'
    else
        log_error "DKMS module is not installed for the running kernel (${kernel_version})"
        [[ -n "$status" ]] && echo "$status" | sed 's/^/  /'
        return 1
    fi

    if [[ -f "$MODPROBE_CONF" ]]; then
        log_success "Configuration file present"
    else
        log_warning "Configuration file not found"
    fi

    return 0
}

# mok_key_path - print the DKMS signing certificate present on this system:
# Ubuntu's shim-signed key first, then the generic DKMS key.
mok_key_path() {
    local key
    for key in /var/lib/shim-signed/mok/MOK.der /var/lib/dkms/mok.pub; do
        if [[ -f "$key" ]]; then
            echo "$key"
            return 0
        fi
    done
    return 1
}

show_secure_boot_instructions() {
    local key
    echo ""
    if ! key=$(mok_key_path); then
        log_warning "Secure Boot is enabled, but no DKMS signing key was found"
        log_info "  (looked for /var/lib/shim-signed/mok/MOK.der and /var/lib/dkms/mok.pub)."
        log_info "  The kernel may refuse to load the driver. After rebooting, check 'dmesg | grep -i rtw'."
        log_info "  See https://github.com/dell/dkms#secure-boot for signing modules manually."
        return 0
    fi

    if mokutil --test-key "$key" 2>/dev/null | grep -q "already enrolled"; then
        log_success "Secure Boot is enabled and the DKMS signing key is already enrolled. No MOK step needed."
        return 0
    fi

    log_warning "Secure Boot is enabled - you need to enroll a Machine Owner Key (MOK)"
    echo ""
    log_info "1. Import the MOK key:"
    echo -e "   ${YELLOW}sudo mokutil --import ${key}${NC}"
    echo ""
    log_info "2. You will be asked to set a one-time password. Remember it for the next step."
    log_info "3. Reboot your system."
    log_info "4. A blue MOK Manager screen will appear during boot."
    log_info "5. Select 'Enroll MOK' > Continue > enter the password from step 2."
    log_info "6. Reboot once more to finish."
}

show_post_install_instructions() {
    echo ""
    if [[ "$DRY_RUN" == true ]]; then
        log_success "Dry run finished. The steps below are what you'd see after a real install."
    elif [[ "$VERIFY_OK" == true ]]; then
        log_success "Installation completed successfully!"
    else
        log_warning "Installation finished, but verification reported issues (see above)."
    fi
    echo ""
    log_info "═══════════════════════════════════════════════════════════"
    log_info "NEXT STEPS"
    log_info "═══════════════════════════════════════════════════════════"

    if [[ "$SECURE_BOOT_ENABLED" == true ]]; then
        show_secure_boot_instructions
    fi

    echo ""
    log_info "After rebooting:"
    log_info "  1. Your WiFi adapter should work automatically."
    log_info "  2. Verify the driver loaded: ${YELLOW}lsmod | grep rtw${NC}"
    log_info "  3. Check your interfaces:    ${YELLOW}ip link show${NC}"
    log_info "  4. Look for wlan0, wlp*, or similar."
    if [[ -d "/usr/src/${DKMS_MODULE_NAME}-${DKMS_VERSION}" ]]; then
        echo ""
        log_info "DKMS keeps the driver source at /usr/src/${DKMS_MODULE_NAME}-${DKMS_VERSION}"
    fi
    echo ""
    log_info "═══════════════════════════════════════════════════════════"
    log_info "Supported Chipsets:"
    log_info "  PCIe: RTL8723DE, RTL8812AE, RTL8814AE, RTL8821AE, RTL8821CE,"
    log_info "        RTL8822BE, RTL8822CE"
    log_info "  USB:  RTL8723DU, RTL8811AU, RTL8811CU, RTL8812AU, RTL8812BU, RTL8812CU,"
    log_info "        RTL8814AU, RTL8821AU, RTL8821CU, RTL8822BU, RTL8822CU"
    log_info "  SDIO: RTL8723CS, RTL8723DS, RTL8821CS, RTL8822BS, RTL8822CS"
    log_info "═══════════════════════════════════════════════════════════"
    echo ""

    log_info "To uninstall later, run the installer with -u:"
    echo -e "  ${YELLOW}/bin/bash -c \"\$(curl -fsSL ${INSTALL_URL})\" -- -u${NC}"
    echo ""
}

# --- Cleanup ---
remove_work_dir() {
    [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]] || return 0
    log_info "Cleaning up temporary files..."
    # `make install_fw` runs as root inside the clone, so fall back to sudo
    # if anything it left behind is root-owned.
    rm -rf "$WORK_DIR" 2>/dev/null || sudo rm -rf "$WORK_DIR" 2>/dev/null || true
    WORK_DIR=""
}

stop_sudo_keepalive() {
    if [[ -n "$SUDO_KEEPALIVE_PID" ]] && kill -0 "$SUDO_KEEPALIVE_PID" 2>/dev/null; then
        kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
        wait "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    fi
    SUDO_KEEPALIVE_PID=""
}

# finish_log - close our end of the log pipe and let tee drain, so the last
# lines are written before the shell prompt comes back.
finish_log() {
    [[ -n "$LOG_TEE_PID" ]] || return 0
    local pid="$LOG_TEE_PID" i
    LOG_TEE_PID=""
    exec 1>&- 2>&-
    wait "$pid" 2>/dev/null || true
    for i in 1 2 3 4 5 6 7 8 9 10; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
    done
}

cleanup() {
    stop_sudo_keepalive
    remove_work_dir
    finish_log
}

# --- Main Execution ---
# Ctrl+C / kill stop the script (instead of being read as "no" at a prompt);
# the EXIT trap then runs cleanup() exactly once.
trap cleanup EXIT
trap 'echo ""; log_warning "Interrupted."; exit 130' INT
trap 'exit 143' TERM


acquire_install_lock() {
    local lock_file="/var/lock/rtw88-install.lock"

    # Ensure the lock file exists and is writable by the current user;
    # fall back to /tmp if /var/lock isn't usable.
    if ! { : > "$lock_file"; } 2>/dev/null; then
        if ! sudo touch "$lock_file" 2>/dev/null || ! sudo chmod 0666 "$lock_file" 2>/dev/null; then
            lock_file="/tmp/rtw88-install.lock"
        fi
    fi

    exec 200>"$lock_file"
    if ! flock -n 200; then
        log_error "Another installer is already running (lock: ${lock_file}). Wait for it to finish, or if no installer is running, delete the lock file and retry."
        exit 1
    fi
}

# start_logging - mirror all further output to $LOG_FILE while keeping colors
# on the terminal. The file is created with sudo and handed to the current
# user, so tee itself doesn't need root.
start_logging() {
    if ! { sudo touch "$LOG_FILE" && sudo chown "$(id -u):$(id -g)" "$LOG_FILE"; } 2>/dev/null; then
        local fallback_log="/tmp/rtw88-install-$$.log"
        if [[ "$LOG_FILE_EXPLICIT" == true ]]; then
            log_warning "Could not write to user-specified log file (${LOG_FILE}). Falling back to ${fallback_log}."
        fi
        LOG_FILE="$fallback_log"
        if ! { : > "$LOG_FILE"; } 2>/dev/null; then
            log_warning "Could not create a log file. Continuing without one."
            return 0
        fi
    fi
    chmod 0644 "$LOG_FILE" 2>/dev/null || true

    # tee must survive Ctrl+C so the interrupt message and cleanup output still
    # reach the screen and the log; it exits once the script closes the pipe.
    # `trap ''` alone isn't enough (bash 5.3 doesn't keep it across exec), so
    # tee also gets its own session, out of reach of terminal signals. It drops
    # the lock fd so the lock is released the moment we exit.
    if command -v setsid &>/dev/null; then
        exec > >(trap '' INT TERM; exec setsid tee -a "$LOG_FILE" 200>&-) 2>&1
    else
        exec > >(trap '' INT TERM; exec tee -a "$LOG_FILE" 200>&-) 2>&1
    fi
    LOG_TEE_PID=$!
    log_info "Saving a full log to: $LOG_FILE (useful if something fails)"
}

run_uninstall() {
    detect_distro
    log_warning "Uninstall mode selected"

    local found=false
    if check_existing_driver; then
        found=true
    fi
    if [[ -f "$MODPROBE_CONF" ]] || compgen -G "/usr/src/${DKMS_MODULE_NAME}-*" > /dev/null; then
        found=true
    fi
    if [[ "$found" != true ]]; then
        log_info "No RTW88 driver installation found. Nothing to uninstall."
        exit 0
    fi

    if ! get_user_confirmation "Are you sure you want to uninstall the RTW88 driver?"; then
        log_info "Uninstallation cancelled"
        exit 0
    fi

    remove_existing_driver true
    if [[ -f "$STATUS_FILE" ]]; then
        run sudo rm -f "$STATUS_FILE"
        run sudo rmdir "$(dirname "$STATUS_FILE")" 2>/dev/null || true
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_success "Dry run complete. No changes were made."
    else
        log_success "Uninstallation complete"
        log_info "Reboot to finish. If your kernel has a built-in rtw88 driver, it takes over again."
    fi
    exit 0
}

main() {
    local start_time
    start_time=$(date +%s)

    print_banner
    check_root
    check_sudo
    acquire_install_lock

    if [[ "$DRY_RUN" == true ]]; then
        log_info "Dry-run mode: no changes will be made and no log file will be written."
    else
        start_logging
    fi

    if [[ "$UNINSTALL_MODE" == true ]]; then
        run_uninstall
    fi

    step_begin "Detecting your Linux distribution"
    detect_distro

    step_begin "Detecting Realtek hardware"
    detect_chipset || true

    # Check Secure Boot status (informational; MOK steps are shown post-install)
    check_secure_boot || true

    if ! get_user_confirmation "Ready to proceed with RTW88 driver installation?"; then
        update_status "Installation cancelled by user"
        log_info "Installation cancelled"
        exit 0
    fi

    step_begin "Checking network"
    check_network

    step_begin "Checking for existing driver"
    check_conflicting_drivers || true
    if check_existing_driver; then
        if get_user_confirmation "Existing driver installation found. Replace it with a fresh build?" "y"; then
            # Removal is deferred until just before the new build, so a WiFi
            # connection that depends on the current driver stays up while
            # headers, packages, and the source are downloaded.
            REPLACE_EXISTING=true
            log_info "The existing driver will be replaced after the new source is downloaded."
        else
            update_status "User declined to remove existing driver"
            log_info "Keeping existing installation. Exiting."
            exit 0
        fi
    else
        log_info "No existing driver found"
    fi

    step_begin "Installing kernel headers"
    update_status "Checking kernel headers"
    if ! check_and_install_kernel_headers; then
        update_status "Kernel headers installation failed"
        log_error "Cannot continue without kernel headers."
        exit 1
    fi

    step_begin "Installing packages"
    update_status "Installing required packages"
    if ! install_packages; then
        update_status "Package installation failed"
        log_error "Failed to install required packages"
        exit 1
    fi

    step_begin "Cloning driver repository"
    update_status "Cloning driver repository"
    if ! clone_repository; then
        update_status "Repository clone failed"
        log_error "Failed to clone repository"
        exit 1
    fi

    step_begin "Compiling driver with DKMS (this can take a minute)"
    if [[ "$REPLACE_EXISTING" == true ]]; then
        update_status "Removing existing driver"
        remove_existing_driver false
        log_success "Existing driver removed"
    fi
    update_status "Installing driver via DKMS"
    if ! install_driver_via_dkms; then
        update_status "Driver installation failed"
        log_error "Driver installation failed"
        exit 1
    fi

    step_begin "Verifying installation"
    update_status "Verifying installation"
    if ! verify_installation; then
        VERIFY_OK=false
        log_warning "The driver may still work - reboot and check 'lsmod | grep rtw'. If WiFi doesn't come up, re-run with -u to uninstall and try again."
    fi

    update_status "Installation complete"

    local end_time elapsed
    end_time=$(date +%s)
    elapsed=$((end_time - start_time))
    log_info "Completed in $((elapsed / 60))m $((elapsed % 60))s"

    # Show post-installation instructions
    show_post_install_instructions

    # Reboot prompt
    if get_user_confirmation "Reboot now to complete installation?" "y"; then
        update_status "Rebooting after successful installation"
        # Clean up now; the reboot may not give the EXIT trap time to finish.
        remove_work_dir
        log_info "Rebooting..."
        if ! run sudo reboot; then
            log_warning "Could not reboot automatically. Reboot manually to finish the installation."
        fi
    else
        update_status "Installation complete - manual reboot pending"
        log_warning "Remember to reboot before using your WiFi adapter."
    fi

    if [[ "$DRY_RUN" == true ]]; then
        echo ""
        log_success "Dry run complete. No changes were made."
        exit 0
    fi
}

# Run main function
main "$@"
