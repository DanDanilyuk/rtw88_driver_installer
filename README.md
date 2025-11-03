# RTW88 WiFi Driver Installer

Automated installation script for Realtek RTW88 WiFi 5 drivers on Linux systems with DKMS support.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## 🚀 Quick Install

Run this command in your terminal:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/DanDanilyuk/rtw88_driver_installer/main/install.sh)"
```

## 📋 Features

- **DKMS Support** - Automatic driver rebuilds on kernel updates
- **Secure Boot Ready** - Includes MOK enrollment instructions
- **Multi-Distribution** - Works on Ubuntu, Debian, Kali, Raspberry Pi OS, and Arch-based distros
- **Automatic Dependency Resolution** - Installs all required packages
- **Smart Kernel Header Detection** - Finds and installs correct headers for your system
- **Raspberry Pi Optimized** - Automatic ARM/ARM64 configuration
- **Existing Driver Cleanup** - Detects and removes conflicting installations

## 🖥️ Supported Hardware

### PCIe Cards

- RTL8723DE, RTL8814AE, RTL8821CE, RTL8822BE, RTL8822CE

### USB Adapters

- RTL8723DU, RTL8811AU, RTL8811CU, RTL8812AU, RTL8812BU, RTL8812CU
- RTL8814AU, RTL8821AU, RTL8821CU, RTL8822BU, RTL8822CU

### SDIO Cards

- RTL8723CS, RTL8723DS, RTL8821CS, RTL8822BS, RTL8822CS

## 💻 Compatible Distributions

- **Ubuntu / Debian** - 20.04+, including Linux Mint and Pop!\_OS
- **Kali Linux** - Rolling release and stable versions
- **Raspberry Pi OS** - Both 32-bit and 64-bit
- **Arch-based** - Arch Linux, Manjaro, EndeavourOS

**Note:** Compatible with Linux kernel versions 5.4 and newer. RHEL-based distros may have compatibility issues due to modified kernel APIs.

## 📦 What Gets Installed

- **Driver Source:** [lwfinger/rtw88](https://github.com/lwfinger/rtw88) - Official backport of Realtek WiFi 5 drivers
- **Installation Method:** DKMS (Dynamic Kernel Module Support)
- **Dependencies:** build-essential, dkms, git, kernel headers
- **Configuration:** Firmware files and modprobe configuration

## 🔧 Installation Process

The script performs the following steps:

1. **Pre-flight Checks**

   - Verifies non-root execution
   - Checks for Secure Boot status
   - Detects existing driver installations

2. **System Preparation**

   - Installs kernel headers for your current kernel
   - Installs required build tools and dependencies
   - Optional system updates

3. **Driver Installation**

   - Clones the rtw88 driver repository
   - Builds and installs via DKMS
   - Installs firmware files
   - Configures modprobe settings

4. **Verification**
   - Confirms DKMS module registration
   - Verifies configuration files
   - Provides post-installation instructions

## 🔐 Secure Boot

If Secure Boot is enabled on your system, you'll need to enroll the MOK (Machine Owner Key) after installation:

### Ubuntu/Debian-based systems:

```bash
sudo mokutil --import /var/lib/shim-signed/mok/MOK.der
```

### Other distributions:

```bash
sudo mokutil --import /var/lib/dkms/mok.pub
```

### MOK Enrollment Steps:

1. Run the mokutil command above
2. Create a password when prompted (remember it!)
3. Reboot your system
4. During boot, MOK Manager will appear (blue screen)
5. Select "Enroll MOK" → Continue
6. Enter the password you created
7. Reboot again

## ✅ Post-Installation

After installation and reboot:

1. **Verify Driver is Loaded**

   ```bash
   lsmod | grep rtw
   ```

2. **Check WiFi Interfaces**

   ```bash
   ip link show
   ```

   Your adapter should appear (usually `wlan0` or `wlp*`)

3. **Test Connection**
   Use your distribution's network manager to connect to WiFi

## 🗑️ Uninstallation

To remove the driver:

```bash
sudo dkms remove rtw88/0.6 --all
sudo rm -rf /usr/src/rtw88-0.6
sudo rm /etc/modprobe.d/rtw88.conf
```

Then reboot your system.

## 🐛 Troubleshooting

### Driver not loading after installation

1. Ensure you've rebooted after installation
2. If Secure Boot is enabled, verify MOK enrollment completed successfully
3. Check kernel logs: `dmesg | grep rtw`

### Kernel headers not found

The script attempts to install headers automatically. If it fails:

- **Ubuntu/Debian:** `sudo apt-get install linux-headers-$(uname -r)`
- **Raspberry Pi:** `sudo apt-get install raspberrypi-kernel-headers`
- **Arch:** `sudo pacman -S linux-headers`

### WiFi adapter not detected

1. Verify adapter is connected: `lsusb` or `lspci`
2. Check if adapter chipset is supported (see hardware list above)
3. Ensure adapter is RTW88-based (not RTL88x2bu or other variants)

### Conflicts with existing drivers

The script automatically detects and offers to remove conflicting drivers. If issues persist:

1. Manually unload conflicting modules
2. Check `/etc/modprobe.d/` for blacklist conflicts
3. Re-run the installation script

## 📚 Additional Resources

- **Driver Source:** [lwfinger/rtw88](https://github.com/lwfinger/rtw88)
- **Installation Page:** [GitHub Pages](https://dandanilyuk.github.io/rtw88_driver_installer/)
- **Report Issues:** [GitHub Issues](https://github.com/DanDanilyuk/rtw88_driver_installer/issues)

## 🤝 Contributing

Contributions are welcome! Please feel free to submit pull requests or open issues for:

- Bug fixes
- Distribution-specific improvements
- Documentation updates
- New feature additions

## 📄 License

This installation script is released under the MIT License. The RTW88 driver itself is licensed under GPL-2.0.

## 🙏 Credits

- **Driver Development:** [lwfinger](https://github.com/lwfinger) and the RTW88 contributors
- **Original Realtek Drivers:** Realtek Semiconductor Corp.
- **Installation Script:** [Dan Danilyuk](https://www.dandanilyuk.com/)

## ⚠️ Disclaimer

This script is provided "as is" without warranty. Always backup important data before installing drivers or modifying system configurations. The author is not responsible for any damage or data loss.

---

**Made by [Dan Danilyuk](https://www.dandanilyuk.com/)** | [View Source Code](https://github.com/DanDanilyuk/rtw88_driver_installer)
