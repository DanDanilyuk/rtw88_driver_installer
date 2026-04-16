#!/bin/bash
set -Eeuo pipefail
# LOG_FILE has a default here so the ERR trap below can reference it safely
# even if the trap fires before main() reassigns LOG_FILE.
LOG_FILE="${LOG_FILE:-/var/log/rtw88-install.log}"
trap 'echo -e "\033[0;31m[ERROR]\033[0m Script failed in ${FUNCNAME[0]:-main}() at line $LINENO (exit code: $?). See ${LOG_FILE} for the full log." >&2' ERR

# RTW88 Driver Installation Script
# Installs Realtek WiFi 5 drivers (rtw88) with DKMS support
# Supports: RTL8723DE, RTL8821CE, RTL8822BE, RTL8822CE, RTL8723DU, RTL8811CU, RTL8821CU, RTL8822BU, RTL8822CU, and more
# Compatible with: Debian, Ubuntu, Kali Linux, Raspberry Pi OS, Arch-based distros

# Configuration
readonly REPO_URL="https://github.com/lwfinger/rtw88.git"
readonly REPO_DIR="rtw88"
readonly DKMS_MODULE_NAME="rtw88"
# DKMS_VERSION is auto-detected from dkms.conf after clone; fallback retained below.
DKMS_VERSION="0.6"
readonly SCRIPT_VERSION="1.2.0"
readonly STATUS_FILE="/var/lib/driver_install/status.flag"

# Distro family detection (set during detect_distro)
DISTRO_FAMILY=""

# Color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# State tracking
CLEANUP_ON_EXIT=true
SUDO_KEEPALIVE_PID=""
APT_UPDATE_DONE=false
DRY_RUN=false
LOG_FILE_EXPLICIT=false

# Step counter (updated by step_begin). STEP_TOTAL must match the number of
# step_begin() calls in main(); bump this when adding or removing a phase.
STEP_TOTAL=9
STEP_CURRENT=0

# Note: LOG_FILE is initialized near the top of the script (before the ERR trap)
# and is reassigned in main() with a /tmp fallback if /var/log isn't writable.

# Avoid interactive apt prompts for config files
export DEBIAN_FRONTEND=noninteractive

# --- Status & Logging Functions ---
update_status() {
    local message="$1"
    run sudo mkdir -p "$(dirname "$STATUS_FILE")"
    echo "$(date +"%Y-%m-%d %T") - $message" | run sudo tee -a "$STATUS_FILE" > /dev/null
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

# run <cmd> [args...] - execute a destructive command or, in dry-run mode,
# print what would have been executed without actually running it. The
# dry-run announcement goes to stderr so callers that redirect stdout
# (e.g. `... | run sudo tee -a FILE > /dev/null`) still surface the notice.
run() {
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${YELLOW}[DRY-RUN]${NC} $*" >&2
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
    echo "Usage: sudo ./install.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -h, --help           Show this help message"
    echo "  -v, --version        Show script version"
    echo "  -y, --yes            Skip confirmation prompts (unattended install)"
    echo "  -u, --uninstall      Uninstall the driver and DKMS entries"
    echo "  -n, --dry-run        Show what would run without making any changes"
    echo "      --log-file PATH  Write the install log to PATH (default: /var/log/rtw88-install.log)"
    echo ""
    exit 0
}

show_version() {
    echo "RTW88 Driver Installer v${SCRIPT_VERSION}"
    exit 0
}

UNATTENDED=false
UNINSTALL_MODE=false

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
        --log-file)
            if [[ -z "${2:-}" ]]; then
                echo "Error: --log-file requires a PATH argument" >&2
                exit 1
            fi
            LOG_FILE="$2"
            LOG_FILE_EXPLICIT=true
            shift 2
            ;;
        *)
            echo "Unknown option: $1" >&2
            show_help
            ;;
    esac
done


# --- Helper Functions ---
apt_update_once() {
    if [[ "$APT_UPDATE_DONE" == true ]]; then
        return 0
    fi
    run sudo apt-get update -qq 2>/dev/null || true
    APT_UPDATE_DONE=true
}

# pkg_installed <package> - returns 0 if installed, 1 otherwise.
pkg_installed() {
    local pkg="$1"
    if [[ "$DISTRO_FAMILY" == "arch" ]]; then
        pacman -Qi "$pkg" &>/dev/null
    else
        dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"
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
# to the configured repositories, 1 otherwise.
pkg_search_exact() {
    local pkg="$1"
    if [[ "$DISTRO_FAMILY" == "arch" ]]; then
        pacman -Si "$pkg" &>/dev/null
    else
        apt-cache search "^${pkg}\$" 2>/dev/null | grep -q "^${pkg} "
    fi
}

print_banner() {
    # Box is 61 columns wide overall (59-char interior between ║ borders).
    local inner=59
    local title="RTW88 WiFi 5 Driver Installer (v${SCRIPT_VERSION})"
    local subtitle="Automated DKMS setup for Linux"
    local border=""
    local i
    for ((i = 0; i < inner; i++)); do
        border+="═"
    done

    echo -e "${GREEN}"
    echo "╔${border}╗"
    printf "║%*s%s%*s║\n" \
        $(( (inner - ${#title}) / 2 )) "" \
        "$title" \
        $(( inner - ${#title} - (inner - ${#title}) / 2 )) ""
    printf "║%*s%s%*s║\n" \
        $(( (inner - ${#subtitle}) / 2 )) "" \
        "$subtitle" \
        $(( inner - ${#subtitle} - (inner - ${#subtitle}) / 2 )) ""
    echo "╚${border}╝"
    echo -e "${NC}"
}

# --- Distro Detection ---
detect_distro() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        case "$ID" in
            arch|manjaro|endeavouros|garuda|artix|cachyos)
                DISTRO_FAMILY="arch"
                ;;
            debian|ubuntu|kali|linuxmint|pop|raspbian|zorin|elementary)
                DISTRO_FAMILY="debian"
                ;;
            *)
                # Check ID_LIKE for derivatives
                if [[ "${ID_LIKE:-}" == *"arch"* ]]; then
                    DISTRO_FAMILY="arch"
                elif [[ "${ID_LIKE:-}" == *"debian"* ]] || [[ "${ID_LIKE:-}" == *"ubuntu"* ]]; then
                    DISTRO_FAMILY="debian"
                else
                    log_error "Unsupported distribution: ${ID} (${ID_LIKE:-unknown})"
                    log_error "This script supports Debian/Ubuntu-based and Arch-based distros"
                    exit 1
                fi
                ;;
        esac
    else
        # Fallback: check for package managers
        if command -v pacman &>/dev/null; then
            DISTRO_FAMILY="arch"
        elif command -v apt-get &>/dev/null; then
            DISTRO_FAMILY="debian"
        else
            log_error "Could not detect your distribution. This script supports apt and pacman-based systems."
            exit 1
        fi
    fi

    log_info "Detected distro family: ${DISTRO_FAMILY}"
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
    # Keep sudo alive; track PID so cleanup() can terminate it on exit.
    while true; do sudo -n true; sleep 50; done 2>/dev/null &
    SUDO_KEEPALIVE_PID=$!
}

check_network() {
    log_info "Checking network connectivity..."
    if command -v curl &>/dev/null; then
        if ! curl -sf --max-time 10 https://github.com > /dev/null 2>&1; then
            log_error "Cannot reach github.com. Check your internet connection."
            exit 1
        fi
    elif command -v wget &>/dev/null; then
        if ! wget -q --timeout=10 --spider https://github.com 2>/dev/null; then
            log_error "Cannot reach github.com. Check your internet connection."
            exit 1
        fi
    else
        log_warning "Cannot verify network (no curl or wget). Continuing anyway..."
        return 0
    fi
    log_success "Network connectivity OK"
}

# detect_chipset - scan for Realtek WiFi hardware via lspci/lsusb and
# report what was found. Does not abort if nothing is found; the user
# may be installing before plugging in the adapter.
detect_chipset() {
    local found_devices=()
    local supported_chipsets="(8723DE|8814AE|8821CE|8822BE|8822CE|8723DU|8811CU|8821CU|8822BU|8822CU|8811AU|8812AU|8812BU|8812CU|8814AU|8723CS|8723DS|8821CS|8822BS|8822CS)"
    local LC_ALL=C

    # Realtek PCIe vendor 10ec
    if command -v lspci &>/dev/null; then
        while IFS= read -r line; do
            [[ -n "$line" ]] && found_devices+=("$line")
        done < <(lspci -nn 2>/dev/null | grep -iE "realtek|10ec:" | grep -iE "wireless|network|wifi|${supported_chipsets}")
    fi

    # Realtek USB vendor 0bda
    if command -v lsusb &>/dev/null; then
        while IFS= read -r line; do
            [[ -n "$line" ]] && found_devices+=("$line")
        done < <(lsusb 2>/dev/null | grep -iE "realtek|0bda:" | grep -iE "wireless|network|wifi|${supported_chipsets}")
    fi

    if [[ ${#found_devices[@]} -eq 0 ]]; then
        log_warning "No Realtek WiFi adapter detected via lspci/lsusb."
        log_info "That's OK if you haven't plugged in a USB adapter yet, or if you're installing ahead of time. Continuing."
        return 1
    fi

    local noun="devices"
    [[ ${#found_devices[@]} -eq 1 ]] && noun="device"
    log_success "Detected ${#found_devices[@]} Realtek WiFi ${noun}:"
    for dev in "${found_devices[@]}"; do
        echo "  - $dev"
    done
    return 0
}

get_user_confirmation() {
    if [[ "$UNATTENDED" == true ]]; then
        return 0
    fi

    local prompt_msg="$1"
    local default="${2:-n}"

    while true; do
        if [[ "$default" == "y" ]]; then
            read -p "${prompt_msg} [Y/n]: " -r
            REPLY="${REPLY:-y}"
        else
            read -p "${prompt_msg} [y/N]: " -r
            REPLY="${REPLY:-n}"
        fi

        case "${REPLY,,}" in
            y|yes) return 0 ;;
            n|no) return 1 ;;
            *) log_warning "Invalid input. Please answer y/n" ;;
        esac
    done
}

check_secure_boot() {
    if command -v mokutil &>/dev/null; then
        if mokutil --sb-state 2>/dev/null | grep -q "SecureBoot enabled"; then
            log_warning "Secure Boot is ENABLED"
            log_info "You will need to enroll the MOK (Machine Owner Key) after installation"
            log_info "See the post-installation instructions for details"
            return 0
        fi
    fi
    log_info "Secure Boot is disabled or not detected"
    return 1
}

check_existing_driver() {
    local found_issues=false

    # Check if any rtw88 modules are loaded
    if lsmod | grep -q "^rtw_"; then
        log_warning "RTW88 driver module(s) currently loaded:"
        lsmod | grep "^rtw_" | awk '{print "  - " $1}'
        found_issues=true
    fi

    # Check DKMS installations
    if dkms status 2>/dev/null | grep -q "${DKMS_MODULE_NAME}"; then
        log_warning "DKMS installation(s) found:"
        dkms status 2>/dev/null | grep "${DKMS_MODULE_NAME}" | while read -r line; do
            log_info "  - $line"
        done
        found_issues=true
    fi

    if [[ "$found_issues" == true ]]; then
        return 0
    fi
    return 1
}

remove_existing_driver() {
    log_info "Removing existing driver installation..."

    # Unload all rtw88 modules
    if lsmod | grep -q "^rtw_"; then
        log_info "Unloading rtw88 driver modules..."
        local modules
        modules=$(lsmod | grep "^rtw_" | awk '{print $1}' | tac)

        for module in $modules; do
            log_info "  Unloading: $module"
            run sudo modprobe -r "$module" 2>/dev/null || log_warning "Could not unload $module"
        done
    fi

    # Remove all DKMS versions
    if dkms status 2>/dev/null | grep -q "${DKMS_MODULE_NAME}"; then
        log_info "Removing DKMS installation(s)..."

        dkms status 2>/dev/null | awk -F'[,/: ]' '/rtw88/ {print $1"/"$2}' | sort -u \
            | while read -r spec; do
                [[ -n "$spec" ]] || continue
                log_info "  Removing: $spec"
                run sudo dkms remove "$spec" --all 2>/dev/null || true
            done

        log_success "DKMS entries removed"
    fi

    # Clean up source directories for any rtw88-* version
    local src_dir
    for src_dir in /usr/src/${DKMS_MODULE_NAME}-*; do
        [[ -d "$src_dir" ]] || continue
        log_info "Cleaning up old source directory: $src_dir"
        run sudo rm -rf "$src_dir" 2>/dev/null || true
    done

    # Remove old config file if exists
    if [[ -f "/etc/modprobe.d/rtw88.conf" ]]; then
        log_info "Removing old configuration file..."
        run sudo rm -f /etc/modprobe.d/rtw88.conf
    fi
}

is_raspberry_pi() {
    if grep -q "^Model\s*:\s*Raspberry Pi" /proc/cpuinfo 2>/dev/null; then
        return 0
    fi
    return 1
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
        # Determine correct headers package based on kernel variant.
        # NOTE: do NOT run `pacman -Sy` standalone (partial-upgrade anti-pattern);
        # full upgrades are handled by check_updates_required().
        local headers_pkg="linux-headers"
        if [[ "$kernel_version" == *"-lts"* ]]; then
            headers_pkg="linux-lts-headers"
        elif [[ "$kernel_version" == *"-zen"* ]]; then
            headers_pkg="linux-zen-headers"
        elif [[ "$kernel_version" == *"-hardened"* ]]; then
            headers_pkg="linux-hardened-headers"
        fi

        log_info "Installing ${headers_pkg}..."
        if pkg_install "$headers_pkg"; then
            log_success "Kernel headers installed"
            return 0
        fi

        log_error "Could not install kernel headers"
        log_error "Try: sudo pacman -S ${headers_pkg}"
        return 1
    fi

    # Debian-based path

    # Try Raspberry Pi headers if on RPi
    if is_raspberry_pi; then
        log_info "Raspberry Pi detected, installing raspberrypi-kernel-headers..."
        if pkg_install raspberrypi-kernel-headers build-essential; then
            log_success "Raspberry Pi kernel headers installed"
            return 0
        fi
    fi

    # Try the exact headers package matching the running kernel
    local headers_pkg="linux-headers-${kernel_version}"
    if pkg_search_exact "$headers_pkg"; then
        if pkg_install "$headers_pkg"; then
            log_success "Kernel headers installed"
            return 0
        fi
    fi

    # Fall back to the generic metapackage
    if pkg_install linux-headers-generic; then
        log_success "Generic kernel headers installed"
        return 0
    fi

    log_error "Could not install kernel headers"
    log_error "Please install kernel headers manually for your distribution"
    return 1
}

check_updates_required() {
    log_info "Checking for system updates..."

    if [[ "$DISTRO_FAMILY" == "arch" ]]; then
        # On Arch, check if any packages are outdated
        local outdated
        outdated=$(pacman -Qu 2>/dev/null | wc -l || echo "0")
        if [[ "$outdated" -gt 0 ]]; then
            log_warning "System has ${outdated} packages to upgrade"
            return 0
        fi
        log_success "System is up to date"
        return 1
    fi

    # Debian-based path
    apt_update_once

    local upgradable
    upgradable=$(apt-get -s upgrade 2>/dev/null | grep -c "^Inst " || true)

    if [[ $upgradable -gt 0 ]]; then
        log_warning "System has ${upgradable} packages to upgrade"
        return 0
    fi

    log_success "System is up to date"
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

    local missing_packages=()
    for pkg in "${packages[@]}"; do
        local probe="$pkg"
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

clone_repository() {
    if [[ -d "$REPO_DIR" ]]; then
        log_warning "Repository directory already exists"
        if get_user_confirmation "Remove and re-clone?"; then
            run rm -rf "$REPO_DIR"
        else
            return 1
        fi
    fi

    log_info "Cloning rtw88 driver repository..."
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${YELLOW}[DRY-RUN]${NC} git clone --depth 1 ${REPO_URL} ${REPO_DIR}"
        log_info "Skipping DKMS version detection in dry-run (no source tree to read)."
        return 0
    fi

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
    parsed=$(grep -E '^[[:space:]]*PACKAGE_VERSION[[:space:]]*=' "$dkms_conf" \
        | head -n 1 \
        | sed -E 's/^[[:space:]]*PACKAGE_VERSION[[:space:]]*=[[:space:]]*//; s/[[:space:]]*#.*$//' \
        | sed -E 's/^["'\'']//; s/["'\'']$//' \
        | tr -d '[:space:]')

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
        echo -e "${YELLOW}[DRY-RUN]${NC} cd ${REPO_DIR}"
        echo -e "${YELLOW}[DRY-RUN]${NC} sudo dkms install \$PWD"
        echo -e "${YELLOW}[DRY-RUN]${NC} sudo make install_fw"
        echo -e "${YELLOW}[DRY-RUN]${NC} sudo cp rtw88.conf /etc/modprobe.d/"
        return 0
    fi

    cd "$REPO_DIR" || { log_error "Failed to enter repository directory"; return 1; }

    # Install via DKMS
    if sudo dkms install "$PWD" 2>&1; then
        log_success "Driver built and installed via DKMS"
    else
        log_error "DKMS build failed. Check the build log at /var/lib/dkms/${DKMS_MODULE_NAME}/${DKMS_VERSION}/build/make.log for compiler errors."
        return 1
    fi

    # Install firmware
    log_info "Installing firmware..."
    if sudo make install_fw 2>&1; then
        log_success "Firmware installed"
    else
        log_warning "Firmware install reported errors. Usually harmless - if WiFi doesn't work after reboot, check 'dmesg | grep rtw' for missing firmware messages."
    fi

    # Copy configuration file
    log_info "Installing configuration file..."
    if sudo cp rtw88.conf /etc/modprobe.d/ 2>&1; then
        log_success "Configuration file installed"
    else
        log_warning "Could not install configuration file"
    fi

    cd - > /dev/null
}

verify_installation() {
    log_info "Verifying installation..."

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${YELLOW}[DRY-RUN]${NC} Would verify DKMS module registration and /etc/modprobe.d/rtw88.conf"
        return 0
    fi

    if dkms status 2>/dev/null | grep -q "${DKMS_MODULE_NAME}.*installed"; then
        log_success "DKMS module registered and installed:"
        dkms status 2>/dev/null | grep "${DKMS_MODULE_NAME}"
    else
        log_error "DKMS module not properly installed"
        return 1
    fi

    if [[ -f /etc/modprobe.d/rtw88.conf ]]; then
        log_success "Configuration file present"
    else
        log_warning "Configuration file not found"
    fi

    return 0
}

show_post_install_instructions() {
    echo ""
    log_success "Installation completed successfully!"
    echo ""
    log_info "═══════════════════════════════════════════════════════════"
    log_info "NEXT STEPS"
    log_info "═══════════════════════════════════════════════════════════"

    # Check if Secure Boot is enabled
    if command -v mokutil &>/dev/null && mokutil --sb-state 2>/dev/null | grep -q "SecureBoot enabled"; then
        echo ""
        log_warning "Secure Boot is enabled - you need to enroll a Machine Owner Key (MOK)"
        echo ""
        log_info "1. Import the MOK key:"
        echo ""

        # Detect Ubuntu vs other distros
        if [[ -f /var/lib/shim-signed/mok/MOK.der ]]; then
            log_info "   Ubuntu/Debian-based systems:"
            echo "   ${YELLOW}sudo mokutil --import /var/lib/shim-signed/mok/MOK.der${NC}"
        else
            log_info "   Other systems:"
            echo "   ${YELLOW}sudo mokutil --import /var/lib/dkms/mok.pub${NC}"
        fi

        echo ""
        log_info "2. You will be asked to set a one-time password. Remember it for the next step."
        log_info "3. Reboot your system."
        log_info "4. A blue MOK Manager screen will appear during boot."
        log_info "5. Select 'Enroll MOK' > Continue > enter the password from step 2."
        log_info "6. Reboot once more to finish."
        echo ""
    fi

    echo ""
    log_info "After rebooting:"
    log_info "  1. Your WiFi adapter should work automatically."
    log_info "  2. Verify the driver loaded: ${YELLOW}lsmod | grep rtw${NC}"
    log_info "  3. Check your interfaces:    ${YELLOW}ip link show${NC}"
    log_info "  4. Look for wlan0, wlp*, or similar."
    echo ""
    log_info "═══════════════════════════════════════════════════════════"
    log_info "Supported Chipsets:"
    log_info "  PCIe: RTL8723DE, RTL8814AE, RTL8821CE, RTL8822BE, RTL8822CE"
    log_info "  USB:  RTL8723DU, RTL8811CU, RTL8821CU, RTL8822BU, RTL8822CU"
    log_info "        RTL8811AU, RTL8812AU, RTL8812BU, RTL8812CU, RTL8814AU"
    log_info "  SDIO: RTL8723CS, RTL8723DS, RTL8821CS, RTL8822BS, RTL8822CS"
    log_info "═══════════════════════════════════════════════════════════"
    echo ""

    log_info "To uninstall later, re-run this script with the -u flag:"
    log_info "  ${YELLOW}./install.sh -u${NC}"
    echo ""
}

cleanup() {
    # Stop the sudo keepalive loop if we started one.
    if [[ -n "${SUDO_KEEPALIVE_PID:-}" ]] && kill -0 "$SUDO_KEEPALIVE_PID" 2>/dev/null; then
        kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
        wait "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
        SUDO_KEEPALIVE_PID=""
    fi

    if [[ "$CLEANUP_ON_EXIT" == true ]] && [[ -d "$REPO_DIR" ]]; then
        log_info "Cleaning up repository..."
        run rm -rf "$REPO_DIR"
    fi
}

# --- Main Execution ---
trap cleanup EXIT INT TERM


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
        # Set up log file mirror; fall back to /tmp if the requested path isn't writable.
        if ! sudo touch "$LOG_FILE" 2>/dev/null; then
            local fallback_log="/tmp/rtw88-install-$$.log"
            if [[ "$LOG_FILE_EXPLICIT" == true ]]; then
                log_warning "Could not write to user-specified log file (${LOG_FILE}). Falling back to ${fallback_log}."
            fi
            LOG_FILE="$fallback_log"
            : > "$LOG_FILE" 2>/dev/null || true
        fi
        sudo chmod 0644 "$LOG_FILE" 2>/dev/null || true
        # Mirror all output to $LOG_FILE while still showing colors on the terminal.
        # `stdbuf -oL` keeps tee line-buffered so `read -p` prompts flush immediately.
        exec > >(stdbuf -oL sudo tee -a "$LOG_FILE") 2>&1
        log_info "Saving a full log to: $LOG_FILE (useful if something fails)"
    fi

    if [[ "$UNINSTALL_MODE" == true ]]; then
        detect_distro
        log_warning "Uninstall mode selected"
        if get_user_confirmation "Are you sure you want to uninstall the RTW88 driver?"; then
            remove_existing_driver
            log_success "Uninstallation complete"
            exit 0
        else
            log_info "Uninstallation cancelled"
            exit 0
        fi
    fi

    step_begin "Detecting your Linux distribution"
    detect_distro

    step_begin "Detecting Realtek hardware"
    detect_chipset || true

    # Check Secure Boot status
    local secure_boot_enabled=false
    if check_secure_boot; then
        secure_boot_enabled=true
    fi

    if ! get_user_confirmation "Ready to proceed with RTW88 driver installation?"; then
        update_status "Installation cancelled by user"
        log_info "Installation cancelled"
        exit 0
    fi

    step_begin "Checking network"
    check_network

    step_begin "Checking for existing driver"
    if check_existing_driver; then
        if get_user_confirmation "Existing driver installation found. Remove and reinstall?" "y"; then
            update_status "Removing existing driver"
            remove_existing_driver
            log_success "Existing driver removed"
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
        log_error "Cannot continue without kernel headers. Install them manually and re-run."
        exit 1
    fi

    # System updates (inline - not a labeled step, optional per user)
    if check_updates_required; then
        if get_user_confirmation "Install system updates before driver installation?" "y"; then
            update_status "Installing system updates"
            log_info "Upgrading system packages..."
            if [[ "$DISTRO_FAMILY" == "arch" ]]; then
                run sudo pacman -Syu --noconfirm
            else
                run sudo apt-get upgrade -y
            fi
            log_success "System updated"

            if [[ -f /var/run/reboot-required ]]; then
                log_warning "System reboot required after updates"
                if get_user_confirmation "Reboot now and run script again after reboot?"; then
                    update_status "Rebooting for system updates"
                    run sudo reboot
                else
                    log_error "A reboot is required before the driver can be built. Reboot manually, then re-run this script."
                    exit 1
                fi
            fi
        fi
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
    update_status "Installing driver via DKMS"
    if ! install_driver_via_dkms; then
        update_status "Driver installation failed"
        log_error "Driver installation failed"
        exit 1
    fi

    step_begin "Verifying installation"
    update_status "Verifying installation"
    if ! verify_installation; then
        log_warning "Installation verification reported issues. The driver may still work - reboot and check 'lsmod | grep rtw'. If WiFi doesn't come up, re-run with -u to uninstall and try again."
    fi

    # Keep repo option
    if get_user_confirmation "Keep source repository for future updates/uninstall?"; then
        CLEANUP_ON_EXIT=false
        log_info "Repository kept at: $(pwd)/$REPO_DIR"
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
        run sudo reboot
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
