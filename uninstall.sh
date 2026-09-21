#!/usr/bin/env bash
# Remove the pia-on-fedora-atomic integration and, optionally, user settings
# and rpm-ostree packages that this project layered.
#
# https://github.com/saifullah4khan/pia-on-fedora-atomic

set -Eeuo pipefail

PROJECT_VERSION="1.1.0"
PROJECT_NAME="pia-on-fedora-atomic"

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/${PROJECT_NAME}"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/${PROJECT_NAME}"

SERVICE_NAME="pia-vpn.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
DESKTOP_FILE="$HOME/.local/share/applications/private-internet-access.desktop"
ICON_FILE="$HOME/.local/share/icons/hicolor/256x256/apps/piavpn.png"
NM_CONF_FILE="/etc/NetworkManager/conf.d/wgpia.conf"
PIACTL_SYMLINK="/usr/local/bin/piactl"
RT_TABLES="/etc/iproute2/rt_tables"

# Groups PIA's installer creates with groupadd before it fails.
PIA_GROUPS=(piavpn piahnsd)
# Routing tables PIA's daemon adds to /etc/iproute2/rt_tables at runtime.
PIA_ROUTING_TABLES=(piavpnrt piavpnOnlyrt piavpnWgrt piavpnFwdrt)

PURGE=false
REMOVE_PACKAGES=false
ASSUME_YES=false

usage() {
    cat <<'USAGE'
Usage: ./uninstall.sh [OPTIONS]

Options:
  --purge                      Also remove PIA user settings, the piavpn and
                               piahnsd groups, and PIA's routing-table entries
  --remove-layered-packages    Remove packages recorded as added by Stage 1
  --yes                        Do not ask for confirmation
  --version                    Show the version of this project
  --help                       Show this help

Examples:
  ./uninstall.sh
  ./uninstall.sh --purge --remove-layered-packages
USAGE
}

info()  { printf '==> %s\n' "$*" >&2; }
fatal() { printf 'Error: %s\n' "$*" >&2; exit 1; }

while (($#)); do
    case "$1" in
        --purge) PURGE=true ;;
        --remove-layered-packages) REMOVE_PACKAGES=true ;;
        --yes|-y) ASSUME_YES=true ;;
        --version|-V) printf '%s %s\n' "$PROJECT_NAME" "$PROJECT_VERSION"; exit 0 ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; fatal "Unknown option: $1" ;;
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

# ---------------------------------------------------------------------------
# Locate the installation
# ---------------------------------------------------------------------------

PIA_ROOT="/var/opt/piavpn"
if [[ -r "$STATE_DIR/pia-root" ]]; then
    saved_root="$(<"$STATE_DIR/pia-root")"
    case "$saved_root" in
        /var/opt/piavpn|/opt/piavpn) PIA_ROOT="$saved_root" ;;
        *) printf 'Ignoring unsafe saved PIA path: %s\n' "$saved_root" >&2 ;;
    esac
fi

# ---------------------------------------------------------------------------
# Stop the client and the daemon
# ---------------------------------------------------------------------------

if [[ -x "$PIA_ROOT/bin/piactl" ]]; then
    "$PIA_ROOT/bin/piactl" disconnect >/dev/null 2>&1 || true
fi

pkill -x pia-client >/dev/null 2>&1 || true

sudo systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
sudo rm -f -- "$SERVICE_FILE"
sudo systemctl daemon-reload
sudo systemctl reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true
info "Removed the systemd service."

# ---------------------------------------------------------------------------
# Per-user integration
# ---------------------------------------------------------------------------

rm -f -- "$DESKTOP_FILE" "$ICON_FILE"
# Backups this project made of earlier launchers.
rm -f -- "${DESKTOP_FILE}".backup.* 2>/dev/null || true

if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache --force --quiet "$HOME/.local/share/icons/hicolor" >/dev/null 2>&1 || true
fi
info "Removed the launcher and icon."

# ---------------------------------------------------------------------------
# System integration this project created
# ---------------------------------------------------------------------------

# Only remove the piactl symlink if it still points into the PIA installation.
if [[ -L "$PIACTL_SYMLINK" ]]; then
    symlink_target="$(readlink -- "$PIACTL_SYMLINK" || true)"
    case "$symlink_target" in
        /var/opt/piavpn/bin/piactl|/opt/piavpn/bin/piactl)
            sudo rm -f -- "$PIACTL_SYMLINK"
            info "Removed the piactl symlink."
            ;;
        *)
            printf 'Leaving %s alone; it points at %s\n' "$PIACTL_SYMLINK" "$symlink_target" >&2
            ;;
    esac
fi

# Only remove the NetworkManager rule if this project created it.
if [[ -r "$STATE_DIR/created-nm-config" && -f "$NM_CONF_FILE" ]]; then
    sudo rm -f -- "$NM_CONF_FILE"
    if systemctl is-active --quiet NetworkManager; then
        sudo systemctl reload NetworkManager >/dev/null 2>&1 || true
    fi
    info "Removed the NetworkManager rule for wgpia interfaces."
elif [[ -f "$NM_CONF_FILE" ]]; then
    printf 'Leaving %s alone; this installation did not create it.\n' "$NM_CONF_FILE" >&2
fi

sudo rm -rf -- "$PIA_ROOT"
info "Removed $PIA_ROOT."

# ---------------------------------------------------------------------------
# Optional deeper cleanup
# ---------------------------------------------------------------------------

if $PURGE; then
    rm -rf -- "$HOME/.config/privateinternetaccess" \
              "$HOME/.config/PrivateInternetAccess" \
              "$HOME/.config/autostart/piavpn.desktop"
    info "Removed PIA user settings."

    for group in "${PIA_GROUPS[@]}"; do
        if getent group "$group" >/dev/null 2>&1; then
            sudo groupdel "$group" >/dev/null 2>&1 || true
        fi
    done
    info "Removed the PIA groups."

    if [[ -f "$RT_TABLES" ]]; then
        rt_pattern=""
        for table in "${PIA_ROUTING_TABLES[@]}"; do
            rt_pattern="${rt_pattern}${rt_pattern:+|}${table}"
        done
        rt_pattern="(^|[[:space:]])(${rt_pattern})([[:space:]]|\$)"

        if grep -Eq -- "$rt_pattern" "$RT_TABLES"; then
            # Write through a temporary file. Piping grep straight into tee
            # truncates the file before grep has finished reading it.
            rt_tmp="$(mktemp)"
            grep -Ev -- "$rt_pattern" "$RT_TABLES" > "$rt_tmp" || true
            # shellcheck disable=SC2024  # the redirect reads our own temp file
            sudo tee "$RT_TABLES" < "$rt_tmp" >/dev/null
            rm -f -- "$rt_tmp"
            info "Removed PIA's routing-table entries."
        fi
    fi
fi

reboot_needed=false
if $REMOVE_PACKAGES && [[ -s "$STATE_DIR/layered-packages" ]]; then
    mapfile -t recorded_packages < "$STATE_DIR/layered-packages"
    installed_packages=()
    for pkg in "${recorded_packages[@]}"; do
        case "$pkg" in
            libnsl|xterm|libxkbcommon|libxkbcommon-x11|libnl3|iptables-nft)
                if rpm -q "$pkg" >/dev/null 2>&1; then
                    installed_packages+=("$pkg")
                fi
                ;;
            '') ;;
            *) printf 'Ignoring unexpected package recorded in state: %s\n' "$pkg" >&2 ;;
        esac
    done

    if ((${#installed_packages[@]})); then
        sudo rpm-ostree uninstall "${installed_packages[@]}"
        reboot_needed=true
    fi
fi

rm -rf -- "$STATE_DIR" "$CACHE_DIR"

echo
echo 'PIA and the community integration have been removed.'
if $PURGE; then
    echo 'PIA user settings, groups, and routing-table entries were also removed.'
else
    echo 'PIA user settings were preserved. Use --purge to remove them.'
fi
if $reboot_needed; then
    echo 'Reboot to activate the deployment without the layered packages.'
fi
