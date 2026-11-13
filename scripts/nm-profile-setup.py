#!/usr/bin/env python3
"""
nm-profile-setup.py — Stage 0–3 NetworkManager profile setup.

Run by install.sh after config is written. Reads
~/.config/smc-gp-vpn/config for the endpoint list (ENDPOINTS /
ENDPOINT_<ID>_* keys) and the installing user's identity.

Multi-endpoint: one NM connection is created per endpoint, e.g.
SMC-UK (uk-access...) and SMC-US (us-access...). Each profile stores
its own gateway cookie, so switching endpoints in the widget does not
require a re-login.

Legacy migration: if a pre-multi-endpoint profile exists (its
vpn.data gateway matches one of the configured endpoint portals but
its name is not the endpoint's connection name), it is RENAMED to
that endpoint's connection name and its secrets are left untouched —
the existing portal cookie keeps working without a re-login.

Two modes per endpoint:
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


def parse_endpoints(config: dict) -> list[dict]:
    """Parse ENDPOINT_* entries from config; fall back to legacy single-endpoint keys.

    Mirrors parse_endpoints() in smc-vpn-refresh / 99-smc-cookie-refresh.
    Each endpoint is a dict: {id, portal, conn_name, cache}.
    """
    endpoints: list[dict] = []
    for eid in (s.strip().upper() for s in config.get("ENDPOINTS", "").split(",")):
        if not eid or not eid.replace("_", "").isalnum():
            continue
        portal = config.get(f"ENDPOINT_{eid}_PORTAL", "")
        conn = config.get(f"ENDPOINT_{eid}_CONN_NAME", "")
        if not portal or not conn:
            continue
        cache = config.get(
            f"ENDPOINT_{eid}_CACHE",
            os.path.expanduser(f"~/.config/gpclient/smc-cookie-{eid.lower()}.json"),
        )
        endpoints.append({"id": eid, "portal": portal, "conn_name": conn, "cache": cache})

    if endpoints:
        return endpoints

    # Legacy single-endpoint config (written by older install.sh versions).
    portal = config.get("PORTAL", "")
    if portal:
        return [{
            "id": "MAIN",
            "portal": portal,
            "conn_name": config.get("CONN_NAME", "SMC"),
            "cache": config.get(
                "CACHE", os.path.expanduser("~/.config/gpclient/smc-cookie.json")
            ),
        }]
    return []


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


# ── legacy migration ─────────────────────────────────────────────────────────

def is_our_gp_profile(conn: NM.RemoteConnection) -> bool:
    """True for NM openconnect profiles in GlobalProtect (protocol=gp) mode."""
    s_vpn = conn.get_setting_vpn()
    if s_vpn is None:
        return False
    if s_vpn.get_service_type() != "org.freedesktop.NetworkManager.openconnect":
        return False
    protocol = s_vpn.get_data_item("protocol")
    return protocol is None or protocol == "gp"


def profile_gateway(conn: NM.RemoteConnection) -> str:
    s_vpn = conn.get_setting_vpn()
    return (s_vpn.get_data_item("gateway") or "").strip().lower() if s_vpn else ""


def rename_connection(conn: NM.RemoteConnection, new_id: str) -> None:
    s_con = conn.get_setting_connection()
    s_con.set_property(NM.SETTING_CONNECTION_ID, new_id)
    conn.update2(
        conn.to_dbus(NM.ConnectionSerializationFlags.ALL),
        NM.SettingsUpdate2Flags.TO_DISK,
        None, None, None,
    )
    pump_loop()


def migrate_legacy_profiles(
    client: NM.Client, endpoints: list[dict]
) -> dict[str, bool]:
    """Rename pre-multi-endpoint profiles to their endpoint's connection name.

    A legacy profile is matched by its vpn.data gateway: if it points at an
    endpoint's portal and that endpoint's connection name does not exist yet,
    the profile is renamed and its secrets are PRESERVED (no re-login needed).

    Returns {endpoint_id: migrated} for endpoints that were migrated.
    """
    migrated: dict[str, bool] = {}
    endpoint_names = {ep["conn_name"] for ep in endpoints}

    for conn in client.get_connections():
        if not is_our_gp_profile(conn):
            continue
        conn_id = conn.get_id()
        if conn_id in endpoint_names:
            continue  # already named after an endpoint — handled by CLEAN

        gateway = profile_gateway(conn)
        for ep in endpoints:
            if gateway != ep["portal"].strip().lower():
                continue
            if client.get_connection_by_id(ep["conn_name"]) is not None:
                print(
                    f"  NOTE: legacy profile '{conn_id}' points at {ep['portal']} "
                    f"but '{ep['conn_name']}' already exists — left untouched. "
                    f"Delete it manually if it is redundant: "
                    f"nmcli connection delete {conn_id}"
                )
                break
            print(
                f"  Migrating legacy profile '{conn_id}' "
                f"(gateway={ep['portal']}) → renaming to '{ep['conn_name']}' "
                f"(secrets preserved — no re-login needed)"
            )
            rename_connection(conn, ep["conn_name"])
            migrated[ep["id"]] = True
            break

    return migrated


# ── main ─────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Set up the NM VPN profiles for smc-gp-vpn."
    )
    parser.add_argument(
        "--config",
        default=os.path.expanduser("~/.config/smc-gp-vpn/config"),
        help="Path to smc-gp-vpn config file (default: ~/.config/smc-gp-vpn/config)",
    )
    args = parser.parse_args()

    config = load_config(args.config)
    endpoints = parse_endpoints(config)
    if not endpoints:
        die("No endpoints found in config — run install.sh first.")

    for ep in endpoints:
        print(f"[NM setup] endpoint '{ep['id']}': "
              f"connection='{ep['conn_name']}'  portal='{ep['portal']}'")

    client = get_nm_client()

    migrated = migrate_legacy_profiles(client, endpoints)

    for ep in endpoints:
        conn_name = ep["conn_name"]
        portal = ep["portal"]
        conn = client.get_connection_by_id(conn_name)
        if conn is None:
            create_profile(client, conn_name, portal)
        elif migrated.get(ep["id"]):
            print(f"  Preserved '{conn_name}' — migrated legacy profile, "
                  f"secrets kept.")
        else:
            clean_profile(conn, conn_name, portal)

    print("[NM setup] Done. Run 'smc-vpn-refresh' to authenticate "
          "(add --endpoint ID for a specific endpoint).")


if __name__ == "__main__":
    main()
