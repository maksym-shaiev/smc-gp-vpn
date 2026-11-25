# smc-gp-vpn

GlobalProtect CAS VPN integration for NetworkManager on Ubuntu 24.04/26.04 and
Arch-based distributions (incl. Omarchy), x86_64.

Connects the network applet's VPN toggle (GNOME Settings on Ubuntu, the
Omarchy bar widget on Omarchy) — or plain `nmcli` — to a Palo Alto
[Cloud Authentication Service (CAS)](https://docs.paloaltonetworks.com/globalprotect/10-2/globalprotect-admin/authentication/configure-cloud-authentication-service)
portal, which the built-in `nm-openconnect` auth dialog cannot handle.

## Quick start

```bash
# 1. Prerequisites (see "Prerequisites" below for your distribution)
#    - globalprotect-openconnect >= 3.3.0   (from upstream GitHub releases)
#    - network-manager-openconnect / networkmanager-openconnect
#    - python3-gi + gir1.2-nm-1.0 / python-gobject

# 2. Install
git clone https://github.com/maksym-shaiev/smc-gp-vpn.git
cd smc-gp-vpn
bash install.sh          # interactive; needs sudo once

# 3. Authenticate and connect (opens the browser for CAS login)
smc-vpn-refresh
```

After that, connect/disconnect from your network applet's VPN toggle or with
`nmcli connection up|down SMC-UK` — no auth dialog appears, and the gateway
cookie auto-refreshes in the background on every disconnect.

## Supported platforms

| Distribution | Architecture |
|---|---|
| Ubuntu 24.04 LTS (Noble) | x86_64 |
| Ubuntu 26.04 LTS (Resolute Raccoon) | x86_64 |
| Arch / Omarchy (rolling) | x86_64 |

`install.sh` detects your distribution automatically.

---

## Prerequisites

| Package | Ubuntu | Arch / Omarchy |
|---|---|---|
| `globalprotect-openconnect` **>= 3.3.0** | upstream `.deb` (below) | upstream `.pkg` or AUR (below) |
| openconnect NM plugin | `network-manager-openconnect` | `networkmanager-openconnect` |
| Python NM binding | `python3-gi` + `gir1.2-nm-1.0` | `python-gobject` |
| misc | `sudo`, `notify-send` (usually preinstalled) | `sudo`, `libnotify` |

**Important:** no distribution repository ships a new-enough `gpclient`.

- The Arch `extra` repo currently carries **2.6.5** — too old for this tool.
- Ubuntu's repos don't carry the package at all.

Install it from the upstream
[GitHub releases](https://github.com/yuezk/GlobalProtect-openconnect/releases)
(any version ≥ 3.3.0; the examples below use the current 3.7.1):

**Ubuntu 24.04 / 26.04 (x86_64):**

```bash
wget https://github.com/yuezk/GlobalProtect-openconnect/releases/download/v3.7.1/globalprotect-openconnect_3.7.1-1_amd64.deb
sudo apt install ./globalprotect-openconnect_3.7.1-1_amd64.deb
```

**Arch / Omarchy (x86_64)** — either the prebuilt package from the release:

```bash
curl -LO https://github.com/yuezk/GlobalProtect-openconnect/releases/download/v3.7.1/globalprotect-openconnect-3.7.1-1-x86_64.pkg.tar.zst
sudo pacman -U globalprotect-openconnect-3.7.1-1-x86_64.pkg.tar.zst
```

…or the AUR package maintained by the upstream author (keeps updating with
your AUR helper):

```bash
yay -S globalprotect-openconnect-git
```

The rest of the prerequisites come from your repositories:

```bash
# Ubuntu
sudo apt install network-manager-openconnect python3-gi gir1.2-nm-1.0

# Arch / Omarchy
sudo pacman -S networkmanager-openconnect python-gobject
```

`install.sh` re-checks all of this (including that your `gpclient` actually
supports `--cookie-only`) and tells you what is missing, with the correct
package-manager command for your distribution.

---

## Background

`uk-access.stagwellglobal.com` and `us-access.stagwellglobal.com` are CAS
portals. CAS explicitly disallows embedded browsers (`cas-embedded-browser: no`),
so the WebKit dialog inside `nm-openconnect-auth-dialog` fails with
*"The URL can't be shown"*.

This repo wires [globalprotect-openconnect](https://github.com/yuezk/GlobalProtect-openconnect)
(`gpclient`) — which handles CAS correctly — into NetworkManager by:

1. Using `gpclient connect --cookie-only` (upstream since 3.3.0) to perform
   CAS auth and emit the gateway cookie without opening a tunnel.
2. Writing that cookie into the NM profile via the NM Python binding.
3. Letting NM manage the tunnel with `--cookie-on-stdin` as it normally would.

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
| NM connection name for `[ID]` | `SMC-<ID>` | Must match the name in your network applet |
| Default endpoint | first id | What plain `smc-vpn-refresh` connects to |
| Browser for CAS auth | `chrome` | `chromium`, `firefox` or `auto` also accepted |
| Browser profile for CAS auth | *(browser default)* | Chrome/Chromium only; see [Sign-in browser profile](#sign-in-browser-profile) |
| Browser profile for `[ID]` | *(global profile)* | Per-endpoint override of the above |

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

## Sign-in browser profile

By default the CAS login opens in the browser's default profile. A Chrome or
Chromium **profile** can be pinned in `~/.config/smc-gp-vpn/config`:

```ini
BROWSER=chrome
BROWSER_PROFILE=stagwell              # dir key, display name or account email
#ENDPOINT_UK_BROWSER_PROFILE=stagwell # optional per-endpoint override
```

- Values are resolved against the browser's `Local State`: the profile
  directory key (`stagwell`), its display name (`stagwellglobal.com`) or the
  account email all work. An unknown name fails early with an `ERROR:` line
  listing the available profiles.
- The sign-in window is opened in its own process session, so cancelling an
  authentication can never close your browser.
- Other browsers (`firefox`, …) keep the plain browser-name behaviour.

---

## Endpoints

`smc-gp-vpn` supports multiple GlobalProtect endpoints (e.g. a UK and a US
portal). Each endpoint gets **its own NM connection profile and its own
portal-cookie cache**.

How authentication behaves per endpoint:

- **Portal-mode endpoints** (`ENDPOINT_<ID>_AS_GATEWAY=no`, US by default):
  the portal login result is cached and reused — refreshes are silent, no
  browser, until the portal session expires.
- **Gateway-mode endpoints** (`ENDPOINT_<ID>_AS_GATEWAY=yes`, UK by default):
  the CAS gateway rejects the portal login result, so `gpclient`
  authenticates directly against the gateway with `--as-gateway`. This needs
  exactly one browser sign-in **every time** — there is no reusable portal
  session to cache.

Config format (`~/.config/smc-gp-vpn/config`):

```ini
BROWSER=chrome
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

Consequences of gateway mode for the dispatcher: the NM dispatcher
(`99-smc-cookie-refresh`) skips the silent background refresh for
gateway-mode endpoints — it cannot mint a cookie without a browser. When the
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

- **Ubuntu:** flip the **Settings → Network → VPN → SMC-<ID>** toggle.
- **Omarchy:** use the [bar widget](#bar-widget-omarchy-only), or `nmcli`.
- **Anywhere:** `nmcli connection up SMC-UK` / `nmcli connection down SMC-UK`.

No dialog appears in any of these. When the VPN disconnects, the dispatcher
script (`99-smc-cookie-refresh`) automatically mints a fresh gateway cookie in
the background (~1–2 s), so the toggle is ready to use again immediately.
Gateway-mode endpoints are skipped (see `ENDPOINT_<ID>_AS_GATEWAY` above) —
their cookie can only be refreshed with a browser login.

Monitor the refresh in real time:

```bash
journalctl -t smc-cookie-refresh -f
```

---

## When the VPN stops connecting

When the portal session expires, the applet toggle or
`nmcli connection up SMC-UK` will fail silently — the VPN simply does not come
up. Run:

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
of the install. Accepting installs the widget as an Omarchy plugin, enables it
in the bar and adds the `Super + Alt + V` popup hotkey.

The widget shows VPN on/off state in the top bar and opens a popup with
connection details, public IP / country, and Refresh cookie / Reconnect
buttons.

![Widget popup](https://raw.githubusercontent.com/maksym-shaiev/gp-vpn-omarchy/main/docs/screenshot.png)

If you skipped the prompt, install the widget later with:

```bash
git clone https://github.com/maksym-shaiev/gp-vpn-omarchy.git
cd gp-vpn-omarchy && bash install.sh
```

(This adds the hotkey too. `omarchy plugin add` alone installs the widget
without the hotkey — see the widget README.)

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
| `~/.local/bin/smc-vpn-open-url` | CAS sign-in launcher (opens the configured browser/profile) |
| `/etc/NetworkManager/dispatcher.d/99-smc-cookie-refresh` | Auto-refresh on vpn-down / vpn-pre-down |
| `/etc/NetworkManager/dispatcher.d/pre-down.d/99-smc-cookie-refresh` | Symlink to the same script (NM calls pre-down scripts only from there) |

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
rm -f ~/.local/bin/gpclient-smc ~/.local/bin/gpauth-smc \
      ~/.local/bin/smc-vpn-refresh ~/.local/bin/smc-vpn-open-url
rm -rf ~/.config/smc-gp-vpn
rm -f ~/.config/gpclient/smc-cookie-*.json
sudo rm -f /etc/NetworkManager/dispatcher.d/99-smc-cookie-refresh
sudo rm -f /etc/NetworkManager/dispatcher.d/pre-down.d/99-smc-cookie-refresh
```

(The uninstall script removes only its own `smc-cookie-*.json` files from
`~/.config/gpclient` and leaves any other gpclient data alone.)

To remove the NM VPN profiles manually:

```bash
nmcli connection delete SMC-UK SMC-US
```

### Optional cleanup

Remove the Omarchy bar widget (if installed):

```bash
omarchy plugin remove gp-vpn
```

`omarchy plugin remove` leaves the `Super + Alt + V` hotkey line in
`~/.config/hypr/bindings.lua` and `~/.config/gp-vpn-omarchy/widget.conf`
behind — remove those manually, or run the widget's uninstaller, which cleans
all of it:

```bash
bash <(curl -sL https://raw.githubusercontent.com/maksym-shaiev/gp-vpn-omarchy/main/uninstall.sh)
```

---

## Troubleshooting

- **The toggle does nothing / fails silently.** The portal session has
  expired — run `smc-vpn-refresh` (see the previous section). The dispatcher
  log shows whether a background refresh succeeded:
  `journalctl -t smc-cookie-refresh -f`.
- **"The URL can't be shown" / a WebKit dialog appears.** Something (e.g. the
  stock `nm-openconnect` dialog) is invoking the auth dialog — the profile's
  secrets were contaminated or cleared. Re-run `install.sh`; it rewrites the
  profiles cleanly.
- **The browser opens twice for one login (UK).** The endpoint is not in
  gateway mode. Set `ENDPOINT_UK_AS_GATEWAY=yes` in
  `~/.config/smc-gp-vpn/config` (or re-run `install.sh`, which adds the
  default) and run `smc-vpn-refresh` again.
- **`smc-vpn-refresh: command not found`.** `~/.local/bin` is not on your
  `PATH` — add `export PATH="$HOME/.local/bin:$PATH"` to your shell profile.
- **`ERROR: Browser profile 'x' not found`.** The `BROWSER_PROFILE` value must
  be a Chrome/Chromium profile directory key, display name or account email —
  the error lists the available ones.
- **Cookie expired after reboot with the VPN still connected at shutdown.**
  The dispatcher refreshes on `vpn-pre-down` (including shutdown) for
  portal-mode endpoints; gateway-mode endpoints always need one browser login
  after expiry by design.

## Security notes

- The gateway cookie is stored in the NM profile under
  `/etc/NetworkManager/system-connections/` (root-readable only) and in the
  per-endpoint cache file under `~/.config/gpclient/` (mode 600 config dir).
- Nothing is sent anywhere except the GlobalProtect portal itself. The
  optional [bar widget](#bar-widget-omarchy-only) queries `ipinfo.io` to show
  your public IP/country in its popup — that lookup goes to a third party and
  runs only when the popup is opened.
- The dispatcher never opens a browser; it only re-mints cookies from a
  still-valid cache.

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
