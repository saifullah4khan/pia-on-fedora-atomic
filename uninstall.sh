#!/usr/bin/env bash
# Remove the pia-on-fedora-atomic integration and, optionally, user settings
# and rpm-ostree packages that this project layered.

set -Eeuo pipefail

PROJECT_NAME="pia-on-fedora-atomic"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/${PROJECT_NAME}"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/${PROJECT_NAME}"
SERVICE_NAME="pia-vpn.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
DESKTOP_FILE="$HOME/.local/share/applications/private-internet-access.desktop"
PURGE=false
REMOVE_PACKAGES=false
ASSUME_YES=false

usage() {
    cat <<'USAGE'
Usage: ./uninstall.sh [OPTIONS]

Options:
  --purge                      Also remove PIA user settings and credentials
  --remove-layered-packages    Remove packages recorded as added by Stage 1
  --yes                        Do not ask for confirmation
  --help                       Show this help

Examples:
  ./uninstall.sh
  ./uninstall.sh --purge --remove-layered-packages
USAGE
}

fatal() { printf 'Error: %s\n' "$*" >&2; exit 1; }

while (($#)); do
    case "$1" in
        --purge) PURGE=true ;;
        --remove-layered-packages) REMOVE_PACKAGES=true ;;
        --yes) ASSUME_YES=true ;;
        --help|-h) usage; exit 0 ;;
        *) usage; fatal "Unknown option: $1" ;;
    esac
    shift
done

if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    fatal "Do not run this script as root or with sudo."
fi

if ! $ASSUME_YES; then
    printf 'This will stop PIA and remove the application files and launcher. Continue? [y/N] '
    read -r answer
    [[ "$answer" =~ ^[Yy]$ ]] || { echo 'Cancelled.'; exit 0; }
fi

PIA_ROOT="/var/opt/piavpn"
if [[ -r "$STATE_DIR/pia-root" ]]; then
    saved_root="$(<"$STATE_DIR/pia-root")"
    case "$saved_root" in
        /var/opt/piavpn|/opt/piavpn) PIA_ROOT="$saved_root" ;;
        *) printf 'Ignoring unsafe saved PIA path: %s\n' "$saved_root" >&2 ;;
    esac
fi

if [[ -x "$PIA_ROOT/bin/piactl" ]]; then
    "$PIA_ROOT/bin/piactl" disconnect >/dev/null 2>&1 || true
fi

sudo systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
sudo rm -f -- "$SERVICE_FILE"
sudo systemctl daemon-reload
sudo systemctl reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true

rm -f -- "$DESKTOP_FILE"
sudo rm -rf -- "$PIA_ROOT"

if $PURGE; then
    rm -rf -- "$HOME/.config/privateinternetaccess" \
              "$HOME/.config/PrivateInternetAccess"
fi

reboot_needed=false
if $REMOVE_PACKAGES && [[ -s "$STATE_DIR/layered-packages" ]]; then
    mapfile -t recorded_packages < "$STATE_DIR/layered-packages"
    installed_packages=()
    for pkg in "${recorded_packages[@]}"; do
        case "$pkg" in
            libnsl|xterm)
                if rpm -q "$pkg" >/dev/null 2>&1; then
                    installed_packages+=("$pkg")
                fi
                ;;
            *) printf 'Ignoring unexpected package recorded in state: %s\n' "$pkg" >&2 ;;
        esac
    done

    if ((${#installed_packages[@]})); then
        sudo rpm-ostree uninstall "${installed_packages[@]}"
        reboot_needed=true
    fi
fi

rm -rf -- "$STATE_DIR" "$CACHE_DIR"

echo 'PIA and the community integration have been removed.'
if $PURGE; then
    echo 'PIA user settings were also removed.'
else
    echo 'PIA user settings were preserved. Use --purge to remove them.'
fi
if $reboot_needed; then
    echo 'Reboot to activate the deployment without the layered packages.'
fi
