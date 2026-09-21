# Security

This project is a set of shell scripts that download and run the official
Private Internet Access Linux installer, then create a systemd service, a
desktop launcher, and a NetworkManager rule. It is unofficial and is not
affiliated with Private Internet Access.

## What the scripts do and do not do

- They never request, read, store, or transmit your PIA username, password,
  account number, or authentication token.
- They download the PIA installer only over HTTPS from PIA's official storage
  domain, `privateinternetaccess-storage.s3.amazonaws.com`. Any other URL is
  refused, including one supplied through `PIA_INSTALLER_URL`.
- They run the PIA installer as your normal user, as PIA recommends. The script
  refuses to run as root.
- `sudo` is used only for `rpm-ostree`, the systemd unit in `/etc`, the
  NetworkManager rule in `/etc`, the `piactl` symlink in `/usr/local/bin`, and
  removal of `/var/opt/piavpn`.
- `--verify` makes no changes and needs no `sudo`.
- Nothing is sent anywhere. The only network requests are to GitHub's public
  release API and to PIA's installer storage.

## Verifying the installer

PIA does not publish checksums with its releases, so this project cannot verify
one for you by default. If you obtain a SHA-256 through a channel you trust, set
it before installing and the download is rejected unless it matches:

```bash
PIA_INSTALLER_SHA256='...' ./install.sh --stage2
```

## Reporting a problem

Open an issue at
https://github.com/saifullah4khan/pia-on-fedora-atomic/issues for anything that
is not sensitive.

For something you would rather not post publicly, such as a way to make these
scripts run unintended commands, use GitHub's private vulnerability reporting on
the Security tab of this repository. Please include the script, the version from
`./install.sh --version`, and the steps to reproduce.

Vulnerabilities in the PIA client itself belong with PIA, not here. Report those
through https://github.com/pia-foss/desktop or PIA support.

## Supported versions

Only the latest release receives fixes. Run `./install.sh --version` to see
which version you have.
