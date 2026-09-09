# SMC VPN Omarchy Bar Widget — Development Notes

## Objective
Create an Omarchy-style bar widget for the SMC GlobalProtect VPN, similar to the built-in `omarchy.network` / `omarchy.tailscale` widgets, that:
- Shows VPN on/off state in the top bar.
- Opens a popup panel with connection details and actions.
- Uses the existing NetworkManager profile `SMC` managed by the `smc-gp-vpn` setup.

## Current Implementation

### Files
- `~/.config/omarchy/bar/modules/max.smcvpn.qml` — the widget / popup.
- `~/.config/omarchy/bar/modules/max.smcvpn-status` — Python helper that prints VPN status as JSON.
- `~/.config/omarchy/shell.json` — loads `max.smcvpn` as a custom QML bar module in the right bar section.

### Bar icon
- Left-click **opens the popup** (like `omarchy.network` / `omarchy.tailscale`).
- Shows a closed lock (`\uf023`) when the `SMC` connection is active, open lock (`\uf09c`) when inactive.
- Tooltip shows connected/disconnected state.

### Popup contents
- **Hero**: title "SMC VPN", status meta, device pill, lock/unlock icon, on/off `ToggleSwitch`, and a `BusyIndicator` when an action is in flight.
- **Connection Details**:
  - Status
  - Portal
  - Device (the actual tunnel device, e.g. `vpn0`)
  - Tunnel IP
  - Gateway (shown only when available)
  - DNS (shown only when available)
  - Connected since
- **Public Address** (fetched when the popup opens):
  - Public IP
  - Country (from `ipinfo.io`)
- **Actions**: "Refresh cookie" and "Reconnect" buttons.

### Commands used
- `~/.config/omarchy/bar/modules/max.smcvpn-status` — poll state/details (JSON).
- `nmcli connection up SMC` / `nmcli connection down SMC` — toggle from the hero switch.
- `smc-vpn-refresh --no-connect` — refresh gateway cookie only.
- `smc-vpn-refresh` — refresh cookie and reconnect.
- `curl -s --max-time 5 https://ipinfo.io/json` — public IP / country / city, only on popup open.

### Busy state
- The `ToggleSwitch` and action buttons are disabled while an operation is running.
- A `BusyIndicator` appears in the popup hero, and the bar icon rotates a spinner glyph while busy.

### Keyboard shortcuts
- `t` / `T` — toggle VPN
- `r` — refresh cookie
- `R` — reconnect
- `Esc` / `q` — close popup

## How We Got Here

### Original Plan
1. Implement the widget as a **third-party plugin** under `~/.config/omarchy/plugins/max.smcvpn/` with a `manifest.json` and a `Panel.qml` mirroring `omarchy.network`.
2. Add the plugin ID to `~/.config/omarchy/shell.json`.
3. Add IPC for an external helper script.

### What Changed
- The third-party plugin validated and was reported as enabled, but did not render.
- After investigation, the root cause was that the root `Panel` item lacked `implicitWidth` / `implicitHeight`, so the bar’s `ModuleSlot` collapsed it to 0 × 0.
- Rather than keep the third-party plugin path, we switched to a **custom QML bar module** (`~/.config/omarchy/bar/modules/max.smcvpn.qml`) because it is simpler and works reliably today.
- The original full popup implementation was lost when the plugin directory was removed; it was rewritten from scratch using `PanelHero`, `PanelSectionHeader`, `GridLayout`, and the built-in `KeyboardPanel`/`PanelKeyCatcher` pattern.

### Device / IP Detection Fix
- The first version read the device from `nmcli connection show --active`, which reported the underlying physical interface (`enp1s0`) for the VPN connection. GlobalProtect creates the actual tunnel as a separate `tun` interface (`vpn0`).
- The helper was rewritten in Python and now enumerates `tun` devices with `ip -j link show type tun`, skips Tailscale’s `100.64.0.0/10` range and link-local addresses, and reports the real tunnel device and IP.
- Gateway is hidden when it is `0.0.0.0` or unavailable.

### Previous Issues
- `Unable to assign [undefined] to bool` warnings appeared in the original `Panel.qml` around `Button.onHovered` handlers. Those were likely caused by importing `QtQuick.Controls` unqualified and using `Button`/`ToggleSwitch` from the wrong namespace. The current file aliases `QtQuick.Controls` as `QC` and uses `qs.Ui.Button` / `qs.Ui.ToggleSwitch`, eliminating the warning.

## Caveats
- **Public IP / Country**: the lookup uses `ipinfo.io`. It runs only when the popup opens and caches until the popup is closed/reopened. Depending on routing, the returned IP may be the VPN egress or your local ISP (split tunnel). The current SMC setup routes traffic through the VPN, so it shows the US/Google egress.
- **Helper script location**: it currently lives next to the QML module in `~/.config`. Future packaging can move it into `smc-gp-vpn/scripts/` or convert the widget into a proper Omarchy plugin.

## Next Steps / Future Decisions
1. **Live-test the popup** by clicking the bar icon and confirming the updated details (device `vpn0`, tunnel IP, DNS, public IP/country) display correctly.
2. **Packaging decision**:
   - Keep the custom-module approach (fastest, works now), or
   - Move to a third-party plugin in `~/.config/omarchy/plugins/max.smcvpn/` now that the visibility fix is known, or
   - Integrate into the `smc-gp-vpn` repo (`scripts/` + `install.sh`) and ship as an installable plugin.
3. **Polish**:
   - Add copy-to-clipboard for tunnel IP / public IP.
   - Add a manual "Refresh public IP" button if desired.
   - Improve the "Since" formatting (relative, e.g. "2h 14m").
