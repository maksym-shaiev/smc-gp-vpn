# smc-gp-vpn

GlobalProtect CAS VPN integration for NetworkManager on Ubuntu 24.04/26.04 and Arch-based distributions (incl. Omarchy).

## Supported platforms

| Distribution | Architecture |
|---|---|
| Ubuntu 24.04 LTS (Noble) | x86_64 |
| Ubuntu 26.04 LTS (Plucky) | x86_64 |
| Arch / Omarchy (rolling) | x86_64 |

`install.sh` detects your distribution automatically.

Connects the GNOME Network → VPN toggle to a Palo Alto
[Cloud Authentication Service (CAS)](https://docs.paloaltonetworks.com/globalprotect/10-2/globalprotect-admin/authentication/configure-cloud-authentication-service)
portal, which the built-in `nm-openconnect` auth dialog cannot handle.

---

## Background

`uk-access.stagwellglobal.com` and `us-access.stagwellglobal.com` are CAS
portals. CAS explicitly disallows embedded browsers (`cas-embedded-browser: no`),
so the WebKit dialog inside `nm-openconnect-auth-dialog` fails with
*"The URL can't be shown"*.

This repo wires [globalprotect-openconnect](https://github.com/yuezk/GlobalProtect-openconnect)
(`gpclient`) — which handles CAS correctly — into NetworkManager by:

1. Using `gpclient connect --cookie-only` (upstream since 3.3.0; originally a
   local patch, `--print-cookie`) to perform CAS auth and emit the gateway
   cookie without opening a tunnel.
2. Writing that cookie into the NM profile via the NM Python binding.
3. Letting NM manage the tunnel with `--cookie-on-stdin` as it normally would.

---

## Requirements

- Ubuntu 24.04/26.04 or Arch-based distribution (incl. Omarchy), x86_64, with NetworkManager
- `globalprotect-openconnect` >= 3.3.0 (upstream `gpclient` with `--cookie-only`)
- `network-manager-openconnect` (Ubuntu) / `networkmanager-openconnect` (Arch)
- `python3-gi` + `gir1.2-nm-1.0` (Ubuntu) / `python-gobject` (Arch)
- `sudo`, `notify-send`

`install.sh` checks all of these and tells you what is missing, with the correct package manager command for your distribution.

---

## Installation

```bash
git clone https://github.com/maksym-shaiev/smc-gp-vpn.git
cd smc-gp-vpn
bash install.sh
```

The script is interactive — it prompts for the endpoints to configure and,
per endpoint, the portal and NM connection name:

| Prompt | Default | Notes |
|---|---|---|
| Endpoints to configure | `UK,US` | Comma-separated ids, e.g. `UK,US` or just `US` |
| Portal gateway for `[ID]` | `uk-access...` / `us-access...` | Falls back to the legacy `PORTAL` for unknown ids |
| NM connection name for `[ID]` | `SMC-<ID>` | Must match the name in GNOME Network settings |
| Default endpoint | first id | What plain `smc-vpn-refresh` connects to |
| Browser for CAS auth | `chrome` | `firefox` or `auto` also accepted |

It requires `sudo` once — only to install the NM dispatcher script into
`/etc/NetworkManager/dispatcher.d/`.

An existing multi-endpoint config is reused as-is (missing
`ENDPOINT_<ID>_AS_GATEWAY` keys are appended with defaults — UK `yes`,
others `no`); a legacy single-endpoint config is upgraded to the
multi-endpoint format on re-run.

### First-time authentication

After `install.sh` completes, run:

```bash
smc-vpn-refresh
```

This opens the browser for CAS login, mints a gateway cookie for the default
endpoint, writes it to the NM profile, and brings the VPN up. Takes ~30 seconds.

---

## Endpoints

`smc-gp-vpn` supports multiple GlobalProtect endpoints (e.g. a UK and a US
portal). Each endpoint gets **its own NM connection profile and its own
portal-cookie cache**, so switching endpoints does not require a re-login —
both cookies stay valid in parallel.

Config format (`~/.config/smc-gp-vpn/config`):

```ini
BROWSER=chromium
DEFAULT_ENDPOINT=UK
ENDPOINTS=UK,US
ENDPOINT_UK_PORTAL=uk-access.stagwellglobal.com
ENDPOINT_UK_CONN_NAME=SMC-UK
ENDPOINT_UK_CACHE=~/.config/gpclient/smc-cookie-uk.json
ENDPOINT_UK_AS_GATEWAY=yes
ENDPOINT_US_PORTAL=us-access.stagwellglobal.com
ENDPOINT_US_CONN_NAME=SMC-US
ENDPOINT_US_CACHE=~/.config/gpclient/smc-cookie-us.json
ENDPOINT_US_AS_GATEWAY=no
# Legacy keys duplicated from the default endpoint (older tooling reads them):
PORTAL=uk-access.stagwellglobal.com
CONN_NAME=SMC-UK
CACHE=~/.config/gpclient/smc-cookie-uk.json
```

`GPCLIENT_BIN` / `GP_AUTH_BIN` are optional overrides for setups that use a
custom gpclient build (e.g. the pre-3.3.0 fork); by default the `gpclient`
found on `PATH` is used.

### Gateway-mode endpoints (`ENDPOINT_<ID>_AS_GATEWAY`)

Set `ENDPOINT_<ID>_AS_GATEWAY=yes` for endpoints whose CAS gateway rejects
the portal login result. Without the flag, `smc-vpn-refresh` authenticates
against the portal first and passes that result to the gateway; a gateway
that rejects it falls back to gateway prelogin and opens the browser a
**second** time (observed on `uk-access`). With the flag, `gpclient` runs
with `--as-gateway` and authenticates directly against the gateway —
exactly one browser login.

Consequences for gateway-mode endpoints:

- The portal login result is never reused, so no portal-cookie cache is
  written and every refresh opens the browser.
- The dispatcher (`99-smc-cookie-refresh`) skips the silent background
  refresh for them — it cannot mint a cookie without a browser. When the
  cookie expires, the next toggle-on fails and you re-authenticate via the
  widget's **Authenticate** button (or `smc-vpn-refresh --endpoint <ID>`).

`install.sh` defaults UK to `yes` and every other endpoint to `no`; re-running
it appends the key for endpoints written before this option existed.

Switching endpoints from the terminal:

```bash
smc-vpn-refresh --endpoint UK    # authenticate (if needed) + connect UK
smc-vpn-refresh --endpoint US    # brings the UK tunnel down, connects US
smc-vpn-refresh                  # no --endpoint: active endpoint, else default
```

Any other configured endpoint that is still connected is brought down first —
CAS portals only honour one live session per user, so a second login would
invalidate the first portal's cookie anyway.

The NM dispatcher (`99-smc-cookie-refresh`) refreshes whichever endpoint's
connection went down, using that endpoint's own cache.

**Migration from a legacy single-profile setup:** re-running
`install.sh` (or `scripts/nm-profile-setup.py` with a multi-endpoint config)
renames an existing profile to the endpoint whose portal matches its
`vpn.data` gateway and **preserves its secrets** — that endpoint keeps working
without a re-login. Other endpoints are created fresh and need one
`smc-vpn-refresh --endpoint <ID>` each.

---

## Daily use

**Via GNOME:** flip the **Network → VPN → SMC-<ID>** toggle. No dialog appears.

**Via terminal:**

```bash
nmcli connection up SMC-UK      # connect
nmcli connection down SMC-UK    # disconnect
```

When the VPN disconnects, the dispatcher script (`99-smc-cookie-refresh`)
automatically mints a fresh gateway cookie in the background (~1–2 s), so the
toggle is ready to use again immediately. Gateway-mode endpoints are skipped
(see `ENDPOINT_<ID>_AS_GATEWAY` above) — their cookie can only be refreshed
with a browser login.

Monitor the refresh in real time:

```bash
journalctl -t smc-cookie-refresh -f
```

---

## When the VPN stops connecting

When the portal session expires, the GNOME toggle or `nmcli connection up SMC-UK`
will fail silently — the VPN simply does not come up. Run:

```bash
smc-vpn-refresh                    # re-authenticate via browser and reconnect
smc-vpn-refresh --endpoint UK      # ... for a specific endpoint
smc-vpn-refresh --no-connect       # update secrets only, no reconnect
smc-vpn-refresh --browser firefox  # use Firefox instead of Chrome
```

Gateway-mode endpoints (`ENDPOINT_<ID>_AS_GATEWAY=yes`, UK by default) always
open the browser for a fresh login here — their CAS gateway does not issue a
reusable portal session, so there is nothing to auto-refresh.

---

## Bar widget (Omarchy only)

On Omarchy, `install.sh` offers to install the GlobalProtect Omarchy bar widget
([gp-vpn-omarchy](https://github.com/maksym-shaiev/gp-vpn-omarchy)) at the end
of the install. Accepting installs the widget as an Omarchy plugin and enables
it in the right bar section.

The widget shows VPN on/off state in the top bar and opens a popup with
connection details, public IP / country, and Refresh cookie / Reconnect
buttons. The global hotkey `Super + Alt + V` opens the popup anywhere.

![Widget popup](https://raw.githubusercontent.com/maksym-shaiev/gp-vpn-omarchy/main/docs/screenshot.png)

If you skipped the prompt, install the widget later with:

```bash
omarchy plugin add https://github.com/maksym-shaiev/gp-vpn-omarchy.git --enable
```

Remove it with:

```bash
omarchy plugin remove gp-vpn
```

---

## Files installed

| Path | Purpose |
|---|---|
| `~/.config/smc-gp-vpn/config` | Configuration (endpoints, portals, connection names, browser) |
| `~/.local/bin/smc-vpn-refresh` | Manual refresh + reconnect script |
| `/etc/NetworkManager/dispatcher.d/99-smc-cookie-refresh` | Auto-refresh on vpn-down / vpn-pre-down |

---

## Updating

Re-run `install.sh` to pick up the latest scripts:

```bash
git -C smc-gp-vpn pull
bash smc-gp-vpn/install.sh
```

The installer is idempotent — it overwrites existing files and reconfigures
the NM profiles cleanly (keeping cookies for migrated profiles).

---

## Uninstall

### Option A — using the uninstall script

```bash
bash uninstall.sh
```

Or from a fresh clone:

```bash
bash <(curl -sL https://raw.githubusercontent.com/maksym-shaiev/smc-gp-vpn/main/uninstall.sh)
```

To also remove the NM VPN profile:

```bash
bash uninstall.sh --remove-profile
```

### Option B — manual uninstall

```bash
rm -f ~/.local/bin/gpclient-smc ~/.local/bin/gpauth-smc ~/.local/bin/smc-vpn-refresh
rm -rf ~/.config/smc-gp-vpn ~/.config/gpclient
sudo rm -f /etc/NetworkManager/dispatcher.d/99-smc-cookie-refresh
sudo rm -f /etc/NetworkManager/dispatcher.d/pre-down.d/99-smc-cookie-refresh
```

To remove the NM VPN profiles manually:

```bash
nmcli connection delete SMC-UK SMC-US
```

### Optional cleanup

Remove the Omarchy bar widget (if installed):

```bash
omarchy plugin remove gp-vpn
```

Or run the widget's uninstaller:

```bash
bash <(curl -sL https://raw.githubusercontent.com/maksym-shaiev/gp-vpn-omarchy/main/uninstall.sh)
```

---

## How it works (technical detail)

See [SMC-VPN-PLAN.md](https://github.com/maksym-shaiev/GlobalProtect-openconnect/blob/smc-distribution/SMC-VPN-PLAN.md)
for the full root cause analysis and implementation ADR.

Key facts:

- NM's tunnel phase never authenticates — `nm-openconnect-service.c` passes
  `--cookie-on-stdin` to openconnect. NM only needs a valid gateway cookie.
- `gpclient connect --cookie-only` performs CAS auth using gpclient's correct
  request envelope (`clientgpversion`, `host-id`, `serialno`, etc.), prints
  `COOKIE='<value>'` / `HOST='<gateway>'` and exits without opening a tunnel
  or requiring root.
- The cookie is written via the NM Python binding (`update2 TO_DISK`) because
  `nmcli` cannot represent `&` and `=` in cookie values unambiguously.
- Three secrets must be present for NM to skip the auth dialog: `cookie`,
  `gateway`, and `gwcert` (empty string satisfies the check; empty → normal
  PKI validation, not certificate pinning).
- If `GP_AUTH_BIN` is configured (legacy fork setups), `gpclient` is forced to
  spawn that `gpauth` build via the `GP_AUTH_BINARY` env var; with the
  upstream package the matching system `gpauth` is used as-is.
