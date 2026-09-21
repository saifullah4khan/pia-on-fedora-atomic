# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[semantic versioning](https://semver.org/).

## [1.1.0] - 2026-09-21

Two months of real-world use with no reported failures, plus a closer reading of
PIA's own installer. That reading turned up integration steps this project was
silently missing, so this release is mostly about completing the job rather than
changing how it is used. Upgrading is a matter of pulling and running
`./install.sh --stage2` again.

### The missing steps

PIA's Linux installer runs under `set -e`. On Fedora Atomic the first command
that fails is the icon copy into the read-only `/usr/share/pixmaps`, which
aborts the installer on the spot. Everything after that point never runs:

| Step PIA never reaches | Before | Now |
| --- | --- | --- |
| Desktop launcher | Replaced by this project | Replaced by this project |
| `/etc/NetworkManager/conf.d/wgpia.conf` | Missing | Created |
| `/usr/local/bin/piactl` symlink | Missing | Created |
| Application icon | Missing, generic icon used | Recovered from the installer archive |

### Added

- The NetworkManager rule that marks PIA's `wgpia*` WireGuard interfaces as
  unmanaged. Without it, NetworkManager can take over the interface and discard
  the DNS settings PIA applied to it when the machine changes network. PIA ships
  this rule; Atomic systems have never received it.
- A `piactl` symlink in `/usr/local/bin`, so the CLI works without typing the
  full path. `/usr/local` is writable on Fedora Atomic, so this is where PIA
  would have put it.
- PIA's real application icon. It lives inside the `.run` payload and is
  extracted from the archive without executing it, then installed into the
  per-user icon theme. If extraction fails for any reason, the launcher falls
  back to the generic `network-vpn` icon exactly as before. Set
  `PIA_SKIP_ICON=1` to skip this step.
- `./install.sh --verify`, a read-only health check that reports on host
  dependencies, binaries, the service, the launcher, the icon, the
  NetworkManager rule, the symlink, and the current connection state. It needs
  no `sudo` and its output is meant to be pasted into an issue.
- `./install.sh --version` and `./uninstall.sh --version`.
- Optional `PIA_INSTALLER_SHA256`. When set, the downloaded installer is
  rejected unless its SHA-256 matches. PIA publishes no official checksums, so
  this is for people who verify one out of band.
- A `lint` GitHub Actions workflow running ShellCheck, syntax checks, desktop
  entry validation, and a version-consistency check.
- Issue templates for bug reports and compatibility reports, `SECURITY.md`, and
  this changelog.
- `networkmanager/wgpia.conf` as a reference copy of what the installer writes.

### Changed

- Dependency detection now tests for the shared libraries PIA actually checks
  (`libnsl.so.1`, `libxkbcommon.so.0`, `libxkbcommon-x11.so.0`, the `libnl-3`
  family, `iptables`, `xterm`) instead of assuming every system is missing
  exactly `libnsl` and `xterm`. On Bazzite the result is unchanged. On a leaner
  Fedora Atomic image, the packages that image is genuinely missing are layered
  too, and nothing already installed is layered again. If the library database
  cannot be read, the script assumes the libraries are present rather than
  layering packages on a failed probe.
- The systemd unit now sets `LD_LIBRARY_PATH` to PIA's own `lib` directory and
  uses `Restart=always`, matching the unit PIA ships.
- The launcher gained `StartupWMClass`, `GenericName`, and `Keywords`, so the
  running window associates with its icon and the entry is easier to search for.
- `uninstall.sh` now removes the NetworkManager rule and the `piactl` symlink,
  but only when this project created them and they still point at PIA.
- `uninstall.sh --purge` now also removes the `piavpn` and `piahnsd` groups and
  PIA's `piavpnrt` routing-table entries, matching PIA's own uninstaller.
- The README leads with a quick start and documents the three integration steps
  precisely rather than describing the failure in general terms.

### Fixed

- Sourcing `/etc/os-release` to detect the distribution overwrote the script's
  own `VERSION` variable, so the version reported and recorded in state was the
  operating system's. The file is now read in a subshell.
- `uninstall.sh` piped `grep` directly into `sudo tee` on the same file when
  editing routing tables, which can truncate the file before `grep` finishes
  reading it. It now writes through a temporary file.
- A failed download no longer leaves a partial JSON response in the cache
  directory, and a GitHub API failure now explains how to continue with
  `PIA_INSTALLER_URL` instead of failing with a parse error.

### Compatibility

PIA 3.7.2 is still the current stable release, so the tested configuration is
unchanged. Existing 1.0 installations keep working and are not required to
upgrade. Running `./install.sh --stage2` again applies the new integration
steps, backing up the existing service file first.

## [1.0.0] - 2026-07-25

Initial release.

- Documented manual installation process for Bazzite and Fedora Atomic.
- Two-stage automatic installer with separate Stage 1 and Stage 2 entry points.
- systemd service integration and a per-user desktop launcher.
- Uninstall script with optional settings purge and package rollback.
- Verified on Bazzite KDE with PIA 3.7.2: native client, full server picker,
  WireGuard, kill switch, Shadowsocks, and multi-hop.

[1.1.0]: https://github.com/saifullah4khan/pia-on-fedora-atomic/releases/tag/v1.1.0
[1.0.0]: https://github.com/saifullah4khan/pia-on-fedora-atomic/releases/tag/Initial-Release
