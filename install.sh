#!/usr/bin/env bash
# Install the full Private Internet Access desktop client on Bazzite and
# compatible Fedora Atomic desktops.
#
# This is an unofficial community workaround. Review this script before use.

set -Eeuo pipefail

PROJECT_NAME="pia-on-fedora-atomic"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/${PROJECT_NAME}"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/${PROJECT_NAME}"
SERVICE_NAME="pia-vpn.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
DESKTOP_FILE="$HOME/.local/share/applications/private-internet-access.desktop"
RELEASE_API="https://api.github.com/repos/pia-foss/desktop/releases/latest"
REQUIRED_PACKAGES=(libnsl xterm)

COLOR=false
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    COLOR=true
fi

if $COLOR; then
    BOLD=$'\033[1m'
    GREEN=$'\033[32m'
    YELLOW=$'\033[33m'
    RED=$'\033[31m'
    RESET=$'\033[0m'
else
    BOLD="" GREEN="" YELLOW="" RED="" RESET=""
fi

info()  { printf '%s==>%s %s\n' "$GREEN" "$RESET" "$*" >&2; }
warn()  { printf '%sWarning:%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
fatal() { printf '%sError:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

on_error() {
    local rc=$?
    printf '%sInstallation stopped%s at line %s with exit code %s.\n' \
        "$RED" "$RESET" "${BASH_LINENO[0]:-unknown}" "$rc" >&2
    printf 'Nothing will continue automatically. Read the error above before retrying.\n' >&2
    exit "$rc"
}
trap on_error ERR

usage() {
    cat <<'USAGE'
Usage: ./install.sh [OPTION]

With no option, the script automatically runs the correct stage:
  - Stage 1 when required rpm-ostree packages are missing
  - Stage 2 when those packages are already active

Options:
  --stage1       Only layer the required host packages
  --stage2       Only install and integrate the PIA desktop client
  --help         Show this help

Optional environment variable:
  PIA_INSTALLER_URL=https://.../pia-linux-....run

Set PIA_INSTALLER_URL to use a specific official PIA Linux installer instead
of resolving the newest stable release from pia-foss/desktop on GitHub.
USAGE
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fatal "Required command '$1' was not found."
}

require_regular_user() {
    if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
        fatal "Do not run this script as root or with sudo. It requests sudo only for the system changes that need it."
    fi
}

require_atomic_host() {
    require_command rpm-ostree
    if ! rpm-ostree status >/dev/null 2>&1; then
        fatal "rpm-ostree is installed, but this does not appear to be an active rpm-ostree system."
    fi

    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        info "Detected ${PRETTY_NAME:-an rpm-ostree based Linux system}."
    fi
}

missing_packages() {
    local pkg
    for pkg in "${REQUIRED_PACKAGES[@]}"; do
        if ! rpm -q "$pkg" >/dev/null 2>&1; then
            printf '%s\n' "$pkg"
        fi
    done
}

save_layered_packages() {
    mkdir -p "$STATE_DIR"
    printf '%s\n' "$@" > "$STATE_DIR/layered-packages"
}

stage1() {
    require_regular_user
    require_atomic_host
    require_command rpm
    require_command sudo

    mapfile -t missing < <(missing_packages)

    if ((${#missing[@]} == 0)); then
        info "The required packages are already active. No dependency reboot is needed."
        printf '\nRun Stage 2 now:\n  ./install.sh --stage2\n'
        return 0
    fi

    info "The PIA installer needs these host packages: ${missing[*]}"
    warn "Bazzite treats rpm-ostree layering as a last resort. These packages can be removed later with the included uninstall script."

    sudo rpm-ostree install "${missing[@]}"
    save_layered_packages "${missing[@]}"

    mkdir -p "$STATE_DIR"
    date -u +'%Y-%m-%dT%H:%M:%SZ' > "$STATE_DIR/stage1-complete"

    cat <<EOF2

${BOLD}Stage 1 finished.${RESET}

A new deployment was created. Reboot to activate it:

  systemctl reboot

After logging back in, run the same installer again. It will detect the
packages and automatically continue with Stage 2.
EOF2
}

resolve_installer_url() {
    local arch="$1"
    local release_json="$2"

    python3 - "$arch" "$release_json" <<'PY'
import json
import re
import sys
from pathlib import Path

arch = sys.argv[1]
data = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))

candidates = []
for asset in data.get("assets", []):
    url = asset.get("browser_download_url")
    if isinstance(url, str):
        candidates.append(url)

body = data.get("body") or ""
candidates.extend(
    re.findall(
        r"https://privateinternetaccess-storage\.s3\.amazonaws\.com/"
        r"pub/pia_desktop/builds/pia-linux(?:-arm64)?-[^\s)\]>'\"]+\.run",
        body,
    )
)

# Keep order while removing duplicates.
seen = set()
urls = []
for url in candidates:
    if url not in seen:
        seen.add(url)
        urls.append(url)

if arch in {"x86_64", "amd64"}:
    matches = [u for u in urls if "/pia-linux-" in u and "pia-linux-arm64-" not in u]
elif arch in {"aarch64", "arm64"}:
    matches = [u for u in urls if "pia-linux-arm64-" in u]
else:
    raise SystemExit(f"Unsupported architecture: {arch}")

if not matches:
    raise SystemExit("No matching official Linux installer URL was found in the latest PIA release.")

print(matches[0])
PY
}

download_installer() {
    require_command curl
    require_command python3

    local arch url filename destination release_json
    arch="$(uname -m)"
    mkdir -p "$CACHE_DIR"

    if [[ -n "${PIA_INSTALLER_URL:-}" ]]; then
        url="$PIA_INSTALLER_URL"
        info "Using the installer URL supplied through PIA_INSTALLER_URL."
    else
        release_json="$CACHE_DIR/latest-release.json.tmp"
        info "Resolving the latest stable PIA desktop release from GitHub."
        curl --fail --silent --show-error --location \
            --retry 3 --retry-delay 2 \
            --header 'Accept: application/vnd.github+json' \
            --header 'User-Agent: pia-on-fedora-atomic' \
            "$RELEASE_API" > "$release_json"
        url="$(resolve_installer_url "$arch" "$release_json")"
        rm -f "$release_json"
    fi

    case "$url" in
        https://privateinternetaccess-storage.s3.amazonaws.com/*.run) ;;
        *)
            fatal "Refusing a non-PIA installer URL. Expected an official privateinternetaccess-storage.s3.amazonaws.com .run file."
            ;;
    esac

    filename="${url##*/}"
    filename="${filename%%\?*}"
    [[ "$filename" == *.run ]] || fatal "The resolved installer filename does not end in .run."
    destination="$CACHE_DIR/$filename"

    info "Downloading $filename from PIA's official storage."
    curl --fail --location --progress-bar --retry 3 --retry-delay 2 \
        "$url" --output "$destination"
    [[ -s "$destination" ]] || fatal "The downloaded installer is empty."
    chmod 0700 "$destination"

    printf '%s\n' "$destination"
}

find_pia_root() {
    local candidate
    for candidate in /var/opt/piavpn /opt/piavpn; do
        if [[ -x "$candidate/bin/pia-daemon" \
           && -x "$candidate/bin/pia-client" \
           && -x "$candidate/bin/piactl" ]]; then
            readlink -f "$candidate"
            return 0
        fi
    done
    return 1
}

backup_existing_file() {
    local path="$1"
    if [[ -e "$path" ]]; then
        local backup="${path}.backup.$(date -u +%Y%m%dT%H%M%SZ)"
        info "Backing up existing $path to $backup"
        sudo cp --preserve=mode,ownership,timestamps "$path" "$backup"
    fi
}

install_service() {
    local pia_root="$1"
    backup_existing_file "$SERVICE_FILE"

    info "Creating the PIA systemd service."
    sudo tee "$SERVICE_FILE" >/dev/null <<EOF2
[Unit]
Description=Private Internet Access VPN daemon
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${pia_root}/bin/pia-daemon
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF2

    sudo chmod 0644 "$SERVICE_FILE"
    sudo systemctl daemon-reload
    sudo systemctl enable --now "$SERVICE_NAME"

    if ! sudo systemctl is-active --quiet "$SERVICE_NAME"; then
        sudo systemctl status "$SERVICE_NAME" --no-pager || true
        fatal "The PIA daemon service did not become active."
    fi
}

install_desktop_entry() {
    local pia_root="$1"
    mkdir -p "$(dirname "$DESKTOP_FILE")"

    if [[ -e "$DESKTOP_FILE" ]]; then
        cp "$DESKTOP_FILE" "${DESKTOP_FILE}.backup.$(date -u +%Y%m%dT%H%M%SZ)"
    fi

    info "Creating a per-user application-menu entry."
    cat > "$DESKTOP_FILE" <<EOF2
[Desktop Entry]
Type=Application
Name=Private Internet Access
Comment=Connect to the Private Internet Access VPN
Exec=${pia_root}/bin/pia-client
TryExec=${pia_root}/bin/pia-client
Icon=network-vpn
Terminal=false
Categories=Network;Security;
StartupNotify=true
EOF2
    chmod 0644 "$DESKTOP_FILE"

    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true
    fi
}

stage2() {
    require_regular_user
    require_atomic_host
    require_command rpm
    require_command sudo
    require_command systemctl
    require_command uname

    mapfile -t missing < <(missing_packages)
    if ((${#missing[@]} != 0)); then
        fatal "Required packages are not active yet: ${missing[*]}. Run Stage 1, reboot, and then retry Stage 2."
    fi

    local installer installer_rc pia_root
    installer="$(download_installer)"

    cat <<'NOTICE'

The official PIA installer will now run.

Do not run it with sudo. It will request your password itself where necessary.
On Fedora Atomic systems, an error about /usr/share/pixmaps or
/usr/share/applications being read-only is expected near the end. This script
will continue only if the actual PIA binaries were successfully extracted.
NOTICE

    if sh "$installer"; then
        installer_rc=0
    else
        installer_rc=$?
    fi

    if ((installer_rc != 0)); then
        warn "The official installer exited with code $installer_rc. This can be expected when it reaches Bazzite's read-only /usr directory."
    fi

    if ! pia_root="$(find_pia_root)"; then
        fatal "PIA's pia-daemon, pia-client, and piactl were not found under /var/opt/piavpn or /opt/piavpn. The installer failed before extracting the usable application."
    fi

    info "Found the extracted PIA application at $pia_root"
    install_service "$pia_root"
    install_desktop_entry "$pia_root"

    mkdir -p "$STATE_DIR"
    printf '%s\n' "$pia_root" > "$STATE_DIR/pia-root"
    printf '%s\n' "$installer" > "$STATE_DIR/installer-path"
    date -u +'%Y-%m-%dT%H:%M:%SZ' > "$STATE_DIR/stage2-complete"

    cat <<EOF2

${BOLD}PIA installation completed successfully.${RESET}

The daemon is active and will start automatically at boot.
Open "Private Internet Access" from the application menu, or run:

  ${pia_root}/bin/pia-client

Useful checks:

  systemctl status ${SERVICE_NAME} --no-pager
  ${pia_root}/bin/piactl get connectionstate

For Shadowsocks multi-hop, open PIA Settings and enable
"Multi-Hop and Obfuscation", then select Shadowsocks.
EOF2
}

main() {
    local mode="auto"
    case "${1:-}" in
        "") ;;
        --stage1) mode="stage1" ;;
        --stage2) mode="stage2" ;;
        --help|-h) usage; exit 0 ;;
        *) usage; fatal "Unknown option: $1" ;;
    esac

    if [[ "$mode" == "stage1" ]]; then
        stage1
    elif [[ "$mode" == "stage2" ]]; then
        stage2
    else
        require_regular_user
        require_atomic_host
        require_command rpm
        mapfile -t missing < <(missing_packages)
        if ((${#missing[@]} != 0)); then
            stage1
        else
            stage2
        fi
    fi
}

main "$@"
