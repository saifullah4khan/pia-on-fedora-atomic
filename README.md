# PIA on Fedora Atomic

[![lint](https://github.com/saifullah4khan/pia-on-fedora-atomic/actions/workflows/lint.yml/badge.svg)](https://github.com/saifullah4khan/pia-on-fedora-atomic/actions/workflows/lint.yml)
[![version](https://img.shields.io/badge/version-1.1.0-informational)](CHANGELOG.md)
[![license](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

Install the full **Private Internet Access desktop client** on Bazzite and compatible Fedora Atomic desktops.

PIA's Linux installer copies most of the application successfully, then aborts when it tries to write its icon into the immutable `/usr` directory. Everything the installer would have done after that point never happens. This project finishes the job using writable locations.

> [!IMPORTANT]
> This is an unofficial community workaround. It is not affiliated with or supported by Private Internet Access, Fedora, Universal Blue, or Bazzite.

## Quick start

```bash
git clone https://github.com/saifullah4khan/pia-on-fedora-atomic.git
cd pia-on-fedora-atomic
chmod +x install.sh install-stage1.sh install-stage2.sh uninstall.sh
./install.sh
```

If it layers packages, reboot with `systemctl reboot`, then run `./install.sh` again from the same directory. It picks up where it left off.

When it finishes:

```bash
./install.sh --verify
```

## Contents

- [What this actually does](#what-this-actually-does)
- [Tested configuration](#tested-configuration)
- [What this preserves](#what-this-preserves)
- [Why the normal installer fails](#why-the-normal-installer-fails)
- [Before installing](#before-installing)
- [Installation options](#installation-options)
- [Verifying the installation](#verifying-the-installation)
- [Fully manual installation](#fully-manual-installation)
- [Using a specific PIA installer](#using-a-specific-pia-installer)
- [Troubleshooting](#troubleshooting)
- [Updating PIA](#updating-pia)
- [Uninstallation](#uninstallation)
- [Security notes](#security-notes)
- [Compatibility reports](#compatibility-reports)
- [Sources and credit](#sources-and-credit)

## What this actually does

PIA's installer stops at the icon copy. Four things it would have done next are handled here instead:

| Step | Where PIA puts it | Where this project puts it |
| --- | --- | --- |
| Daemon service | `/etc/systemd/system/piavpn.service` | `/etc/systemd/system/pia-vpn.service` |
| Application launcher | `/usr/share/applications` (read-only) | `~/.local/share/applications` |
| Application icon | `/usr/share/pixmaps` (read-only) | `~/.local/share/icons/hicolor` |
| WireGuard DNS rule | `/etc/NetworkManager/conf.d/wgpia.conf` | Same path, which is writable |
| `piactl` on your PATH | `/usr/local/bin/piactl` | Same path, which is writable |

The NetworkManager rule matters more than it looks. Without it, NetworkManager can take over PIA's `wgpia0` interface and discard the DNS settings PIA applied to it when you switch between wifi and ethernet, or move to a different network. Version 1.0 of this project did not create it, so if you installed before September 2026, rerun `./install.sh --stage2` to pick it up.

## Tested configuration

- **Distribution:** Bazzite KDE
- **Architecture:** x86_64
- **PIA client:** 3.7.2, still the current stable release
- **Tested:** July 25, 2026, in continuous use since
- **Confirmed:** Native PIA interface, full server picker, WireGuard, kill switch, and Shadowsocks multi-hop

Other Fedora Atomic desktops may work, because they use the same rpm-ostree and immutable `/usr` model. Treat them as unverified until somebody reports a successful test. [Reports are welcome.](#compatibility-reports)

## What this preserves

Because this installs the native PIA desktop client rather than importing individual OpenVPN profiles, you keep PIA's normal server browser and client-side settings.

Feature availability can change between PIA releases. Shadowsocks multi-hop obfuscates the connection between your device and PIA, but it does **not** guarantee that websites cannot identify the final PIA exit IP as a VPN address.

## Why the normal installer fails

PIA's installer writes the application under `/opt/piavpn`. On Fedora Atomic systems `/opt` resolves into writable `/var` storage, so the application itself is extracted successfully.

The installer then runs this, roughly in this order:

```text
1. create the piavpn and piahnsd groups          works
2. copy the application into /opt/piavpn         works
3. copy the icon into /usr/share/pixmaps         FAILS, read-only
4. copy the launcher into /usr/share/applications  never runs
5. write /etc/NetworkManager/conf.d/wgpia.conf     never runs
6. link piactl into /usr/local/bin                 never runs
7. install and start the systemd service           never runs
```

PIA's installer runs under `set -e`, so step 3 ends it. The error you see looks like this:

```text
cp: cannot create regular file '/usr/share/pixmaps/piavpn.png': Read-only file system
```

Steps 5 and 6 target paths that are writable on Fedora Atomic, so they only fail because the installer never reaches them. This project performs steps 3 through 7 itself.

## Before installing

Read the scripts before running them. The installer:

1. Checks which shared libraries PIA needs and layers only the packages your image is missing. On Bazzite that is normally `libnsl` and `xterm`.
2. Requires a reboot so the new deployment becomes active.
3. Resolves the latest stable PIA Linux installer from the official `pia-foss/desktop` GitHub release.
4. Downloads the installer only from PIA's official S3 storage domain.
5. Runs the official PIA installer as your normal user, as PIA recommends.
6. Creates and starts `pia-vpn.service`.
7. Recovers PIA's application icon from the installer archive.
8. Creates a launcher in your personal applications directory.
9. Writes the NetworkManager rule and the `piactl` symlink.

Bazzite recommends package layering only for system-level software that cannot work through Flatpak, Homebrew, or a container. Layered packages can occasionally interfere with future image upgrades.

## Installation options

### Option A: Clone and inspect the repository

This is the recommended method, because you can read every command before running it.

```bash
git clone https://github.com/saifullah4khan/pia-on-fedora-atomic.git
cd pia-on-fedora-atomic
chmod +x install.sh install-stage1.sh install-stage2.sh uninstall.sh
./install.sh
```

If Stage 1 installs packages, reboot:

```bash
systemctl reboot
```

After logging back in, enter the repository again and run the same command:

```bash
cd ~/pia-on-fedora-atomic
./install.sh
```

The script detects that the dependencies are now active and automatically continues with Stage 2.

### Option B: Explicit two-stage scripts

```bash
./install-stage1.sh
systemctl reboot
# after logging back in
./install-stage2.sh
```

### Option C: Paste-in installer

Reviewing a downloaded script before executing it is safer than piping it directly into Bash. For convenience, the standalone installer also supports this two-command process:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/saifullah4khan/pia-on-fedora-atomic/main/install.sh)
```

Reboot when Stage 1 finishes:

```bash
systemctl reboot
```

Then run the exact same command again.

## Verifying the installation

```bash
./install.sh --verify
```

This makes no changes and needs no `sudo`. It checks the host, the PIA binaries, the service, the launcher, the icon, the NetworkManager rule, the `piactl` symlink, and the current connection state, then prints a report:

```text
pia-on-fedora-atomic 1.1.0 verification report

  System:       Bazzite 42 (KDE Plasma)
  Architecture: x86_64

Host
  [ ok ] rpm-ostree system
  [ ok ] all PIA host dependencies are satisfied

PIA application
  [ ok ] binaries present at /var/opt/piavpn

Integration
  [ ok ] service file /etc/systemd/system/pia-vpn.service
  [ ok ] pia-vpn.service is enabled at boot
  [ ok ] pia-vpn.service is running
  [ ok ] application launcher installed
  [ ok ] PIA application icon installed
  [ ok ] NetworkManager leaves wgpia interfaces unmanaged
  [ ok ] piactl is on your PATH

Connection
  [ ok ] connection state: Connected
```

Paste this report into an issue when you need help, or into a [compatibility report](#compatibility-reports) when you get it working somewhere new.

## Fully manual installation

This section explains every change and is useful for auditing or troubleshooting the automated installer.

### 1. Confirm that this is an rpm-ostree system

```bash
rpm-ostree status
```

You should see your current deployment. If the command does not exist, stop. This workaround is specifically for rpm-ostree based systems.

### 2. Check the libraries PIA needs

PIA's installer checks for shared libraries, not package names:

```bash
for lib in libnsl.so.1 libxkbcommon.so.0 libxkbcommon-x11.so.0 \
           libnl-3.so.200 libnl-route-3.so.200 libnl-genl-3.so.200; do
  ldconfig -p | grep -q "$lib" && echo "ok      $lib" || echo "MISSING $lib"
done
command -v xterm >/dev/null && echo "ok      xterm" || echo "MISSING xterm"
command -v iptables >/dev/null && echo "ok      iptables" || echo "MISSING iptables"
```

On Bazzite, only `libnsl.so.1` and `xterm` are normally missing. The Fedora packages that provide them are:

| Missing | Package to layer |
| --- | --- |
| `libnsl.so.1` | `libnsl` |
| `libxkbcommon.so.0` | `libxkbcommon` |
| `libxkbcommon-x11.so.0` | `libxkbcommon-x11` |
| any `libnl-3` library | `libnl3` |
| `xterm` | `xterm` |
| `iptables` | `iptables-nft` |

### 3. Layer the dependencies

```bash
sudo rpm-ostree install libnsl xterm
```

This creates a new deployment with the required host libraries. It does not modify the currently running deployment.

### 4. Reboot into the new deployment

```bash
systemctl reboot
```

After logging in, confirm the packages are active:

```bash
rpm -q libnsl xterm
```

### 5. Download the PIA installer

The following URL was current for the tested PIA 3.7.2 x86_64 release. Check the official PIA releases page for a newer version first.

```bash
cd ~/Downloads
curl -fLO https://privateinternetaccess-storage.s3.amazonaws.com/pub/pia_desktop/builds/pia-linux-3.7.2-08420.run
ls -lh pia-linux-3.7.2-08420.run
```

ARM64 users need the matching `pia-linux-arm64-...run` installer from the official release.

### 6. Run the official installer

Do not put `sudo` in front of this command. PIA's installer requests elevated access itself when needed.

```bash
sh ~/Downloads/pia-linux-3.7.2-08420.run
```

An error about `/usr/share/pixmaps` is expected. Continue only after checking that the application files exist.

### 7. Verify the extracted PIA binaries

```bash
ls -lh \
  /var/opt/piavpn/bin/pia-daemon \
  /var/opt/piavpn/bin/pia-client \
  /var/opt/piavpn/bin/piactl
```

All three files must exist. Do not create the service if any of them are missing.

### 8. Create the PIA systemd service

```bash
sudo tee /etc/systemd/system/pia-vpn.service >/dev/null <<'SERVICE'
[Unit]
Description=Private Internet Access VPN daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Environment=LD_LIBRARY_PATH=/var/opt/piavpn/lib
ExecStart=/var/opt/piavpn/bin/pia-daemon
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SERVICE
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now pia-vpn.service
systemctl status pia-vpn.service --no-pager
```

The status should include `active (running)`.

### 9. Recover the application icon

PIA keeps its icon inside the `.run` payload and copies it to `/usr/share/pixmaps`, which is read-only here. Extract the archive without executing it and install the icon into your own icon theme:

```bash
mkdir -p ~/.cache/pia-extract
sh ~/Downloads/pia-linux-3.7.2-08420.run --noexec --keep --target ~/.cache/pia-extract
mkdir -p ~/.local/share/icons/hicolor/256x256/apps
install -m 0644 ~/.cache/pia-extract/installfiles/app-icon.png \
  ~/.local/share/icons/hicolor/256x256/apps/piavpn.png
rm -rf ~/.cache/pia-extract
gtk-update-icon-cache --force ~/.local/share/icons/hicolor
```

The extraction needs a few hundred megabytes of temporary space. Skip this step if you do not mind a generic icon, and use `Icon=network-vpn` in the next step instead of `Icon=piavpn`.

### 10. Create a per-user application launcher

```bash
mkdir -p ~/.local/share/applications
cat > ~/.local/share/applications/private-internet-access.desktop <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Private Internet Access
GenericName=VPN Client
Comment=Connect to the Private Internet Access VPN
Exec=/var/opt/piavpn/bin/pia-client
TryExec=/var/opt/piavpn/bin/pia-client
Icon=piavpn
Terminal=false
Categories=Network;Security;
Keywords=VPN;PIA;Privacy;WireGuard;
StartupNotify=true
StartupWMClass=pia-client
DESKTOP
chmod 0644 ~/.local/share/applications/private-internet-access.desktop
update-desktop-database ~/.local/share/applications
```

### 11. Stop NetworkManager managing PIA's WireGuard interface

```bash
printf '[keyfile]\nunmanaged-devices=interface-name:wgpia*\n' \
  | sudo tee /etc/NetworkManager/conf.d/wgpia.conf >/dev/null
sudo chmod 0644 /etc/NetworkManager/conf.d/wgpia.conf
sudo systemctl reload NetworkManager
```

Skip this only if your system does not use NetworkManager. Without it, DNS on the VPN interface can break when you change networks.

### 12. Put piactl on your PATH

```bash
sudo ln -s /var/opt/piavpn/bin/piactl /usr/local/bin/piactl
piactl --version
```

`/usr/local` is writable on Fedora Atomic, so this is the same location PIA would have used.

### 13. Open PIA

Search for **Private Internet Access** in the application menu, or launch it directly:

```bash
/var/opt/piavpn/bin/pia-client
```

Sign in with your PIA account and connect normally.

### 14. Enable Shadowsocks multi-hop

Inside PIA:

1. Open **Settings**.
2. Open **Multi-Hop and Obfuscation**.
3. Enable multi-hop.
4. Select **Shadowsocks**.
5. Use **Auto** initially, then select the final VPN region from the main server list.

Shadowsocks changes the route into PIA. The website still sees the final PIA VPN IP address.

## Using a specific PIA installer

The automated installer normally resolves the latest stable release. To force a specific official PIA installer:

```bash
PIA_INSTALLER_URL='https://privateinternetaccess-storage.s3.amazonaws.com/pub/pia_desktop/builds/pia-linux-3.7.2-08420.run' ./install.sh --stage2
```

The script refuses URLs outside PIA's official installer storage domain.

PIA does not publish checksums with its releases. If you obtain one through a channel you trust, the installer will enforce it:

```bash
PIA_INSTALLER_SHA256='...' ./install.sh --stage2
```

Other environment variables:

| Variable | Effect |
| --- | --- |
| `PIA_INSTALLER_URL` | Use a specific official PIA `.run` installer |
| `PIA_INSTALLER_SHA256` | Reject the download unless the SHA-256 matches |
| `PIA_SKIP_ICON=1` | Skip icon extraction and use the generic `network-vpn` icon |
| `NO_COLOR=1` | Disable colored output |

## Troubleshooting

Start with `./install.sh --verify`. It names the specific piece that is broken.

### The installer shows a read-only filesystem error

That is the failure this workaround expects. Check whether the three binaries under `/var/opt/piavpn/bin` exist. If they do, continue with the service and launcher steps.

### The service does not start

```bash
systemctl status pia-vpn.service --no-pager
journalctl -u pia-vpn.service -n 100 --no-pager
ls -lh /var/opt/piavpn/bin/pia-daemon
```

### The application does not appear in the menu

Run it directly:

```bash
/var/opt/piavpn/bin/pia-client
```

Then log out and back in, or refresh the desktop application database:

```bash
update-desktop-database ~/.local/share/applications
```

### DNS stops working after switching wifi or plugging in ethernet

The NetworkManager rule is missing. This affects every installation made with version 1.0 of this project:

```bash
ls -l /etc/NetworkManager/conf.d/wgpia.conf
```

If it is not there, rerun `./install.sh --stage2` or follow [step 11](#11-stop-networkmanager-managing-pias-wireguard-interface).

### The launcher shows a generic icon

Icon extraction was skipped or failed. Rerun `./install.sh --stage2`, or follow [step 9](#9-recover-the-application-icon) manually. This is cosmetic and nothing else depends on it.

PIA's own window icon comes from `/usr/share/pixmaps/piavpn.png`, which cannot be written on an Atomic system. The application window itself will keep a default icon. Only a custom image build can change that.

### Stage 2 says the packages are missing after Stage 1

You probably have not rebooted into the new deployment yet:

```bash
systemctl reboot
```

### GitHub API rate limit or release parsing failure

Open the official PIA release page, copy the current Linux installer URL, and run:

```bash
PIA_INSTALLER_URL='PASTE_THE_OFFICIAL_PIA_RUN_URL_HERE' ./install.sh --stage2
```

## Updating PIA

PIA may offer an in-app update. Because this installation depends on unsupported installer behavior, an update can fail at the same immutable `/usr` step.

The safer approach is:

1. Disconnect and quit PIA.
2. Run `./install.sh --stage2` again.
3. Run `./install.sh --verify`.

The script backs up an existing service file and launcher before replacing them, and leaves the NetworkManager rule and `piactl` symlink alone if they already exist.

## Uninstallation

### Automated removal

Remove PIA while preserving its user settings:

```bash
./uninstall.sh
```

Also remove saved PIA settings, the `piavpn` and `piahnsd` groups, PIA's routing-table entries, and the packages that Stage 1 recorded as newly layered:

```bash
./uninstall.sh --purge --remove-layered-packages
```

The uninstaller only removes the NetworkManager rule and the `piactl` symlink if this project created them and they still point at PIA. Removing layered packages creates another deployment, so reboot afterward when instructed.

### Manual removal

Disconnect and quit PIA first. Then run:

```bash
sudo systemctl disable --now pia-vpn.service
sudo rm -f /etc/systemd/system/pia-vpn.service
sudo systemctl daemon-reload
rm -f ~/.local/share/applications/private-internet-access.desktop
rm -f ~/.local/share/icons/hicolor/256x256/apps/piavpn.png
sudo rm -f /etc/NetworkManager/conf.d/wgpia.conf
sudo rm -f /usr/local/bin/piactl
sudo rm -rf /var/opt/piavpn
```

Optionally remove PIA's saved user settings and the groups its installer created:

```bash
rm -rf ~/.config/privateinternetaccess ~/.config/PrivateInternetAccess
sudo groupdel piavpn
sudo groupdel piahnsd
```

Optionally remove the layered packages:

```bash
sudo rpm-ostree uninstall libnsl xterm
systemctl reboot
```

Do not remove `xterm` or `libnsl` if you installed them for another application and still need them.

## Security notes

- The scripts never request, read, or save your PIA username or password.
- The PIA installer is run as your normal user, not as root. The scripts refuse to run as root.
- Elevated access is used only for `rpm-ostree`, the systemd service, the NetworkManager rule, the `piactl` symlink, and removal of `/var/opt/piavpn`.
- The automated installer accepts only official PIA S3 `.run` URLs.
- Icon extraction uses the archive's own extract-without-executing mode. The installer is not executed a second time.
- `--verify` makes no changes and needs no `sudo`.
- There are no official checksums in the release information published by PIA. Review the PIA release before running a newly published version, or supply your own with `PIA_INSTALLER_SHA256`.

See [SECURITY.md](SECURITY.md) for how to report a problem.

## Compatibility reports

Bazzite KDE is the only verified configuration. If you run this anywhere else, please [open a compatibility report](https://github.com/saifullah4khan/pia-on-fedora-atomic/issues/new?template=compatibility_report.yml) with:

- Distribution, desktop environment, and CPU architecture
- PIA version
- The output of `./install.sh --verify`
- Whether WireGuard, the kill switch, and Shadowsocks multi-hop connect
- Whether DNS survives a network change

Never post PIA credentials, account information, VPN tokens, or complete logs containing private network data.

## Sources and credit

This project packages and documents a workaround discussed by the community in:

- [PIA desktop issue #70: Unable to install on Fedora Atomics](https://github.com/pia-foss/desktop/issues/70)
- [PIA desktop releases](https://github.com/pia-foss/desktop/releases)
- [PIA's Linux installer source](https://github.com/pia-foss/desktop/blob/master/extras/installer/linux/linux_installer.sh), which is where the exact failure point and the missing integration steps were confirmed
- [PIA Linux installation guide](https://helpdesk.privateinternetaccess.com/hc/en-us/articles/46775920774043-Linux-Installing-the-PIA-App)
- [PIA Linux terminal uninstallation guide](https://helpdesk.privateinternetaccess.com/hc/en-us/articles/46775947469723-Linux-Uninstalling-the-PIA-App-Through-the-Terminal)
- [Bazzite package-layering documentation](https://docs.bazzite.gg/Installing_and_Managing_Software/rpm-ostree/)

Credit belongs to the PIA issue reporters and commenters who identified the immutable-path failure and demonstrated that the extracted client can be started with a manually created systemd service.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Compatibility reports are the most useful contribution.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

## Disclaimer

This project is provided as-is, without warranty. PIA or Fedora Atomic updates may change the installer, required dependencies, paths, or service behavior. Back up important data and make sure you understand how to select an older rpm-ostree deployment before modifying your system.

## License

[MIT](LICENSE)
