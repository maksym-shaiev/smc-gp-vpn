#!/usr/bin/env bash
# uninstall.sh — smc-gp-vpn uninstaller
#
# Removes the GlobalProtect CAS VPN integration for NetworkManager.
#
# What this script removes:
#   1. Binaries from ~/.local/bin/
#   2. Config from ~/.config/smc-gp-vpn/ and ~/.config/gpclient/
#   3. NM dispatcher script from /etc/NetworkManager/dispatcher.d/
#
# What this script does NOT remove by default:
#   - NM VPN profiles (one per endpoint, e.g. SMC-UK / SMC-US) — see --remove-profile
#   - Omarchy bar widget (gp-vpn) — separate uninstaller
#
# Usage:
#   bash uninstall.sh [--remove-profile]

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${GREEN}[+]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[!]${RESET} $*"; }
error()   { echo -e "${RED}[✗]${RESET} $*" >&2; }
die()     { error "$*"; exit 1; }
section() { echo -e "\n${BOLD}── $* ──${RESET}"; }

REMOVE_PROFILE=0

# ── 0. parse arguments ───────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
    --remove-profile)
        REMOVE_PROFILE=1
        shift
        ;;
    -h | --help)
        echo "Usage: bash uninstall.sh [--remove-profile]"
        exit 0
        ;;
    *)
        die "unknown argument: $1"
        ;;
    esac
done

# Collect the NM connection names of all configured endpoints (before the
# config is removed in step 3) so --remove-profile can delete each of them.
CONN_NAMES=()
SMC_CONFIG="$HOME/.config/smc-gp-vpn/config"
if [[ -r "$SMC_CONFIG" ]]; then
    if grep -q '^ENDPOINTS=' "$SMC_CONFIG"; then
        mapfile -t CONN_NAMES < <(awk -F= '/^ENDPOINT_[A-Z0-9_]+_CONN_NAME=/{print $2}' "$SMC_CONFIG" | sort -u)
    else
        mapfile -t CONN_NAMES < <(awk -F= '$1=="CONN_NAME"{print $2}' "$SMC_CONFIG")
    fi
fi

# ── 1. confirmation ──────────────────────────────────────────────────────────
section "Uninstall smc-gp-vpn"

read -rp "  Are you sure you want to uninstall smc-gp-vpn? [y/N]: " confirm
confirm="${confirm:-N}"
if [[ ! "$confirm" =~ ^[Yy] ]]; then
    info "Aborted"
    exit 0
fi

# ── 2. remove binaries ───────────────────────────────────────────────────────
section "Removing binaries"

BIN_DIR="$HOME/.local/bin"
for bin in gpclient-smc gpauth-smc smc-vpn-refresh smc-vpn-open-url; do
    if [[ -f "$BIN_DIR/$bin" ]]; then
        rm -f "$BIN_DIR/$bin"
        info "Removed $BIN_DIR/$bin"
    else
        warn "$BIN_DIR/$bin does not exist — skipping"
    fi
done

# ── 3. remove config ─────────────────────────────────────────────────────────
section "Removing config"

CONFIG_DIR="$HOME/.config/smc-gp-vpn"
if [[ -d "$CONFIG_DIR" ]]; then
    rm -rf "$CONFIG_DIR"
    info "Removed $CONFIG_DIR"
else
    warn "$CONFIG_DIR does not exist — skipping"
fi

# Only remove this tool's own cookie files from ~/.config/gpclient — the
# directory may also hold unrelated gpclient data (e.g. the GUI app's state)
# that we must not touch.
GPCLIENT_DIR="$HOME/.config/gpclient"
if [[ -d "$GPCLIENT_DIR" ]]; then
    found=0
    while IFS= read -r -d '' cookie; do
        rm -f "$cookie"
        info "Removed $cookie"
        found=1
    done < <(find "$GPCLIENT_DIR" -maxdepth 1 -name 'smc-cookie-*.json' -print0)
    if [[ $found -eq 1 ]] && [[ -z "$(ls -A "$GPCLIENT_DIR")" ]]; then
        rmdir "$GPCLIENT_DIR"
        info "Removed empty $GPCLIENT_DIR"
    else
        warn "$GPCLIENT_DIR kept (contains other gpclient data)"
    fi
else
    warn "$GPCLIENT_DIR does not exist — skipping"
fi

# ── 4. remove dispatcher (requires sudo) ─────────────────────────────────────
section "Removing NM dispatcher (requires sudo)"

DISPATCHER_DIR="/etc/NetworkManager/dispatcher.d"
if [[ -f "$DISPATCHER_DIR/99-smc-cookie-refresh" ]]; then
    sudo rm -f "$DISPATCHER_DIR/99-smc-cookie-refresh"
    info "Removed $DISPATCHER_DIR/99-smc-cookie-refresh"
else
    warn "$DISPATCHER_DIR/99-smc-cookie-refresh does not exist — skipping"
fi

PRE_DOWN_DIR="$DISPATCHER_DIR/pre-down.d"
if [[ -L "$PRE_DOWN_DIR/99-smc-cookie-refresh" ]]; then
    sudo rm -f "$PRE_DOWN_DIR/99-smc-cookie-refresh"
    info "Removed $PRE_DOWN_DIR/99-smc-cookie-refresh"
else
    warn "$PRE_DOWN_DIR/99-smc-cookie-refresh does not exist — skipping"
fi

# ── 5. optional: remove NM profiles ──────────────────────────────────────────
if [[ $REMOVE_PROFILE -eq 1 ]]; then
    section "Removing NM VPN profiles"

    if [[ ${#CONN_NAMES[@]} -eq 0 ]]; then
        CONN_NAMES=("SMC")
    fi

    if python3 -c "import gi; gi.require_version('NM','1.0'); from gi.repository import NM, GLib" &>/dev/null; then
        python3 - "${CONN_NAMES[@]}" <<'EOF'
import sys
import gi
gi.require_version('NM', '1.0')
from gi.repository import NM

names = sys.argv[1:]
client = NM.Client.new(None)
for name in names:
    conn = client.get_connection_by_id(name)
    if conn:
        conn.delete()
        print(f"Removed NM connection '{name}'")
    else:
        print(f"NM connection '{name}' not found")
EOF
    else
        warn "python3-gi not available — cannot remove NM profiles"
        warn "Remove them manually: nmcli connection delete <name>"
    fi
fi

# ── 6. done ──────────────────────────────────────────────────────────────────
section "Uninstall complete"

echo -e ""
echo -e "${BOLD}smc-gp-vpn has been removed.${RESET}"
echo -e ""
echo -e "${BOLD}Optional cleanup:${RESET}"
echo -e ""
echo -e "  Remove the NM VPN profiles (if not already done):"
echo -e ""
echo -e "    ${GREEN}nmcli connection delete SMC-UK SMC-US${RESET}"
echo -e ""
echo -e "  Remove the Omarchy bar widget (if installed):"
echo -e ""
echo -e "    ${GREEN}omarchy plugin remove gp-vpn${RESET}"
echo -e ""
echo -e "  Or run the widget's uninstaller:"
echo -e ""
echo -e "    ${GREEN}bash <(curl -sL https://raw.githubusercontent.com/maksym-shaiev/gp-vpn-omarchy/main/uninstall.sh)${RESET}"
echo -e ""
echo -e "${BOLD}Reinstall:${RESET}"
echo -e ""
echo -e "    ${GREEN}git clone https://github.com/maksym-shaiev/smc-gp-vpn.git${RESET}"
echo -e "    ${GREEN}cd smc-gp-vpn && bash install.sh${RESET}"
echo -e ""
