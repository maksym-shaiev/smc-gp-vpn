#!/usr/bin/env python3
"""
nm-profile-setup.py — Stage 0–3 NetworkManager profile setup.

Run by install.sh after config is written. Reads
~/.config/smc-gp-vpn/config for CONN_NAME, PORTAL, and the
installing user's identity.

Two modes:
  CREATE  — NM connection CONN_NAME does not exist: create it from
             scratch with correct vpn.data and empty secrets.
  CLEAN   — NM connection CONN_NAME already exists: remove any
             contaminated secrets, fix secret flags, write empty
             placeholder secrets so need_secrets() returns FALSE.

In both modes the profile ends up in the same state:
  - vpn.data  : protocol=gp, gateway=PORTAL, cacert=system bundle,
                all *-flags=0 (stored), no usergroup
  - vpn.secrets: cookie='', gateway=PORTAL, gwcert=''
                 (all present, flags 0 → NM will not invoke auth dialog)

Usage:
  python3 nm-profile-setup.py [--config PATH]
  (default config: ~/.config/smc-gp-vpn/config)
"""

import argparse
import os
import sys
import gi

gi.require_version("NM", "1.0")
from gi.repository import NM, GLib  # noqa: E402


# ── config loader ────────────────────────────────────────────────────────────

def load_config(path: str) -> dict:
    """Parse KEY=VALUE config file; expand ~ in values."""
    config = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if "=" not in line:
                    continue
                key, _, value = line.partition("=")
                config[key.strip()] = os.path.expanduser(value.strip())
    except FileNotFoundError:
        die(f"Config file not found: {path}\nRun install.sh first.")
    return config


# ── helpers ──────────────────────────────────────────────────────────────────

def die(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def pump_loop(ms: int = 700) -> None:
    """Pump the GLib main loop briefly to flush async D-Bus calls."""
    ml = GLib.MainLoop()
    GLib.timeout_add(ms, ml.quit)
    ml.run()


def get_nm_client() -> NM.Client:
    client = NM.Client.new(None)
    if client is None:
        die("Could not connect to NetworkManager D-Bus service.")
    return client


# ── vpn.data for a clean GlobalProtect/openconnect profile ───────────────────

def build_vpn_data(portal: str) -> dict:
    """
    Returns the vpn.data key/value pairs for a clean GP openconnect profile.

    All *-flags keys are 0 (NM_SETTING_SECRET_FLAG_NONE = stored on disk).
    This prevents NM from invoking the auth dialog on connect.

    No 'usergroup' key — that field caused contamination on the original profile
    (see SMC-VPN-PLAN.md §4.1).
    """
    return {
        "authtype":            "password",
        "autoconnect-flags":   "0",
        "cacert":              "/etc/ssl/certs/ca-certificates.crt",
        "certsigs-flags":      "0",
        "cookie-flags":        "0",
        "disable_udp":         "no",
        "enable_csd_trojan":   "no",
        "gateway":             portal,
        "gateway-flags":       "0",
        "gwcert-flags":        "0",
        "lasthost-flags":      "0",
        "pem_passphrase_fsid": "no",
        "prevent_invalid_cert":"no",
        "protocol":            "gp",
        "resolve-flags":       "0",
        "stoken_source":       "disabled",
        "xmlconfig-flags":     "0",
    }


# ── secret helpers ───────────────────────────────────────────────────────────

REQUIRED_SECRETS = ("cookie", "gateway", "gwcert")

def write_placeholder_secrets(s_vpn: NM.SettingVpn, portal: str) -> None:
    """
    Write the three secrets that nm-openconnect-service.c's need_secrets()
    checks for presence (not validity).

    - cookie  = '' (will be replaced by smc-vpn-refresh on first auth)
    - gateway = portal FQDN
    - gwcert  = '' (empty → use cacert; immune to cert rotation)

    All three must be present; a missing gwcert causes need_secrets() to
    return TRUE, triggering the WebKit auth dialog.
    """
    s_vpn.add_secret("cookie",  "")
    s_vpn.add_secret("gateway", portal)
    s_vpn.add_secret("gwcert",  "")


def clear_contaminated_secrets(s_vpn: NM.SettingVpn) -> None:
    """Remove all existing secrets; write_placeholder_secrets() follows."""
    for key in list(s_vpn.get_secret_keys()):
        s_vpn.remove_secret(key)


# ── CREATE path ──────────────────────────────────────────────────────────────

def create_profile(client: NM.Client, conn_name: str, portal: str) -> None:
    print(f"  NM connection '{conn_name}' not found — creating from scratch.")

    conn = NM.SimpleConnection.new()

    # connection settings
    s_con = NM.SettingConnection.new()
    s_con.set_property(NM.SETTING_CONNECTION_ID,           conn_name)
    s_con.set_property(NM.SETTING_CONNECTION_TYPE,         "vpn")
    s_con.set_property(NM.SETTING_CONNECTION_AUTOCONNECT,  False)
    conn.add_setting(s_con)

    # vpn settings
    s_vpn = NM.SettingVpn.new()
    s_vpn.set_property(
        NM.SETTING_VPN_SERVICE_TYPE,
        "org.freedesktop.NetworkManager.openconnect",
    )
    for k, v in build_vpn_data(portal).items():
        s_vpn.add_data_item(k, v)
    write_placeholder_secrets(s_vpn, portal)
    conn.add_setting(s_vpn)

    # persist to disk
    client.add_connection2(
        conn.to_dbus(NM.ConnectionSerializationFlags.ALL),
        NM.SettingsAddConnection2Flags.TO_DISK,
        None, False, None, None, None,
    )
    pump_loop()
    print(f"  Created '{conn_name}' (protocol=gp, gateway={portal})")


# ── CLEAN path ───────────────────────────────────────────────────────────────

def clean_profile(conn: NM.RemoteConnection, conn_name: str, portal: str) -> None:
    print(f"  NM connection '{conn_name}' found — cleaning and reconfiguring.")

    s_vpn = conn.get_setting_vpn()
    if s_vpn is None:
        die(f"Connection '{conn_name}' exists but has no VPN setting.")

    # Rewrite vpn.data entirely — removes usergroup and any other contamination
    # by replacing each key individually.
    existing_keys = list(s_vpn.get_data_keys())
    for k in existing_keys:
        s_vpn.remove_data_item(k)
    for k, v in build_vpn_data(portal).items():
        s_vpn.add_data_item(k, v)

    # Clear all secrets and write clean placeholders
    clear_contaminated_secrets(s_vpn)
    write_placeholder_secrets(s_vpn, portal)

    conn.update2(
        conn.to_dbus(NM.ConnectionSerializationFlags.ALL),
        NM.SettingsUpdate2Flags.TO_DISK,
        None, None, None,
    )
    pump_loop()
    print(f"  Cleaned '{conn_name}' — vpn.data rewritten, secrets reset.")


# ── main ─────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Set up the NM VPN profile for smc-gp-vpn."
    )
    parser.add_argument(
        "--config",
        default=os.path.expanduser("~/.config/smc-gp-vpn/config"),
        help="Path to smc-gp-vpn config file (default: ~/.config/smc-gp-vpn/config)",
    )
    args = parser.parse_args()

    config    = load_config(args.config)
    conn_name = config.get("CONN_NAME", "SMC")
    portal    = config.get("PORTAL",    "us-access.stagwellglobal.com")

    print(f"[NM setup] connection='{conn_name}'  portal='{portal}'")

    client = get_nm_client()
    conn   = client.get_connection_by_id(conn_name)

    if conn is None:
        create_profile(client, conn_name, portal)
    else:
        clean_profile(conn, conn_name, portal)

    print("[NM setup] Done. Run 'smc-vpn-refresh' to authenticate.")


if __name__ == "__main__":
    main()
