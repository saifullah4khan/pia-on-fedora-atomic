#!/usr/bin/env bash
# Install the full Private Internet Access desktop client on Bazzite and
# compatible Fedora Atomic desktops.
#
# This is an unofficial community workaround. Review this script before use.
# https://github.com/saifullah4khan/pia-on-fedora-atomic

set -Eeuo pipefail

PROJECT_VERSION="1.1.0"
PROJECT_NAME="pia-on-fedora-atomic"

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/${PROJECT_NAME}"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/${PROJECT_NAME}"

SERVICE_NAME="pia-vpn.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"

DESKTOP_FILE="$HOME/.local/share/applications/private-internet-access.desktop"
ICON_DIR="$HOME/.local/share/icons/hicolor/256x256/apps"
ICON_FILE="${ICON_DIR}/piavpn.png"
ICON_NAME="piavpn"
FALLBACK_ICON_NAME="network-vpn"

# PIA's own installer creates these two, but never reaches them on Fedora
# Atomic because it aborts earlier at the read-only /usr/share/pixmaps copy.
NM_CONF_DIR="/etc/NetworkManager/conf.d"
NM_CONF_FILE="${NM_CONF_DIR}/wgpia.conf"
PIACTL_SYMLINK="/usr/local/bin/piactl"

RELEASE_API="https://api.github.com/repos/pia-foss/desktop/releases/latest"
INSTALLER_HOST="privateinternetaccess-storage.s3.amazonaws.com"

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
    printf 'Run "./install.sh --verify" for a report you can paste into an issue.\n' >&2
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
  --verify       Check an existing installation and print a report
  --version      Show the version of this project
  --help         Show this help

Optional environment variables:
  PIA_INSTALLER_URL      Use a specific official PIA Linux .run installer
                         instead of resolving the newest stable release.
  PIA_INSTALLER_SHA256   Expected SHA-256 of the installer. When set, the
                         download is rejected unless the checksum matches.
  PIA_SKIP_ICON=1        Do not extract PIA's application icon. The launcher
                         falls back to the generic network-vpn icon.
  NO_COLOR=1             Disable colored output.
USAGE
}

# ---------------------------------------------------------------------------
# Environment checks
# ---------------------------------------------------------------------------

require_command() {
    command -v "$1" >/dev/null 2>&1 || fatal "Required command '$1' was not found."
}

# Read PRETTY_NAME in a subshell. Sourcing /etc/os-release directly would
# overwrite this script's own VERSION and NAME variables.
os_pretty_name() {
    [[ -r /etc/os-release ]] || return 0
    # shellcheck disable=SC1091
    ( . /etc/os-release && printf '%s' "${PRETTY_NAME:-}" ) 2>/dev/null || true
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

    local pretty
    pretty="$(os_pretty_name)"
    info "Detected ${pretty:-an rpm-ostree based Linux system}."
}

# ---------------------------------------------------------------------------
# Dependency detection
#
# PIA's installer checks for shared libraries rather than package names. This
# mirrors those checks so that only the packages a given Fedora Atomic image is
# actually missing get layered. On Bazzite that is normally just libnsl and
# xterm.
# ---------------------------------------------------------------------------

LDCONFIG_CACHE=""

load_ldconfig_cache() {
    [[ -n "$LDCONFIG_CACHE" ]] && return 0
    if command -v ldconfig >/dev/null 2>&1; then
        LDCONFIG_CACHE="$(ldconfig -p 2>/dev/null || true)"
    elif [[ -x /usr/sbin/ldconfig ]]; then
        LDCONFIG_CACHE="$(/usr/sbin/ldconfig -p 2>/dev/null || true)"
    fi
    return 0
}

have_soname() {
    load_ldconfig_cache
    [[ -n "$LDCONFIG_CACHE" ]] || return 0   # Cannot tell; assume present.
    grep -Fq -- "$1" <<<"$LDCONFIG_CACHE"
}

have_iptables() {
    command -v iptables >/dev/null 2>&1 || [[ -x /usr/sbin/iptables ]]
}

package_installed() {
    rpm -q "$1" >/dev/null 2>&1
}

# Prints one package name per line for every dependency that is not satisfied.
missing_packages() {
    local candidates=() pkg

    have_soname libnsl.so.1            || candidates+=(libnsl)
    command -v xterm >/dev/null 2>&1   || candidates+=(xterm)
    have_soname libxkbcommon.so.0      || candidates+=(libxkbcommon)
    have_soname libxkbcommon-x11.so.0  || candidates+=(libxkbcommon-x11)

    if ! have_soname libnl-3.so.200 \
       || ! have_soname libnl-route-3.so.200 \
       || ! have_soname libnl-genl-3.so.200; then
        candidates+=(libnl3)
    fi

    have_iptables || candidates+=(iptables-nft)

    # Never ask rpm-ostree to layer something that is already present.
    for pkg in "${candidates[@]+"${candidates[@]}"}"; do
        package_installed "$pkg" || printf '%s\n' "$pkg"
    done
}

save_layered_packages() {
    mkdir -p "$STATE_DIR"
    printf '%s\n' "$@" > "$STATE_DIR/layered-packages"
}

# ---------------------------------------------------------------------------
# Stage 1: layer host packages
# ---------------------------------------------------------------------------

stage1() {
    require_regular_user
    require_atomic_host
    require_command rpm
    require_command sudo

    local missing=()
    mapfile -t missing < <(missing_packages)

    if ((${#missing[@]} == 0)); then
        info "The required packages are already active. No dependency reboot is needed."
        printf '\nRun Stage 2 now:\n  ./install.sh --stage2\n'
        return 0
    fi

    info "The PIA client needs these host packages: ${missing[*]}"
    warn "Bazzite treats rpm-ostree layering as a last resort. These packages can be removed later with the included uninstall script."

    sudo rpm-ostree install "${missing[@]}"
    save_layered_packages "${missing[@]}"

    mkdir -p "$STATE_DIR"
    date -u +'%Y-%m-%dT%H:%M:%SZ' > "$STATE_DIR/stage1-complete"
    printf '%s\n' "$PROJECT_VERSION" > "$STATE_DIR/version"

    cat <<STAGE1_DONE

${BOLD}Stage 1 finished.${RESET}

A new deployment was created. Reboot to activate it:

  systemctl reboot

After logging back in, run the same installer again. It will detect the
packages and automatically continue with Stage 2.
STAGE1_DONE
}

# ---------------------------------------------------------------------------
# Installer download
# ---------------------------------------------------------------------------

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

verify_checksum() {
    local file="$1" expected="${PIA_INSTALLER_SHA256:-}"
    [[ -n "$expected" ]] || return 0

    require_command sha256sum
    local actual
    actual="$(sha256sum -- "$file" | awk '{print $1}')"
    if [[ "${actual,,}" != "${expected,,}" ]]; then
        rm -f -- "$file"
        fatal "Checksum mismatch. Expected $expected but the download is $actual."
    fi
    info "Installer checksum matches PIA_INSTALLER_SHA256."
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
        if ! curl --fail --silent --show-error --location \
            --retry 3 --retry-delay 2 \
            --header 'Accept: application/vnd.github+json' \
            --header "User-Agent: ${PROJECT_NAME}/${PROJECT_VERSION}" \
            "$RELEASE_API" > "$release_json"; then
            rm -f "$release_json"
            fatal "Could not reach the GitHub release API. Open https://github.com/pia-foss/desktop/releases, copy the current Linux .run URL, and rerun with PIA_INSTALLER_URL set."
        fi
        url="$(resolve_installer_url "$arch" "$release_json")"
        rm -f "$release_json"
    fi

    case "$url" in
        "https://${INSTALLER_HOST}/"*.run) ;;
        *)
            fatal "Refusing a non-PIA installer URL. Expected an official ${INSTALLER_HOST} .run file."
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
    verify_checksum "$destination"

    printf '%s\n' "$destination"
}

# ---------------------------------------------------------------------------
# Integration steps that PIA's installer never reaches on Fedora Atomic
# ---------------------------------------------------------------------------

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
        local backup
        backup="${path}.backup.$(date -u +%Y%m%dT%H%M%SZ)"
        info "Backing up existing $path to $backup"
        sudo cp --preserve=mode,ownership,timestamps "$path" "$backup"
    fi
}

install_service() {
    local pia_root="$1"
    backup_existing_file "$SERVICE_FILE"

    info "Creating the PIA systemd service."
    sudo tee "$SERVICE_FILE" >/dev/null <<SERVICE
[Unit]
Description=Private Internet Access VPN daemon
Documentation=https://github.com/saifullah4khan/pia-on-fedora-atomic
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Environment=LD_LIBRARY_PATH=${pia_root}/lib
ExecStart=${pia_root}/bin/pia-daemon
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SERVICE

    sudo chmod 0644 "$SERVICE_FILE"
    sudo systemctl daemon-reload
    sudo systemctl enable --now "$SERVICE_NAME"

    if ! systemctl is-active --quiet "$SERVICE_NAME"; then
        systemctl status "$SERVICE_NAME" --no-pager || true
        fatal "The PIA daemon service did not become active."
    fi
}

# PIA ships its application icon inside the .run payload and copies it to
# /usr/share/pixmaps, which is read-only here. Recover it from the installer
# archive and place it in the per-user icon theme instead.
install_icon() {
    local pia_root="$1" installer="$2"
    local source="" extract_dir="$CACHE_DIR/icon-extract"

    if [[ -n "${PIA_SKIP_ICON:-}" ]]; then
        info "PIA_SKIP_ICON is set. Using the generic ${FALLBACK_ICON_NAME} icon."
        return 1
    fi

    if [[ -f /usr/share/pixmaps/piavpn.png ]]; then
        source=/usr/share/pixmaps/piavpn.png
    else
        source="$(find "$pia_root/share" -maxdepth 3 -type f \
            \( -name 'app-icon.png' -o -name 'piavpn.png' \) -print -quit 2>/dev/null || true)"
    fi

    if [[ -z "$source" && -f "$installer" ]]; then
        info "Extracting PIA's application icon from the installer archive."
        rm -rf -- "$extract_dir"
        mkdir -p "$extract_dir"
        if sh "$installer" --noexec --keep --target "$extract_dir" >/dev/null 2>&1; then
            source="$(find "$extract_dir" -maxdepth 3 -type f -name 'app-icon.png' -print -quit 2>/dev/null || true)"
        fi
    fi

    if [[ -z "$source" || ! -f "$source" ]]; then
        rm -rf -- "$extract_dir"
        warn "Could not recover PIA's icon. The launcher will use the generic ${FALLBACK_ICON_NAME} icon."
        return 1
    fi

    mkdir -p "$ICON_DIR"
    install -m 0644 -- "$source" "$ICON_FILE"
    rm -rf -- "$extract_dir"

    mkdir -p "$STATE_DIR"
    printf '%s\n' "$ICON_FILE" > "$STATE_DIR/icon-file"

    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
        gtk-update-icon-cache --force --quiet "$HOME/.local/share/icons/hicolor" >/dev/null 2>&1 || true
    fi

    info "Installed PIA's application icon into your user icon theme."
    return 0
}

install_desktop_entry() {
    local pia_root="$1" icon="$2"
    mkdir -p "$(dirname "$DESKTOP_FILE")"

    if [[ -e "$DESKTOP_FILE" ]]; then
        cp "$DESKTOP_FILE" "${DESKTOP_FILE}.backup.$(date -u +%Y%m%dT%H%M%SZ)"
    fi

    info "Creating a per-user application-menu entry."
    cat > "$DESKTOP_FILE" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Private Internet Access
GenericName=VPN Client
Comment=Connect to the Private Internet Access VPN
Exec=${pia_root}/bin/pia-client
TryExec=${pia_root}/bin/pia-client
Icon=${icon}
Terminal=false
Categories=Network;Security;
Keywords=VPN;PIA;Privacy;WireGuard;
StartupNotify=true
StartupWMClass=pia-client
DESKTOP
    chmod 0644 "$DESKTOP_FILE"

    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true
    fi
}

# Without this, NetworkManager can take over the wgpia* interface and drop the
# DNS settings PIA applies to it when the network changes.
install_nm_config() {
    if [[ ! -d "$NM_CONF_DIR" ]]; then
        info "NetworkManager is not configured on this system. Skipping the WireGuard interface rule."
        return 0
    fi

    if [[ -e "$NM_CONF_FILE" ]]; then
        info "The NetworkManager rule for wgpia interfaces already exists."
        return 0
    fi

    info "Telling NetworkManager to leave PIA's WireGuard interfaces alone."
    printf '[keyfile]\nunmanaged-devices=interface-name:wgpia*\n' \
        | sudo tee "$NM_CONF_FILE" >/dev/null
    sudo chmod 0644 "$NM_CONF_FILE"

    mkdir -p "$STATE_DIR"
    printf '%s\n' "$NM_CONF_FILE" > "$STATE_DIR/created-nm-config"

    if systemctl is-active --quiet NetworkManager; then
        sudo systemctl reload NetworkManager >/dev/null 2>&1 || true
    fi
}

install_piactl_symlink() {
    local pia_root="$1"
    local target="${pia_root}/bin/piactl"

    if [[ -L "$PIACTL_SYMLINK" ]]; then
        local existing
        existing="$(readlink -- "$PIACTL_SYMLINK" || true)"
        if [[ "$existing" == "$target" ]]; then
            info "piactl is already on your PATH."
        else
            warn "$PIACTL_SYMLINK already points at $existing. Leaving it alone."
        fi
        return 0
    fi

    if [[ -e "$PIACTL_SYMLINK" ]]; then
        warn "$PIACTL_SYMLINK already exists and is not a symlink. Leaving it alone."
        return 0
    fi

    sudo mkdir -p "$(dirname "$PIACTL_SYMLINK")"
    if sudo ln -s -- "$target" "$PIACTL_SYMLINK"; then
        mkdir -p "$STATE_DIR"
        printf '%s\n' "$PIACTL_SYMLINK" > "$STATE_DIR/created-piactl-symlink"
        info "Linked piactl into $(dirname "$PIACTL_SYMLINK")."
    else
        warn "Could not create $PIACTL_SYMLINK. Use ${target} directly instead."
    fi
}

# ---------------------------------------------------------------------------
# Stage 2: install and integrate the client
# ---------------------------------------------------------------------------

stage2() {
    require_regular_user
    require_atomic_host
    require_command rpm
    require_command sudo
    require_command systemctl
    require_command uname

    local missing=()
    mapfile -t missing < <(missing_packages)
    if ((${#missing[@]} != 0)); then
        fatal "Required packages are not active yet: ${missing[*]}. Run Stage 1, reboot, and then retry Stage 2."
    fi

    local installer installer_rc pia_root desktop_icon
    installer="$(download_installer)"

    cat <<'NOTICE'

The official PIA installer will now run.

Do not run it with sudo. It will request your password itself where necessary.
On Fedora Atomic systems, an error about /usr/share/pixmaps being read-only is
expected near the end. This script will continue only if the actual PIA
binaries were successfully extracted.
NOTICE

    if sh "$installer"; then
        installer_rc=0
    else
        installer_rc=$?
    fi

    if ((installer_rc != 0)); then
        warn "The official installer exited with code $installer_rc. This is expected when it reaches Bazzite's read-only /usr directory."
    fi

    if ! pia_root="$(find_pia_root)"; then
        fatal "PIA's pia-daemon, pia-client, and piactl were not found under /var/opt/piavpn or /opt/piavpn. The installer failed before extracting the usable application."
    fi

    info "Found the extracted PIA application at $pia_root"

    install_service "$pia_root"

    desktop_icon="$FALLBACK_ICON_NAME"
    if install_icon "$pia_root" "$installer"; then
        desktop_icon="$ICON_NAME"
    fi

    install_desktop_entry "$pia_root" "$desktop_icon"
    install_nm_config
    install_piactl_symlink "$pia_root"

    mkdir -p "$STATE_DIR"
    printf '%s\n' "$pia_root" > "$STATE_DIR/pia-root"
    printf '%s\n' "$installer" > "$STATE_DIR/installer-path"
    printf '%s\n' "$PROJECT_VERSION" > "$STATE_DIR/version"
    date -u +'%Y-%m-%dT%H:%M:%SZ' > "$STATE_DIR/stage2-complete"

    cat <<STAGE2_DONE

${BOLD}PIA installation completed successfully.${RESET}

The daemon is active and will start automatically at boot.
Open "Private Internet Access" from the application menu, or run:

  ${pia_root}/bin/pia-client

Useful checks:

  ./install.sh --verify
  piactl get connectionstate

For Shadowsocks multi-hop, open PIA Settings and enable
"Multi-Hop and Obfuscation", then select Shadowsocks.
STAGE2_DONE
}

# ---------------------------------------------------------------------------
# Verification report
# ---------------------------------------------------------------------------

VERIFY_FAILURES=0

check_pass() { printf '  %s[ ok ]%s %s\n' "$GREEN" "$RESET" "$*"; }
check_warn() { printf '  %s[warn]%s %s\n' "$YELLOW" "$RESET" "$*"; }
check_fail() { printf '  %s[fail]%s %s\n' "$RED" "$RESET" "$*"; VERIFY_FAILURES=$((VERIFY_FAILURES + 1)); }

verify() {
    local pia_root="" missing=() os_name

    os_name="$(os_pretty_name)"
    os_name="${os_name:-unknown}"

    printf '%s%s %s verification report%s\n\n' "$BOLD" "$PROJECT_NAME" "$PROJECT_VERSION" "$RESET"
    printf '  System:       %s\n' "$os_name"
    printf '  Architecture: %s\n' "$(uname -m)"
    printf '  Kernel:       %s\n\n' "$(uname -r)"

    printf '%sHost%s\n' "$BOLD" "$RESET"
    if command -v rpm-ostree >/dev/null 2>&1 && rpm-ostree status >/dev/null 2>&1; then
        check_pass "rpm-ostree system"
    else
        check_fail "not an active rpm-ostree system"
    fi

    if command -v rpm >/dev/null 2>&1; then
        mapfile -t missing < <(missing_packages)
        if ((${#missing[@]} == 0)); then
            check_pass "all PIA host dependencies are satisfied"
        else
            check_fail "missing host packages: ${missing[*]} (run ./install.sh --stage1, then reboot)"
        fi
    fi
    printf '\n'

    printf '%sPIA application%s\n' "$BOLD" "$RESET"
    if pia_root="$(find_pia_root)"; then
        check_pass "binaries present at $pia_root"
    else
        check_fail "pia-daemon, pia-client, or piactl missing under /var/opt/piavpn"
    fi
    printf '\n'

    printf '%sIntegration%s\n' "$BOLD" "$RESET"
    if [[ -f "$SERVICE_FILE" ]]; then
        check_pass "service file $SERVICE_FILE"
    else
        check_fail "service file $SERVICE_FILE is missing"
    fi

    if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
        check_pass "$SERVICE_NAME is enabled at boot"
    else
        check_fail "$SERVICE_NAME is not enabled"
    fi

    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        check_pass "$SERVICE_NAME is running"
    else
        check_fail "$SERVICE_NAME is not running (journalctl -u $SERVICE_NAME -n 50 --no-pager)"
    fi

    if [[ -f "$DESKTOP_FILE" ]]; then
        check_pass "application launcher installed"
    else
        check_fail "application launcher is missing"
    fi

    if [[ -f "$ICON_FILE" ]]; then
        check_pass "PIA application icon installed"
    else
        check_warn "using the generic ${FALLBACK_ICON_NAME} icon"
    fi

    if [[ ! -d "$NM_CONF_DIR" ]]; then
        check_warn "NetworkManager is not in use on this system"
    elif [[ -f "$NM_CONF_FILE" ]]; then
        check_pass "NetworkManager leaves wgpia interfaces unmanaged"
    else
        check_warn "$NM_CONF_FILE is missing; NetworkManager may clear DNS on the WireGuard interface (rerun ./install.sh --stage2)"
    fi

    if [[ -L "$PIACTL_SYMLINK" ]]; then
        check_pass "piactl is on your PATH"
    else
        check_warn "piactl is not linked into $(dirname "$PIACTL_SYMLINK")"
    fi
    printf '\n'

    printf '%sConnection%s\n' "$BOLD" "$RESET"
    if [[ -n "$pia_root" && -x "$pia_root/bin/piactl" ]]; then
        local state
        state="$("$pia_root/bin/piactl" get connectionstate 2>/dev/null || true)"
        if [[ -n "$state" ]]; then
            check_pass "connection state: $state"
        else
            check_warn "piactl could not report a connection state (is the client signed in?)"
        fi
    else
        check_warn "piactl is unavailable"
    fi
    printf '\n'

    if ((VERIFY_FAILURES == 0)); then
        printf '%sNo failures found.%s\n' "$GREEN" "$RESET"
        return 0
    fi

    printf '%s%s check(s) failed.%s Paste this report into an issue if you need help.\n' \
        "$RED" "$VERIFY_FAILURES" "$RESET"
    return 1
}

# ---------------------------------------------------------------------------

main() {
    local mode="auto"

    while (($#)); do
        case "$1" in
            --stage1)       mode="stage1" ;;
            --stage2)       mode="stage2" ;;
            --verify)       mode="verify" ;;
            --version|-V)   printf '%s %s\n' "$PROJECT_NAME" "$PROJECT_VERSION"; exit 0 ;;
            --help|-h)      usage; exit 0 ;;
            *)              usage >&2; fatal "Unknown option: $1" ;;
        esac
        shift
    done

    case "$mode" in
        stage1) stage1 ;;
        stage2) stage2 ;;
        verify) trap - ERR; verify ;;
        *)
            require_regular_user
            require_atomic_host
            require_command rpm
            local missing=()
            mapfile -t missing < <(missing_packages)
            if ((${#missing[@]} != 0)); then
                stage1
            else
                stage2
            fi
            ;;
    esac
}

main "$@"
