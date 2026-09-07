#!/usr/bin/env bash
# install.sh — smc-gp-vpn installer
#
# Sets up the GlobalProtect CAS VPN integration for NetworkManager.
#
# What this script does:
#   1. Detects the distribution (Ubuntu / Arch-based incl. Omarchy)
#   2. Checks prerequisites
#   3. Selects the correct pre-built binary for the distribution
#   4. Prompts for configuration (portal, connection name, browser)
#   5. Writes ~/.config/smc-gp-vpn/config
#   6. Downloads the gpclient-smc binary from the fork release and verifies SHA-256
#   7. Installs gpclient-smc and smc-vpn-refresh to ~/.local/bin/
#   8. Installs 99-smc-cookie-refresh dispatcher (requires sudo)
#   9. Runs nm-profile-setup.py (creates or cleans the NM VPN profile)
#  10. Prints next steps
#
# Usage:
#   bash install.sh
#
# Supported: Ubuntu 24.04 / 26.04, Arch-based distributions (incl. Omarchy)

set -euo pipefail

# ── release base URL ─────────────────────────────────────────────────────────
# Update RELEASE_BASE when the upstream PR is merged and a new release is cut
# from yuezk/GlobalProtect-openconnect.
RELEASE_BASE="https://github.com/maksym-shaiev/GlobalProtect-openconnect/releases/download/gpclient-smc-latest"

# ── paths ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$HOME/.config/smc-gp-vpn"
CONFIG_FILE="$CONFIG_DIR/config"
BIN_DIR="$HOME/.local/bin"
DISPATCHER_DIR="/etc/NetworkManager/dispatcher.d"

# ── defaults ─────────────────────────────────────────────────────────────────
DEFAULT_PORTAL="us-access.stagwellglobal.com"
DEFAULT_CONN_NAME="SMC"
DEFAULT_BROWSER="chrome"

# ── colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${GREEN}[+]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[!]${RESET} $*"; }
error()   { echo -e "${RED}[✗]${RESET} $*" >&2; }
die()     { error "$*"; exit 1; }
section() { echo -e "\n${BOLD}── $* ──${RESET}"; }

# ── 1. detect distribution ────────────────────────────────────────────────────
section "Detecting distribution"

if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
fi

DISTRO=""
case "${ID:-}" in
    arch|omarchy) DISTRO="arch" ;;
    ubuntu)       DISTRO="ubuntu" ;;
    *)
        case "${ID_LIKE:-}" in
            *arch*)   DISTRO="arch" ;;
            *debian*) DISTRO="ubuntu" ;;
        esac
        ;;
esac

if [[ -z "$DISTRO" ]]; then
    die "Unsupported distribution: ${PRETTY_NAME:-${ID:-unknown}}\nSupported: Ubuntu 24.04/26.04, Arch-based (incl. Omarchy)"
fi

info "Detected: ${PRETTY_NAME:-$DISTRO} (distro=$DISTRO)"

# ── 2. prerequisites ─────────────────────────────────────────────────────────
section "Checking prerequisites"

MISSING=()
for cmd in python3 curl jq nmcli sudo notify-send; do
    if ! command -v "$cmd" &>/dev/null; then
        MISSING+=("$cmd")
    fi
done

# gi + NM introspection (python3-gi on Ubuntu, python-gobject on Arch)
if ! python3 -c "import gi; gi.require_version('NM','1.0'); from gi.repository import NM" &>/dev/null; then
    if [[ "$DISTRO" == "ubuntu" ]]; then
        MISSING+=("python3-gi (install: sudo apt install python3-gi gir1.2-nm-1.0)")
    else
        MISSING+=("python-gobject (install: sudo pacman -S python-gobject)")
    fi
fi

# network-manager-openconnect
if [[ "$DISTRO" == "ubuntu" ]]; then
    if ! dpkg -l network-manager-openconnect &>/dev/null; then
        MISSING+=("network-manager-openconnect (install: sudo apt install network-manager-openconnect)")
    fi
else
    if ! pacman -Q networkmanager-openconnect &>/dev/null; then
        MISSING+=("networkmanager-openconnect (install: sudo pacman -S networkmanager-openconnect)")
    fi
fi

if [[ ${#MISSING[@]} -gt 0 ]]; then
    error "Missing prerequisites:"
    for m in "${MISSING[@]}"; do echo "    • $m"; done
    die "Install the above packages and re-run install.sh"
fi

info "All prerequisites satisfied"

# ── 3. resolve binary suffix ──────────────────────────────────────────────────
section "Selecting binary for this system"

case "$DISTRO" in
    arch)
        BINARY_SUFFIX="arch"
        ;;
    ubuntu)
        if ! command -v lsb_release &>/dev/null; then
            MISSING+=("lsb_release (install: sudo apt install lsb-release)")
        fi
        UBUNTU_VERSION=$(lsb_release -rs)
        case "$UBUNTU_VERSION" in
            24.04) BINARY_SUFFIX="ubuntu24.04" ;;
            26.04) BINARY_SUFFIX="ubuntu26.04" ;;
            *)
                die "Unsupported Ubuntu version: $UBUNTU_VERSION\nSupported versions: 24.04, 26.04"
                ;;
        esac
        info "Detected Ubuntu $UBUNTU_VERSION"
        ;;
esac

# Each matrix job publishes its own checksum file to avoid race conditions
# when parallel jobs upload to the same release.
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

SUMS_URL="${RELEASE_BASE}/SHA256SUMS-${BINARY_SUFFIX}"

info "Fetching SHA256SUMS-${BINARY_SUFFIX} to resolve binary name …"
curl -fsSL -o "$TMP_DIR/SHA256SUMS" "$SUMS_URL" \
    || die "Failed to download SHA256SUMS from $SUMS_URL"

BINARY_NAME=$(awk '{print $2}' "$TMP_DIR/SHA256SUMS" | grep '^gpclient-smc_' | head -1)
AUTH_NAME=$(awk '{print $2}' "$TMP_DIR/SHA256SUMS" | grep '^gpauth-smc_' | head -1)
if [[ -z "$BINARY_NAME" || -z "$AUTH_NAME" ]]; then
    die "Could not resolve binary names from SHA256SUMS:\n$(cat "$TMP_DIR/SHA256SUMS")"
fi

BINARY_URL="${RELEASE_BASE}/${BINARY_NAME}"
AUTH_URL="${RELEASE_BASE}/${AUTH_NAME}"
info "Selected binaries:"
echo "    gpclient: $BINARY_NAME"
echo "    gpauth:   $AUTH_NAME"

# ── 4. interactive configuration ─────────────────────────────────────────────
section "Configuration"

prompt() {
    local var="$1" prompt="$2" default="$3"
    read -rp "  ${prompt} [${default}]: " value
    value="${value:-$default}"
    printf -v "$var" '%s' "$value"
}

prompt PORTAL    "Portal gateway"       "$DEFAULT_PORTAL"
prompt CONN_NAME "NM connection name"   "$DEFAULT_CONN_NAME"
prompt BROWSER   "Browser for CAS auth" "$DEFAULT_BROWSER"

echo
info "Configuration:"
echo "    PORTAL    = $PORTAL"
echo "    CONN_NAME = $CONN_NAME"
echo "    BROWSER   = $BROWSER"

# ── 5. write config ───────────────────────────────────────────────────────────
section "Writing config"

mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"

cat > "$CONFIG_FILE" <<EOF
# smc-gp-vpn configuration
# Generated by install.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)

PORTAL=$PORTAL
CONN_NAME=$CONN_NAME
BROWSER=$BROWSER
GPCLIENT_BIN=$BIN_DIR/gpclient-smc
GP_AUTH_BIN=$BIN_DIR/gpauth-smc
CACHE=$HOME/.config/gpclient/smc-cookie.json
EOF

chmod 600 "$CONFIG_FILE"
info "Config written to $CONFIG_FILE"

# ── 6. download binaries ──────────────────────────────────────────────────────
section "Downloading gpclient-smc binaries"

info "Downloading $BINARY_NAME …"
curl -fsSL --progress-bar -o "$TMP_DIR/gpclient-smc" "$BINARY_URL" \
    || die "Failed to download binary from $BINARY_URL"

info "Downloading $AUTH_NAME …"
curl -fsSL --progress-bar -o "$TMP_DIR/gpauth-smc" "$AUTH_URL" \
    || die "Failed to download gpauth from $AUTH_URL"

# ── 7. verify checksums ───────────────────────────────────────────────────────
section "Verifying checksums"

EXPECTED_CLIENT=$(awk -v n='gpclient-smc_' 'index($2, n) == 1 {print $1}' "$TMP_DIR/SHA256SUMS")
ACTUAL_CLIENT=$(sha256sum "$TMP_DIR/gpclient-smc" | awk '{print $1}')
if [[ "$EXPECTED_CLIENT" != "$ACTUAL_CLIENT" ]]; then
    die "SHA-256 mismatch (gpclient-smc)!\n  expected: $EXPECTED_CLIENT\n  actual:   $ACTUAL_CLIENT"
fi
info "gpclient-smc verified: $ACTUAL_CLIENT"

EXPECTED_AUTH=$(awk -v n='gpauth-smc_' 'index($2, n) == 1 {print $1}' "$TMP_DIR/SHA256SUMS")
ACTUAL_AUTH=$(sha256sum "$TMP_DIR/gpauth-smc" | awk '{print $1}')
if [[ "$EXPECTED_AUTH" != "$ACTUAL_AUTH" ]]; then
    die "SHA-256 mismatch (gpauth-smc)!\n  expected: $EXPECTED_AUTH\n  actual:   $ACTUAL_AUTH"
fi
info "gpauth-smc verified: $ACTUAL_AUTH"

# ── 8. install binaries ───────────────────────────────────────────────────────
section "Installing gpclient-smc"

mkdir -p "$BIN_DIR"
install -m 755 "$TMP_DIR/gpclient-smc" "$BIN_DIR/gpclient-smc"
info "Installed: $BIN_DIR/gpclient-smc"

section "Installing gpauth-smc"

install -m 755 "$TMP_DIR/gpauth-smc" "$BIN_DIR/gpauth-smc"
info "Installed: $BIN_DIR/gpauth-smc"

section "Installing smc-vpn-refresh"

install -m 755 "$SCRIPT_DIR/scripts/smc-vpn-refresh" "$BIN_DIR/smc-vpn-refresh"
info "Installed: $BIN_DIR/smc-vpn-refresh"

# Ensure ~/.local/bin is on PATH
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    warn "$BIN_DIR is not in your PATH."
    warn "Add the following to your shell profile (~/.bashrc, ~/.zshrc, ...):"
    warn '    export PATH="$HOME/.local/bin:$PATH"'
fi

# ── 9. install NM dispatcher ──────────────────────────────────────────────────
section "Installing NM dispatcher (requires sudo)"

sudo install -m 755 \
    "$SCRIPT_DIR/scripts/99-smc-cookie-refresh" \
    "$DISPATCHER_DIR/99-smc-cookie-refresh"
info "Installed: $DISPATCHER_DIR/99-smc-cookie-refresh"

# vpn-pre-down scripts must live in pre-down.d/ — NM only calls scripts from
# that directory for the vpn-pre-down event (clean disconnect / shutdown).
# A symlink avoids duplication; both locations point to the same file.
sudo mkdir -p "$DISPATCHER_DIR/pre-down.d"
sudo ln -sf \
    "$DISPATCHER_DIR/99-smc-cookie-refresh" \
    "$DISPATCHER_DIR/pre-down.d/99-smc-cookie-refresh"
info "Symlinked: $DISPATCHER_DIR/pre-down.d/99-smc-cookie-refresh"

# ── 10. NM profile setup ──────────────────────────────────────────────────────
section "Setting up NetworkManager VPN profile"

python3 "$SCRIPT_DIR/scripts/nm-profile-setup.py" --config "$CONFIG_FILE"

# ── done ──────────────────────────────────────────────────────────────────────
section "Installation complete"

cat <<EOF

${BOLD}Next step:${RESET}

  Run the following to authenticate and connect for the first time:

    ${GREEN}smc-vpn-refresh${RESET}

  This will open ${BROWSER} for CAS login, mint a gateway cookie,
  write it to the '${CONN_NAME}' NM profile, and bring the VPN up.

${BOLD}Daily use:${RESET}

  Flip the GNOME Network → VPN → ${CONN_NAME} toggle, or run:

    nmcli connection up ${CONN_NAME}      # connect
    nmcli connection down ${CONN_NAME}    # disconnect

  No dialog will appear. The cookie auto-refreshes on disconnect.

${BOLD}When the VPN stops connecting (portal session expired):${RESET}

    ${GREEN}smc-vpn-refresh${RESET}            (re-authenticates and reconnects)
    ${GREEN}smc-vpn-refresh --no-connect${RESET} (update secrets only)
    ${GREEN}smc-vpn-refresh --browser firefox${RESET}

EOF
