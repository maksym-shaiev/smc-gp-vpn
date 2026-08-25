# smc-gp-vpn

GlobalProtect CAS VPN integration for NetworkManager on Ubuntu 24.04.

Connects the GNOME Network → VPN toggle to a Palo Alto
[Cloud Authentication Service (CAS)](https://docs.paloaltonetworks.com/globalprotect/10-2/globalprotect-admin/authentication/configure-cloud-authentication-service)
portal, which the built-in `nm-openconnect` auth dialog cannot handle.

---

## Background

`us-access.stagwellglobal.com` is a CAS portal. CAS explicitly disallows
embedded browsers (`cas-embedded-browser: no`), so the WebKit dialog inside
`nm-openconnect-auth-dialog` fails with *"The URL can't be shown"*.

This repo wires [globalprotect-openconnect](https://github.com/yuezk/GlobalProtect-openconnect)
(`gpclient`) — which handles CAS correctly — into NetworkManager by:

1. Using a patched `gpclient` (`--print-cookie`) to perform CAS auth and emit
   the gateway cookie without opening a tunnel.
2. Writing that cookie into the NM profile via the NM Python binding.
3. Letting NM manage the tunnel with `--cookie-on-stdin` as it normally would.

The patch is submitted upstream:
[yuezk/GlobalProtect-openconnect#PR](https://github.com/yuezk/GlobalProtect-openconnect/pulls).
Until it is merged, the binary is built from
[maksym-shaiev/GlobalProtect-openconnect@smc-distribution](https://github.com/maksym-shaiev/GlobalProtect-openconnect/tree/smc-distribution).

---

## Requirements

- Ubuntu 24.04 (or compatible) with GNOME and NetworkManager
- `network-manager-openconnect`
- `python3-gi` + `gir1.2-nm-1.0`
- `jq`, `curl`, `sudo`, `notify-send`

`install.sh` checks all of these and tells you what is missing.

---

## Installation

```bash
git clone https://github.com/maksym-shaiev/smc-gp-vpn.git
cd smc-gp-vpn
bash install.sh
```

The script is interactive — it prompts for three values:

| Prompt | Default | Notes |
|---|---|---|
| Portal gateway | `us-access.stagwellglobal.com` | Change if your org uses a different portal |
| NM connection name | `SMC` | Must match the name in GNOME Network settings |
| Browser for CAS auth | `chrome` | `firefox` or `auto` also accepted |

It requires `sudo` once — only to install the NM dispatcher script into
`/etc/NetworkManager/dispatcher.d/`.

### First-time authentication

After `install.sh` completes, run:

```bash
smc-vpn-refresh
```

This opens the browser for CAS login, mints a gateway cookie, writes it to
the NM profile, and brings the VPN up. Takes ~30 seconds.

---

## Daily use

Flip the GNOME **Network → VPN → SMC** toggle. No dialog appears.

When the VPN disconnects, the dispatcher script (`99-smc-cookie-refresh`)
automatically mints a fresh gateway cookie in the background (~1–2 s). The
toggle is ready to use again immediately.

Monitor the refresh in real time:

```bash
journalctl -t smc-cookie-refresh -f
```

---

## Cookie expiry (~30 days)

When the portal session expires you will receive a desktop notification:

> **SMC VPN — re-authentication required**
> The portal session has expired. Run `smc-vpn-refresh` to log in again.

Run:

```bash
smc-vpn-refresh                    # re-authenticate and reconnect
smc-vpn-refresh --no-connect       # update secrets only, no reconnect
smc-vpn-refresh --browser firefox  # use Firefox instead of Chrome
```

---

## Files installed

| Path | Purpose |
|---|---|
| `~/.config/smc-gp-vpn/config` | Configuration (portal, connection name, browser) |
| `~/.local/bin/gpclient-smc` | Patched gpclient binary |
| `~/.local/bin/smc-vpn-refresh` | Manual refresh + reconnect script |
| `/etc/NetworkManager/dispatcher.d/99-smc-cookie-refresh` | Auto-refresh on vpn-down |

---

## Updating

Re-run `install.sh` to pull the latest binary and scripts:

```bash
git -C smc-gp-vpn pull
bash smc-gp-vpn/install.sh
```

The installer is idempotent — it overwrites existing files and reconfigures
the NM profile cleanly.

---

## Uninstall

```bash
rm -f ~/.local/bin/gpclient-smc ~/.local/bin/smc-vpn-refresh
rm -rf ~/.config/smc-gp-vpn
sudo rm -f /etc/NetworkManager/dispatcher.d/99-smc-cookie-refresh

# Clear secrets from the NM profile (leaves the connection intact)
python3 - <<'EOF'
import gi; gi.require_version('NM','1.0')
from gi.repository import NM, GLib
c = NM.Client.new(None).get_connection_by_id('SMC')
s = c.get_setting_vpn()
for k in ('cookie', 'gateway', 'gwcert'): s.remove_secret(k)
c.update2(c.to_dbus(NM.ConnectionSerializationFlags.ALL),
          NM.SettingsUpdate2Flags.TO_DISK, None, None, None)
ml = GLib.MainLoop(); GLib.timeout_add(700, ml.quit); ml.run()
print("secrets cleared")
EOF
```

---

## When the upstream PR is merged

Once `--print-cookie` lands in an official `globalprotect-openconnect` release:

1. Update `install.sh` — change `BINARY_URL` and `SUMS_URL` to point at the
   upstream release.
2. Users on the PPA can simply `sudo apt upgrade globalprotect-openconnect`.

---

## How it works (technical detail)

See [SMC-VPN-PLAN.md](https://github.com/maksym-shaiev/GlobalProtect-openconnect/blob/smc-distribution/SMC-VPN-PLAN.md)
for the full root cause analysis and implementation ADR.

Key facts:

- NM's tunnel phase never authenticates — `nm-openconnect-service.c` passes
  `--cookie-on-stdin` to openconnect. NM only needs a valid gateway cookie.
- `gpclient --print-cookie` performs CAS auth using gpclient's correct request
  envelope (`clientgpversion`, `host-id`, `serialno`, etc.) and emits the
  cookie without opening a tunnel or requiring root.
- The cookie is written via the NM Python binding (`update2 TO_DISK`) because
  `nmcli` cannot represent `&` and `=` in cookie values unambiguously.
- Three secrets must be present for NM to skip the auth dialog: `cookie`,
  `gateway`, and `gwcert` (empty string satisfies the check; empty → normal
  PKI validation, not certificate pinning).
