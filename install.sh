#!/usr/bin/env bash
# install.sh — smc-gp-vpn installer
#
# Sets up the GlobalProtect CAS VPN integration for NetworkManager.
#
# What this script does:
#   1. Detects the distribution (Ubuntu / Arch-based incl. Omarchy)
#   2. Checks prerequisites (incl. globalprotect-openconnect >= 3.3.0,
#      which ships the upstream `--cookie-only` capability)
#   3. Prompts for configuration (endpoints, portals, connection names, browser)
#   4. Writes ~/.config/smc-gp-vpn/config (one NM profile per endpoint)
#   5. Installs smc-vpn-refresh to ~/.local/bin/
#   6. Installs 99-smc-cookie-refresh dispatcher (requires sudo)
#   7. Runs nm-profile-setup.py (creates or cleans the NM VPN profiles)
#   8. Prints next steps
#
# Usage:
#   bash install.sh
#
# Supported: Ubuntu 24.04 / 26.04, Arch-based distributions (incl. Omarchy)

set -euo pipefail

# ── paths ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$HOME/.config/smc-gp-vpn"
CONFIG_FILE="$CONFIG_DIR/config"
BIN_DIR="$HOME/.local/bin"
DISPATCHER_DIR="/etc/NetworkManager/dispatcher.d"

# ── defaults ─────────────────────────────────────────────────────────────────
DEFAULT_ENDPOINTS="UK,US"
DEFAULT_BROWSER="chrome"

# Well-known portal defaults per endpoint id (unknown ids prompt empty and
# fall back to the legacy PORTAL from a previous config, if any).
known_portal_default() {
    case "$1" in
        UK) echo "uk-access.stagwellglobal.com" ;;
        US) echo "us-access.stagwellglobal.com" ;;
        *)  echo "" ;;
    esac
}

# Gateway-mode default per endpoint id: CAS gateways that reject the portal
# login result at the gateway (forcing a second browser login) authenticate
# directly against the gateway instead (--as-gateway). UK does; US doesn't.
known_as_gateway_default() {
    case "$1" in
        UK) echo "yes" ;;
        *)  echo "no" ;;
    esac
}

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
for cmd in python3 nmcli sudo notify-send; do
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

# globalprotect-openconnect >= 3.3.0 — upstream gpclient with `--cookie-only`
# (authenticates, prints COOKIE=/HOST=, exits without opening a tunnel).
GPCLIENT=""
if command -v gpclient &>/dev/null; then
    GPCLIENT="$(command -v gpclient)"
    if ! "$GPCLIENT" connect --help 2>&1 | grep -q -- '--cookie-only'; then
        MISSING+=("globalprotect-openconnect >= 3.3.0 (${GPCLIENT} lacks --cookie-only; upgrade the package)")
    fi
else
    if [[ "$DISTRO" == "ubuntu" ]]; then
        MISSING+=("globalprotect-openconnect (install: sudo apt install globalprotect-openconnect)")
    else
        MISSING+=("globalprotect-openconnect (install: sudo pacman -S globalprotect-openconnect)")
    fi
fi

if [[ ${#MISSING[@]} -gt 0 ]]; then
    error "Missing prerequisites:"
    for m in "${MISSING[@]}"; do echo "    • $m"; done
    die "Install the above packages and re-run install.sh"
fi

info "All prerequisites satisfied (gpclient: ${GPCLIENT})"

# ── 3. interactive configuration ─────────────────────────────────────────────
section "Configuration"

prompt() {
    local var="$1" prompt="$2" default="$3"
    read -rp "  ${prompt} [${default}]: " value
    value="${value:-$default}"
    printf -v "$var" '%s' "$value"
}

CONFIG_STATE=0   # 0 = no config, 1 = legacy single-endpoint, 2 = multi-endpoint
LEGACY_PORTAL="" LEGACY_BROWSER="" LEGACY_BROWSER_PROFILE=""
if [[ -r "$CONFIG_FILE" ]]; then
    if grep -q '^ENDPOINTS=' "$CONFIG_FILE"; then
        CONFIG_STATE=2
    else
        CONFIG_STATE=1
        LEGACY_PORTAL=$(awk -F= '$1=="PORTAL"{print $2}' "$CONFIG_FILE")
        LEGACY_BROWSER=$(awk -F= '$1=="BROWSER"{print $2}' "$CONFIG_FILE")
        LEGACY_BROWSER_PROFILE=$(awk -F= '$1=="BROWSER_PROFILE"{print $2}' "$CONFIG_FILE")
    fi
fi

if [[ $CONFIG_STATE -eq 2 ]]; then
    info "Using existing multi-endpoint config at $CONFIG_FILE"
    grep -E '^(ENDPOINTS|DEFAULT_ENDPOINT|ENDPOINT_[A-Z0-9_]+_(PORTAL|CONN_NAME|AS_GATEWAY))=' "$CONFIG_FILE" \
        | sed 's/^/    /'
else
    if [[ $CONFIG_STATE -eq 1 ]]; then
        warn "Found legacy single-endpoint config — it will be upgraded to multi-endpoint."
    fi

    prompt EP_LIST  "Endpoints to configure (comma-separated ids)" "$DEFAULT_ENDPOINTS"
    # Normalise: uppercase, keep [A-Z0-9_,] only, collapse duplicate commas
    EP_LIST=$(echo "$EP_LIST" | tr '[:lower:]' '[:upper:]' | tr -cd 'A-Z0-9_,' | sed 's/,\+/,/g; s/^,//; s/,$//')
    if [[ -z "$EP_LIST" ]]; then
        die "At least one endpoint is required."
    fi

    BROWSER=""
    prompt BROWSER "Browser for CAS auth" "${LEGACY_BROWSER:-$DEFAULT_BROWSER}"

    # Optional: pin the CAS sign-in to a specific Chrome/Chromium profile.
    # The value may be the profile dir key, its display name or the account
    # email; empty keeps the browser's default profile handling.
    BROWSER_PROFILES_HINT=""
    case "$BROWSER" in
        chrome|chromium)
            BROWSER_PROFILES_HINT=$(python3 - "$BROWSER" <<'PYEOF'
import json, os, sys
base = {"chrome": os.path.expanduser("~/.config/google-chrome"),
        "chromium": os.path.expanduser("~/.config/chromium")}[sys.argv[1]]
try:
    info = json.load(open(os.path.join(base, "Local State")))["profile"]["info_cache"]
    items = [f"{k} ({v.get('name', '')}{', ' + v['user_name'] if v.get('user_name') else ''})"
             for k, v in info.items()]
    print("; ".join(items) if items else "<none found>")
except Exception:
    print("<none found>")
PYEOF
)
            echo -e "  Detected ${BROWSER} profiles: ${BROWSER_PROFILES_HINT}"
            ;;
    esac
    BROWSER_PROFILE=""
    prompt BROWSER_PROFILE "Browser profile for CAS auth (dir, name or email; empty = default)" \
        "${LEGACY_BROWSER_PROFILE:-}"

    EP_IDS=() EP_PORTALS=() EP_CONNS=() EP_CACHES=() EP_ASGW=() EP_PROFILES=()
    for eid in ${EP_LIST//,/ }; do
        def_portal="$(known_portal_default "$eid")"
        if [[ -z "$def_portal" && -n "$LEGACY_PORTAL" ]]; then
            def_portal="$LEGACY_PORTAL"
        fi
        PORTAL=""
        prompt PORTAL "Portal gateway for [$eid]" "$def_portal"
        if [[ -z "$PORTAL" ]]; then
            die "Portal for [$eid] is required."
        fi
        CONN_NAME=""
        prompt CONN_NAME "NM connection name for [$eid]" "SMC-$eid"
        if [[ -z "$CONN_NAME" ]]; then
            die "Connection name for [$eid] is required."
        fi
        EP_IDS+=("$eid")
        EP_PORTALS+=("$PORTAL")
        EP_CONNS+=("$CONN_NAME")
        EP_CACHES+=("$HOME/.config/gpclient/smc-cookie-$(echo "$eid" | tr '[:upper:]' '[:lower:]').json")
        EP_ASGW+=("$(known_as_gateway_default "$eid")")
        EP_PROFILE=""
        prompt EP_PROFILE "Browser profile for [$eid] (empty = global '${BROWSER_PROFILE:-default}')" \
            "$BROWSER_PROFILE"
        EP_PROFILES+=("$EP_PROFILE")
    done

    FIRST_EP="${EP_IDS[0]}"
    DEFAULT_EP=""
    prompt DEFAULT_EP "Default endpoint" "$FIRST_EP"
    DEFAULT_EP=$(echo "$DEFAULT_EP" | tr '[:lower:]' '[:upper:]')
    DEFAULT_EP="${DEFAULT_EP//[^A-Z0-9_]/}"
    FOUND_DEFAULT=0
    for eid in "${EP_IDS[@]}"; do
        [[ "$eid" == "$DEFAULT_EP" ]] && FOUND_DEFAULT=1
    done
    if [[ $FOUND_DEFAULT -eq 0 ]]; then
        die "Default endpoint '$DEFAULT_EP' is not in the endpoint list: ${EP_LIST}"
    fi

    echo
    info "Configuration:"
    echo "    BROWSER          = $BROWSER"
    echo "    BROWSER_PROFILE  = ${BROWSER_PROFILE:-<browser default>}"
    echo "    DEFAULT_ENDPOINT = $DEFAULT_EP"
    for i in "${!EP_IDS[@]}"; do
        echo "    [${EP_IDS[$i]}] portal=${EP_PORTALS[$i]}  conn=${EP_CONNS[$i]}  gateway-auth=${EP_ASGW[$i]}"
    done
fi

# ── 4. write config ──────────────────────────────────────────────────────────
section "Writing config"

if [[ $CONFIG_STATE -ne 2 ]]; then
    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR"

    {
        echo "# smc-gp-vpn configuration"
        echo "# Generated by install.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo
        echo "BROWSER=$BROWSER"
        if [[ -n "$BROWSER_PROFILE" ]]; then
            echo "BROWSER_PROFILE=$BROWSER_PROFILE"
        fi
        echo "DEFAULT_ENDPOINT=$DEFAULT_EP"
        echo "ENDPOINTS=$EP_LIST"
        DEF_PORTAL="" DEF_CONN="" DEF_CACHE=""
        for i in "${!EP_IDS[@]}"; do
            echo "ENDPOINT_${EP_IDS[$i]}_PORTAL=${EP_PORTALS[$i]}"
            echo "ENDPOINT_${EP_IDS[$i]}_CONN_NAME=${EP_CONNS[$i]}"
            echo "ENDPOINT_${EP_IDS[$i]}_CACHE=${EP_CACHES[$i]}"
            echo "ENDPOINT_${EP_IDS[$i]}_AS_GATEWAY=${EP_ASGW[$i]}"
            # Per-endpoint overrides are only written when they differ from
            # the global profile — absence already means "use the global one".
            if [[ -n "${EP_PROFILES[$i]}" && "${EP_PROFILES[$i]}" != "$BROWSER_PROFILE" ]]; then
                echo "ENDPOINT_${EP_IDS[$i]}_BROWSER_PROFILE=${EP_PROFILES[$i]}"
            fi
            if [[ "${EP_IDS[$i]}" == "$DEFAULT_EP" ]]; then
                DEF_PORTAL="${EP_PORTALS[$i]}"
                DEF_CONN="${EP_CONNS[$i]}"
                DEF_CACHE="${EP_CACHES[$i]}"
            fi
        done
        # Legacy keys duplicated from the default endpoint — older tooling
        # (previous widget versions, custom scripts) still reads PORTAL/CONN_NAME.
        echo "PORTAL=$DEF_PORTAL"
        echo "CONN_NAME=$DEF_CONN"
        echo "CACHE=$DEF_CACHE"
    } > "$CONFIG_FILE"

    chmod 600 "$CONFIG_FILE"
else
    # Existing multi-endpoint config — append gateway-mode defaults for
    # endpoints written before ENDPOINT_<ID>_AS_GATEWAY existed. Existing
    # keys (and cookies) are left untouched.
    _updated=0
    while IFS= read -r eid; do
        eid="$(echo "$eid" | tr -cd 'A-Z0-9_')"
        [[ -z "$eid" ]] && continue
        if ! grep -q "^ENDPOINT_${eid}_AS_GATEWAY=" "$CONFIG_FILE"; then
            _asgw="$(known_as_gateway_default "$eid")"
            echo "ENDPOINT_${eid}_AS_GATEWAY=$_asgw" >> "$CONFIG_FILE"
            info "Added ENDPOINT_${eid}_AS_GATEWAY=$_asgw"
            _updated=1
        fi
    done < <(awk -F= '$1=="ENDPOINTS"{print $2}' "$CONFIG_FILE" | tr ',' '\n')
    if [[ $_updated -eq 1 ]]; then
        chmod 600 "$CONFIG_FILE"
    fi
fi
info "Config ready at $CONFIG_FILE"

# ── 5. install smc-vpn-refresh ────────────────────────────────────────────────
section "Installing smc-vpn-refresh"

install -m 755 "$SCRIPT_DIR/scripts/smc-vpn-refresh" "$BIN_DIR/smc-vpn-refresh"
install -m 755 "$SCRIPT_DIR/scripts/smc-vpn-open-url" "$BIN_DIR/smc-vpn-open-url"
info "Installed: $BIN_DIR/smc-vpn-refresh"

# Ensure ~/.local/bin is on PATH
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    warn "$BIN_DIR is not in your PATH."
    warn "Add the following to your shell profile (~/.bashrc, ~/.zshrc, ...):"
    warn '    export PATH="$HOME/.local/bin:$PATH"'
fi

# ── 6. install NM dispatcher ──────────────────────────────────────────────────
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

# ── 7. NM profile setup ──────────────────────────────────────────────────────
section "Setting up NetworkManager VPN profile"

python3 "$SCRIPT_DIR/scripts/nm-profile-setup.py" --config "$CONFIG_FILE"

# ── 8. Omarchy bar widget (Omarchy only) ─────────────────────────────────────
OMARCHY_WIDGET_URL="https://github.com/maksym-shaiev/gp-vpn-omarchy.git"

IS_OMARCHY=0
if [[ "$DISTRO" == "arch" && -n "$(command -v omarchy-shell 2>/dev/null || true)" ]]; then
    IS_OMARCHY=1
fi

if [[ $IS_OMARCHY -eq 1 ]]; then
    section "Omarchy bar widget (Omarchy only)"
    read -rp "  Install the Omarchy bar widget (gp-vpn)? [Y/n]: " want_widget
    want_widget="${want_widget:-Y}"
    if [[ "$want_widget" =~ ^[Yy] ]]; then
        if command -v omarchy-plugin-add &>/dev/null; then
            omarchy-plugin-add "$OMARCHY_WIDGET_URL" --enable --yes
        else
            warn "omarchy-plugin-add not found; install the widget manually:"
            warn "  omarchy plugin add $OMARCHY_WIDGET_URL --enable"
        fi
    else
        info "Skipped the Omarchy bar widget"
    fi
else
    info "Not Omarchy — skipping the bar widget"
fi

# ── done ──────────────────────────────────────────────────────────────────────
section "Installation complete"

DEFAULT_EP_NAME=$(awk -F= '$1=="DEFAULT_ENDPOINT"{print $2}' "$CONFIG_FILE")
DEFAULT_CONN=$(awk -F= '$1=="CONN_NAME"{print $2}' "$CONFIG_FILE")
BROWSER=$(awk -F= '$1=="BROWSER"{print $2}' "$CONFIG_FILE")
BROWSER_PROFILE=$(awk -F= '$1=="BROWSER_PROFILE"{print $2}' "$CONFIG_FILE")
LOGIN_BROWSER_DESC="$BROWSER"
[[ -n "$BROWSER_PROFILE" ]] && LOGIN_BROWSER_DESC="$BROWSER (profile: $BROWSER_PROFILE)"

echo -e ""
echo -e "${BOLD}Next step:${RESET}"
echo -e ""
echo -e "  Run the following to authenticate and connect for the first time:"
echo -e ""
echo -e "    ${GREEN}smc-vpn-refresh${RESET}"
echo -e ""
echo -e "  This will open ${LOGIN_BROWSER_DESC} for CAS login, mint a gateway cookie for the"
echo -e "  default endpoint (${DEFAULT_EP_NAME}), write it to the '${DEFAULT_CONN}'"
echo -e "  NM profile, and bring the VPN up."
echo -e ""
echo -e "${BOLD}Daily use:${RESET}"
echo -e ""
echo -e "  Flip the GNOME Network → VPN → ${DEFAULT_CONN} toggle, or run:"
echo -e ""
echo -e "    nmcli connection up ${DEFAULT_CONN}      # connect"
echo -e "    nmcli connection down ${DEFAULT_CONN}    # disconnect"
echo -e ""
echo -e "  No dialog will appear. The cookie auto-refreshes on disconnect."
echo -e ""
echo -e "${BOLD}Switching endpoints:${RESET}"
echo -e ""
echo -e "  Authenticate and connect another endpoint:"
echo -e ""
echo -e "    ${GREEN}smc-vpn-refresh --endpoint UK${RESET}   (or US, or any configured id)"
echo -e ""
echo -e "  On Omarchy, the bar widget's popup has an endpoint selector."
echo -e ""
echo -e "${BOLD}When the VPN stops connecting (portal session expired):${RESET}"
echo -e ""
echo -e "    ${GREEN}smc-vpn-refresh${RESET}            (re-authenticate and reconnect)"
echo -e "    ${GREEN}smc-vpn-refresh --no-connect${RESET} (update secrets only)"
echo -e "    ${GREEN}smc-vpn-refresh --browser firefox${RESET}"
echo -e ""
