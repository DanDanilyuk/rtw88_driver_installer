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
- **Existing Driver Cleanup** - Detects and removes all registered `rtw88` DKMS versions before reinstalling
- **Pre-flight Chipset Detection** - Scans `lspci` and `lsusb` for Realtek adapters and reports what it finds before installing
- **Dry-run Mode** - Preview every action without touching the system (`--dry-run` / `-n`)
- **Detailed Logging** - Every step is teed to `/var/log/rtw88-install.log` (or `--log-file PATH`) for easy debugging
- **Concurrent-Run Protection** - A lock file prevents two installers from racing each other

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

The script walks through nine numbered steps, prefixed in output as `[N/9]`:

1. **Detecting your Linux distribution** - Identifies the package manager family (apt or pacman)
2. **Detecting Realtek hardware** - Scans `lspci` and `lsusb` for supported chipsets (warns but does not abort if none are found)
3. **Checking network** - Verifies connectivity to github.com
4. **Checking for existing driver** - Removes every registered `rtw88` DKMS version and its source tree
5. **Installing kernel headers** - Picks the right headers package for your kernel variant (standard, -lts, -zen, -hardened, raspberrypi)
6. **Installing packages** - Installs `dkms`, `git`, and build tools (`build-essential` or `base-devel`)
7. **Cloning driver repository** - Shallow-clones `lwfinger/rtw88` and auto-detects `PACKAGE_VERSION` from its `dkms.conf`
8. **Compiling driver with DKMS** - Builds, installs firmware, and writes the modprobe config
9. **Verifying installation** - Confirms the DKMS module is registered and the config file is in place

Pre-flight: the script also acquires `/var/lock/rtw88-install.lock` via `flock`, sets up `/var/log/rtw88-install.log` (falling back to `/tmp` if the system log directory is not writable), and runs a keepalive loop so it does not re-prompt for sudo during long builds.

## 🎛️ Command-Line Options

```
-h, --help           Show this help message
-v, --version        Show script version
-y, --yes            Skip confirmation prompts (unattended install)
-u, --uninstall      Uninstall the driver and DKMS entries
-n, --dry-run        Show what would run without making any changes
    --log-file PATH  Write the install log to PATH (default: /var/log/rtw88-install.log)
```

`--dry-run` is useful for auditing the script before running it as root - every destructive command is printed with a `[DRY-RUN]` prefix instead of executing. Combine with `--yes` to preview a non-interactive install end-to-end.

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

Re-run the installer with `-u`:

```bash
curl -fsSL https://raw.githubusercontent.com/DanDanilyuk/rtw88_driver_installer/main/install.sh | sudo bash -s -- -u
```

Or, if you kept a local copy of the script:

```bash
sudo ./install.sh -u
```

This removes every registered `rtw88` DKMS version (not just the one this run installed), cleans up `/usr/src/rtw88-*`, and deletes the modprobe config. Then reboot.

## 🐛 Troubleshooting

The full install log lives at `/var/log/rtw88-install.log` (or wherever `--log-file` pointed). That is the first place to look when something goes wrong - errors from `apt`/`pacman`, the DKMS build, and every prompt are captured there.

### Driver not loading after installation

1. Ensure you've rebooted after installation
2. If Secure Boot is enabled, verify MOK enrollment completed successfully
3. Check kernel logs: `dmesg | grep rtw`
4. Check the DKMS build log: `/var/lib/dkms/rtw88/<version>/build/make.log`

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
