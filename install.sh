#!/bin/bash
set -euo pipefail

# RTW88 Driver Installation Script
# Installs Realtek WiFi 5 drivers (rtw88) with DKMS support
# Supports: RTL8723DE, RTL8821CE, RTL8822BE, RTL8822CE, RTL8723DU, RTL8811CU, RTL8821CU, RTL8822BU, RTL8822CU, and more
# Compatible with: Debian, Ubuntu, Kali Linux, Raspberry Pi OS, Arch-based distros

# Configuration
readonly REPO_URL="https://github.com/lwfinger/rtw88.git"
readonly REPO_DIR="rtw88"
readonly DKMS_MODULE_NAME="rtw88"
readonly DKMS_VERSION="0.6"
readonly STATUS_FILE="/var/lib/driver_install/status.flag"

# Required packages (kernel headers determined dynamically)
REQUIRED_PACKAGES=("dkms" "git" "build-essential")

# Color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# State tracking
CLEANUP_ON_EXIT=true

# CLI Arguments
show_help() {
    echo "Usage: sudo ./install.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -h, --help         Show this help message"
    echo "  -y, --yes          Skip confirmation prompts (unattended install)"
    echo "  -u, --uninstall    Uninstall the driver and DKMS entries"
    echo ""
    exit 0
}

UNATTENDED=false
UNINSTALL_MODE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            ;;
        -y|--yes)
            UNATTENDED=true
            shift
            ;;
        -u|--uninstall)
            UNINSTALL_MODE=true
            shift
            ;;
        *)
            log_error "Unknown option: $1"
            show_help
            ;;
    esac
done


# --- Status & Logging Functions ---
update_status() {
    local message="$1"
    sudo mkdir -p "$(dirname "$STATUS_FILE")"
    echo "$(date +"%Y-%m-%d %T") - $message" | sudo tee -a "$STATUS_FILE" > /dev/null
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

# --- Helper Functions ---
# Spinner for long running operations
spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf ""
    done
    printf "    "
}

print_banner() {
    echo -e "${GREEN}"
    echo "╔═══════════════════════════════════════════════════════════╗"
    echo "║          RTW88 WiFi 5 Driver Installation Script         ║"
    echo "║                    DKMS Installation                      ║"
    echo "╚═══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

check_root() {
    if [[ $EUID -eq 0 ]]; then
        log_error "This script should NOT be run as root"
        log_info "It will request sudo when needed"
        exit 1
    fi
}

check_sudo() {
    if ! sudo -n true 2>/dev/null; then
        log_info "This script requires sudo privileges"
        sudo -v || { log_error "Failed to obtain sudo privileges"; exit 1; }
    fi
    # Keep sudo alive
    while true; do sudo -n true; sleep 50; done 2>/dev/null &
}


get_user_confirmation() {
    if [ "$UNATTENDED" = true ]; then
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
            sudo modprobe -r "$module" 2>/dev/null || log_warning "Could not unload $module"
        done
    fi
    
    # Remove all DKMS versions
    if dkms status 2>/dev/null | grep -q "${DKMS_MODULE_NAME}"; then
        log_info "Removing DKMS installation(s)..."
        
        # Remove rtw88 from DKMS
        sudo dkms remove "${DKMS_MODULE_NAME}/${DKMS_VERSION}" --all 2>/dev/null || true
        
        log_success "DKMS entries removed"
    fi
    
    # Clean up source directories
    if [[ -d "/usr/src/${DKMS_MODULE_NAME}-${DKMS_VERSION}" ]]; then
        log_info "Cleaning up old source directory..."
        sudo rm -rf "/usr/src/${DKMS_MODULE_NAME}-${DKMS_VERSION}" 2>/dev/null || true
    fi
    
    # Remove old config file if exists
    if [[ -f "/etc/modprobe.d/rtw88.conf" ]]; then
        log_info "Removing old configuration file..."
        sudo rm -f /etc/modprobe.d/rtw88.conf
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
    
    # Update package cache
    sudo apt-get update -qq 2>/dev/null || true
    
    # Try Raspberry Pi headers if on RPi
    if is_raspberry_pi; then
        log_info "Raspberry Pi detected, installing raspberrypi-kernel-headers..."
        if sudo apt-get install -y raspberrypi-kernel-headers build-essential 2>/dev/null; then
            log_success "Raspberry Pi kernel headers installed"
            return 0
        fi
    fi
    
    # Try standard headers packages based on distro
    local headers_pkg="linux-headers-${kernel_version}"
    
    if apt-cache search "^${headers_pkg}$" 2>/dev/null | grep -q "$headers_pkg"; then
        if sudo apt-get install -y "$headers_pkg" 2>/dev/null; then
            log_success "Kernel headers installed"
            return 0
        fi
    fi
    
    # Try generic headers as fallback
    if sudo apt-get install -y linux-headers-generic 2>/dev/null; then
        log_success "Generic kernel headers installed"
        return 0
    fi
    
    log_error "Could not install kernel headers"
    log_error "Please install kernel headers manually for your distribution"
    return 1
}

check_updates_required() {
    log_info "Checking for system updates..."
    sudo apt-get update -qq 2>/dev/null || true
    
    local upgradable
    upgradable=$(apt list --upgradable 2>/dev/null | grep -c "upgradable" || true)
    
    if [[ $upgradable -gt 1 ]]; then
        log_warning "System has $((upgradable - 1)) packages to upgrade"
        return 0
    fi
    
    log_success "System is up to date"
    return 1
}

install_packages() {
    log_info "Installing required packages..."
    
    local missing_packages=()
    for pkg in "${REQUIRED_PACKAGES[@]}"; do
        if ! dpkg -l "$pkg" 2>/dev/null | grep -q "^ii"; then
            missing_packages+=("$pkg")
        fi
    done
    
    if [[ ${#missing_packages[@]} -eq 0 ]]; then
        log_success "All required packages already installed"
        return 0
    fi
    
    log_info "Installing: ${missing_packages[*]}"
    if sudo apt-get install -y "${missing_packages[@]}" 2>/dev/null; then
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
            rm -rf "$REPO_DIR"
        else
            return 1
        fi
    fi
    
    log_info "Cloning rtw88 driver repository..."
    if git clone "$REPO_URL" "$REPO_DIR" 2>/dev/null; then
        log_success "Repository cloned successfully"
        return 0
    else
        log_error "Failed to clone repository"
        return 1
    fi
}

install_driver_via_dkms() {
    log_info "Installing rtw88 driver via DKMS..."
    log_info "  Kernel: $(uname -r)"
    log_info "  Architecture: $(uname -m)"
    
    cd "$REPO_DIR" || { log_error "Failed to enter repository directory"; return 1; }
    
    # Install via DKMS
    if sudo dkms install "$PWD" 2>&1; then
        log_success "Driver built and installed via DKMS"
    else
        log_error "DKMS installation failed"
        return 1
    fi
    
    # Install firmware
    log_info "Installing firmware..."
    if sudo make install_fw 2>&1; then
        log_success "Firmware installed"
    else
        log_warning "Firmware installation had issues (may not be critical)"
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
    log_info "NEXT STEPS:"
    log_info "═══════════════════════════════════════════════════════════"
    
    # Check if Secure Boot is enabled
    if command -v mokutil &>/dev/null && mokutil --sb-state 2>/dev/null | grep -q "SecureBoot enabled"; then
        echo ""
        log_warning "SECURE BOOT IS ENABLED - MOK Enrollment Required!"
        echo ""
        log_info "1. Enroll the Machine Owner Key (MOK):"
        echo ""
        
        # Detect Ubuntu vs other distros
        if [[ -f /var/lib/shim-signed/mok/MOK.der ]]; then
            log_info "   For Ubuntu/Debian-based systems:"
            echo "   ${YELLOW}sudo mokutil --import /var/lib/shim-signed/mok/MOK.der${NC}"
        else
            log_info "   For most other systems:"
            echo "   ${YELLOW}sudo mokutil --import /var/lib/dkms/mok.pub${NC}"
        fi
        
        echo ""
        log_info "2. You will be asked to create a password - remember it!"
        log_info "3. REBOOT your system"
        log_info "4. During boot, a blue MOK Manager screen will appear"
        log_info "5. Select 'Enroll MOK' → Continue → Enter the password you created"
        log_info "6. Reboot again"
        echo ""
    fi
    
    echo ""
    log_info "After reboot (or if Secure Boot is disabled):"
    log_info "  1. Your WiFi adapter should work automatically"
    log_info "  2. Check loaded modules: ${YELLOW}lsmod | grep rtw${NC}"
    log_info "  3. Check WiFi interfaces: ${YELLOW}ip link show${NC}"
    log_info "  4. Your adapter should appear (usually wlan0 or wlp*)"
    echo ""
    log_info "═══════════════════════════════════════════════════════════"
    log_info "Supported Chipsets:"
    log_info "  PCIe: RTL8723DE, RTL8814AE, RTL8821CE, RTL8822BE, RTL8822CE"
    log_info "  USB:  RTL8723DU, RTL8811CU, RTL8821CU, RTL8822BU, RTL8822CU"
    log_info "        RTL8811AU, RTL8812AU, RTL8812BU, RTL8812CU, RTL8814AU"
    log_info "  SDIO: RTL8723CS, RTL8723DS, RTL8821CS, RTL8822BS, RTL8822CS"
    log_info "═══════════════════════════════════════════════════════════"
    echo ""
    
    if [[ -d "$REPO_DIR" ]]; then
        log_info "To uninstall:"
        log_info "  ${YELLOW}sudo dkms remove rtw88/0.6 --all${NC}"
        log_info "  ${YELLOW}sudo rm -rf /usr/src/rtw88-0.6${NC}"
        log_info "  ${YELLOW}sudo rm /etc/modprobe.d/rtw88.conf${NC}"
    fi
    echo ""
}

cleanup() {
    if [[ "$CLEANUP_ON_EXIT" == true ]] && [[ -d "$REPO_DIR" ]]; then
        log_info "Cleaning up repository..."
        rm -rf "$REPO_DIR"
    fi
}

# --- Main Execution ---
trap cleanup EXIT


main() {
    print_banner
    check_root
    check_sudo

    if [ "$UNINSTALL_MODE" = true ]; then
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
    
    # Check for existing driver and remove if found
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
    fi
    
    # Check and install kernel headers
    update_status "Checking kernel headers"
    if ! check_and_install_kernel_headers; then
        update_status "Kernel headers installation failed"
        log_error "Cannot proceed without kernel headers"
        exit 1
    fi
    
    # System updates
    if check_updates_required; then
        if get_user_confirmation "Install system updates before driver installation?" "y"; then
            update_status "Installing system updates"
            log_info "Upgrading system packages..."
            sudo apt-get upgrade -y
            log_success "System updated"
            
            if [[ -f /var/run/reboot-required ]]; then
                log_warning "System reboot required after updates"
                if get_user_confirmation "Reboot now and run script again after reboot?"; then
                    update_status "Rebooting for system updates"
                    sudo reboot
                else
                    log_error "Reboot required before continuing"
                    exit 1
                fi
            fi
        fi
    fi
    
    # Install packages
    update_status "Installing required packages"
    if ! install_packages; then
        update_status "Package installation failed"
        log_error "Failed to install required packages"
        exit 1
    fi
    
    # Clone repository
    update_status "Cloning driver repository"
    if ! clone_repository; then
        update_status "Repository clone failed"
        log_error "Failed to clone repository"
        exit 1
    fi
    
    # Install driver via DKMS
    update_status "Installing driver via DKMS"
    if ! install_driver_via_dkms; then
        update_status "Driver installation failed"
        log_error "Driver installation failed"
        exit 1
    fi
    
    # Verify
    update_status "Verifying installation"
    if ! verify_installation; then
        log_warning "Installation verification had issues"
    fi
    
    # Keep repo option
    if get_user_confirmation "Keep source repository for future updates/uninstall?"; then
        CLEANUP_ON_EXIT=false
        log_info "Repository kept at: $(pwd)/$REPO_DIR"
    fi
    
    update_status "Installation complete"
    
    # Show post-installation instructions
    show_post_install_instructions
    
    # Reboot prompt
    if get_user_confirmation "Reboot now to complete installation?" "y"; then
        update_status "Rebooting after successful installation"
        sudo reboot
    else
        update_status "Installation complete - manual reboot pending"
        log_warning "Please reboot to complete the installation"
    fi
}

# Run main function
main "$@"
