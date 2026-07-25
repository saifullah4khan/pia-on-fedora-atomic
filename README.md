# PIA on Fedora Atomic

Install the full **Private Internet Access desktop client** on Bazzite and compatible Fedora Atomic desktops.

The standard PIA Linux installer copies most of the application successfully, but fails near the end when it tries to write icons and desktop entries into the immutable `/usr` directory. This project completes the missing systemd and desktop integration using writable locations.

> [!IMPORTANT]
> This is an unofficial community workaround. It is not affiliated with or supported by Private Internet Access, Fedora, Universal Blue, or Bazzite.

## Tested configuration

- **Distribution:** Bazzite KDE
- **Architecture:** x86_64
- **PIA client:** 3.7.2
- **Tested:** July 25, 2026
- **Confirmed:** Native PIA interface, full server picker, WireGuard, and Shadowsocks multi-hop

Other Fedora Atomic desktops may work because they use the same rpm-ostree and immutable `/usr` model, but they should be treated as unverified until someone reports a successful test.

## What this preserves

Because this installs the native PIA desktop client rather than importing individual OpenVPN profiles, you retain PIA's normal server browser and client-side settings.

Feature availability can change between PIA releases. Shadowsocks multi-hop obfuscates the connection between your device and PIA, but it does **not** guarantee that websites cannot identify the final PIA exit IP as a VPN address.

## Why the normal installer fails

PIA's installer writes the application under `/opt/piavpn`. On Fedora Atomic systems, `/opt` resolves into writable `/var` storage, so the application itself is extracted successfully. The installer later attempts to create files under locations such as:

```text
/usr/share/pixmaps
/usr/share/applications
```

Those paths are read-only on Bazzite and other Fedora Atomic desktops. The expected error looks similar to:

```text
cp: cannot create regular file '/usr/share/pixmaps/piavpn.png': Read-only file system
```

This project verifies that the PIA binaries were extracted, creates a systemd service in `/etc`, and creates a per-user application launcher under `~/.local/share/applications`.

## Before installing

Read the scripts before running them. The installer:

1. Layers `libnsl` and `xterm` with `rpm-ostree` only when missing.
2. Requires a reboot so the new deployment becomes active.
3. Resolves the latest stable PIA Linux installer from the official `pia-foss/desktop` GitHub release.
4. Downloads the installer only from PIA's official S3 storage domain.
5. Runs the official PIA installer as your normal user, as PIA recommends.
6. Creates and starts `pia-vpn.service`.
7. Creates a launcher in your personal applications directory.

Bazzite recommends package layering only for system-level software that cannot work through Flatpak, Homebrew, or a container. Layered packages can occasionally interfere with future image upgrades.

# Installation options

## Option A: Clone and inspect the repository

This is the recommended method because you can read every command before running it.

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

## Option B: Explicit two-stage scripts

Run Stage 1:

```bash
./install-stage1.sh
```

Reboot:

```bash
systemctl reboot
```

Run Stage 2:

```bash
./install-stage2.sh
```

## Option C: Paste-in installer

Reviewing a downloaded script before executing it is safer than piping it directly into Bash. For convenience, the standalone installer also supports this two-command process:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/saifullah4khan/pia-on-fedora-atomic/main/install.sh)
```

Reboot when Stage 1 finishes:

```bash
systemctl reboot
```

Then run the exact same command again:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/saifullah4khan/pia-on-fedora-atomic/main/install.sh)
```

# Fully manual installation

This section explains every change and is useful for auditing or troubleshooting the automated installer.

## 1. Confirm that this is an rpm-ostree system

```bash
rpm-ostree status
```

You should see your current Bazzite deployment. If the command does not exist, stop. This workaround is specifically for rpm-ostree based systems.

## 2. Check the required packages

```bash
rpm -q libnsl xterm
```

A package version means it is already installed. `package ... is not installed` means it must be layered.

## 3. Layer the dependencies

```bash
sudo rpm-ostree install libnsl xterm
```

This creates a new Bazzite deployment with the required host libraries. It does not modify the currently running deployment.

## 4. Reboot into the new deployment

```bash
systemctl reboot
```

After logging in, confirm the packages are active:

```bash
rpm -q libnsl xterm
```

## 5. Download the tested PIA installer

The following URL was current for the tested PIA 3.7.2 x86_64 release. Check the official PIA releases page for a newer version before publishing future updates to this guide.

```bash
cd ~/Downloads
curl -fLO https://privateinternetaccess-storage.s3.amazonaws.com/pub/pia_desktop/builds/pia-linux-3.7.2-08420.run
```

Confirm that the file exists:

```bash
ls -lh pia-linux-3.7.2-08420.run
```

ARM64 users need the matching `pia-linux-arm64-...run` installer from the official release.

## 6. Run the official installer

Do not put `sudo` in front of this command. PIA's installer requests elevated access itself when needed.

```bash
sh ~/Downloads/pia-linux-3.7.2-08420.run
```

An error involving `/usr/share/pixmaps` or `/usr/share/applications` is expected. Continue only after checking that the useful application files exist.

## 7. Verify the extracted PIA binaries

```bash
ls -lh \
  /var/opt/piavpn/bin/pia-daemon \
  /var/opt/piavpn/bin/pia-client \
  /var/opt/piavpn/bin/piactl
```

All three files must exist. Do not create the service if any of them are missing.

## 8. Create the PIA systemd service

```bash
sudo tee /etc/systemd/system/pia-vpn.service >/dev/null <<'SERVICE'
[Unit]
Description=Private Internet Access VPN daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/var/opt/piavpn/bin/pia-daemon
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
SERVICE
```

Tell systemd to load and start it:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now pia-vpn.service
```

Confirm that it is active:

```bash
systemctl status pia-vpn.service --no-pager
```

The status should include `active (running)`.

## 9. Create a per-user application launcher

The official installer cannot write its normal launcher into immutable `/usr/share/applications`. This replacement is stored inside your home directory.

```bash
mkdir -p ~/.local/share/applications
```

```bash
cat > ~/.local/share/applications/private-internet-access.desktop <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Private Internet Access
Comment=Connect to the Private Internet Access VPN
Exec=/var/opt/piavpn/bin/pia-client
TryExec=/var/opt/piavpn/bin/pia-client
Icon=network-vpn
Terminal=false
Categories=Network;Security;
StartupNotify=true
DESKTOP
```

Set normal launcher permissions:

```bash
chmod 0644 ~/.local/share/applications/private-internet-access.desktop
```

## 10. Open PIA

Search for **Private Internet Access** in the application menu, or launch it directly:

```bash
/var/opt/piavpn/bin/pia-client
```

Sign in with your PIA account and connect normally.

## 11. Enable Shadowsocks multi-hop

Inside PIA:

1. Open **Settings**.
2. Open **Multi-Hop and Obfuscation**.
3. Enable multi-hop.
4. Select **Shadowsocks**.
5. Use **Auto** initially, then select the final VPN region from the main server list.

Shadowsocks changes the route into PIA. The website still sees the final PIA VPN IP address.

# Verification

Check the daemon:

```bash
systemctl is-active pia-vpn.service
```

Check the PIA connection state:

```bash
/var/opt/piavpn/bin/piactl get connectionstate
```

View service logs:

```bash
journalctl -u pia-vpn.service -n 100 --no-pager
```

# Using a specific PIA installer

The automated installer normally resolves the latest stable release. To force a specific official PIA installer:

```bash
PIA_INSTALLER_URL='https://privateinternetaccess-storage.s3.amazonaws.com/pub/pia_desktop/builds/pia-linux-3.7.2-08420.run' ./install.sh --stage2
```

The script refuses URLs outside PIA's official installer storage domain.

# Troubleshooting

## The installer shows a read-only filesystem error

That is the failure this workaround expects. Check whether the three binaries under `/var/opt/piavpn/bin` exist. If they do, continue with the service and launcher steps.

## The service does not start

```bash
systemctl status pia-vpn.service --no-pager
journalctl -u pia-vpn.service -n 100 --no-pager
```

Also verify:

```bash
ls -lh /var/opt/piavpn/bin/pia-daemon
```

## The application does not appear in the menu

Run it directly:

```bash
/var/opt/piavpn/bin/pia-client
```

Then log out and back in, or refresh the desktop application database:

```bash
update-desktop-database ~/.local/share/applications
```

## Stage 2 says the packages are missing after Stage 1

You probably have not rebooted into the new deployment yet:

```bash
systemctl reboot
```

## GitHub API rate limit or release parsing failure

Open the official PIA release page, copy the current Linux installer URL, and run:

```bash
PIA_INSTALLER_URL='PASTE_THE_OFFICIAL_PIA_RUN_URL_HERE' ./install.sh --stage2
```

# Uninstallation

## Automated removal

Remove PIA while preserving its user settings:

```bash
./uninstall.sh
```

Also remove saved PIA settings and the packages that Stage 1 recorded as newly layered:

```bash
./uninstall.sh --purge --remove-layered-packages
```

Removing layered packages creates another deployment, so reboot afterward when instructed.

## Manual removal

Disconnect and quit PIA first. Then run:

```bash
sudo systemctl disable --now pia-vpn.service
sudo rm -f /etc/systemd/system/pia-vpn.service
sudo systemctl daemon-reload
rm -f ~/.local/share/applications/private-internet-access.desktop
sudo rm -rf /var/opt/piavpn
```

Optionally remove PIA's saved user settings:

```bash
rm -rf ~/.config/privateinternetaccess ~/.config/PrivateInternetAccess
```

Optionally remove the layered packages:

```bash
sudo rpm-ostree uninstall libnsl xterm
systemctl reboot
```

Do not remove `xterm` or `libnsl` if you installed them for another application and still need them.

# Security notes

- The scripts never request, read, or save your PIA username or password.
- The PIA installer is run as your normal user, not as root.
- Elevated access is used only for rpm-ostree, the systemd service, and the application directory under `/var/opt` during removal.
- The automated installer accepts only official PIA S3 `.run` URLs.
- There are no official checksums in the release information currently parsed by this project. Review the PIA release before running a newly published version.

# Updating PIA

PIA may offer an in-app update. Because this installation depends on unsupported installer behavior, an update can fail at the same immutable `/usr` step.

The safer approach is:

1. Disconnect and quit PIA.
2. Run `./install.sh --stage2` again.
3. Confirm that `pia-vpn.service` is active.
4. Confirm that the client opens and connects.

The script backs up an existing service file before replacing it.

# Compatibility reports

Please open an issue with:

- Distribution and desktop environment
- CPU architecture
- PIA version
- Whether the client opens after reboot
- Whether WireGuard connects
- Whether Shadowsocks multi-hop connects
- Sanitized service logs when something fails

Never post PIA credentials, account information, VPN tokens, or complete logs containing private network data.

# Sources and credit

This project packages and documents a workaround discussed by the community in:

- [PIA desktop issue #70: Unable to install on Fedora Atomics](https://github.com/pia-foss/desktop/issues/70)
- [PIA desktop releases](https://github.com/pia-foss/desktop/releases)
- [PIA Linux installation guide](https://helpdesk.privateinternetaccess.com/hc/en-us/articles/46775920774043-Linux-Installing-the-PIA-App)
- [PIA Linux terminal uninstallation guide](https://helpdesk.privateinternetaccess.com/hc/en-us/articles/46775947469723-Linux-Uninstalling-the-PIA-App-Through-the-Terminal)
- [Bazzite package-layering documentation](https://docs.bazzite.gg/Installing_and_Managing_Software/rpm-ostree/)

Credit belongs to the PIA issue reporters and commenters who identified the immutable-path failure and demonstrated that the extracted client can be started with a manually created systemd service.

# Disclaimer

This project is provided as-is, without warranty. PIA or Fedora Atomic updates may change the installer, required dependencies, paths, or service behavior. Back up important data and make sure you understand how to select an older rpm-ostree deployment before modifying your system.

# License

[MIT](LICENSE)
