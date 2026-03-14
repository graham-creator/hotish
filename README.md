# hotish 🔥

> **A bash WiFi hotspot manager with a terminal UI — just your laptop sharing internet from the command line.**

![Version](https://img.shields.io/badge/version-4.2.0-cyan)
![Shell](https://img.shields.io/badge/shell-bash-blue)
![Platform](https://img.shields.io/badge/platform-Linux-lightgrey)
![License](https://img.shields.io/badge/license-MIT-green)

```
██╗  ██╗ ██████╗ ████████╗██╗███████╗██╗  ██╗
██║  ██║██╔═══██╗╚══██╔══╝██║██╔════╝██║  ██║
███████║██║   ██║   ██║   ██║███████╗███████║
██╔══██║██║   ██║   ██║   ██║╚════██║██╔══██║
██║  ██║╚██████╔╝   ██║   ██║███████║██║  ██║
╚═╝  ╚═╝ ╚═════╝    ╚═╝   ╚═╝╚══════╝╚═╝  ╚═╝
WiFi Hotspot Manager  •  by graham / IRIR
```

---

## What it does

hotish turns your Linux laptop into a WiFi hotspot with a full arrow-key TUI. It handles everything — creating the virtual AP interface, configuring NetworkManager, setting up NAT/internet sharing, and tearing it all down cleanly when you stop it.

**Key features:**
- Arrow-key TUI with live status header
- Start/stop/restart hotspot with one keypress
- Internet sharing (NAT) through your existing WiFi or ethernet uplink
- Live bandwidth monitor with per-second RX/TX graphs
- Connected clients list (pulled from lnxrouter's dnsmasq leases)
- Built-in speed test (uses `speedtest-cli`, `fast`, or curl fallback)
- QR code to connect your phone instantly
- MAC whitelist / blacklist
- Multiple saved profiles (SSID + password + channel presets)
- Headless CLI mode (`--start`, `--stop`, `--status`) for scripting
- Safe uninstaller with config backup

---

## Requirements

| Package | Purpose | Install |
|---------|---------|---------|
| `lnxrouter` | Hotspot engine (AP + NAT) | See below |
| `iw` | Interface detection | `sudo apt install iw` |
| `hostapd` | Access point daemon | `sudo apt install hostapd` |
| `dnsmasq` | DHCP for clients | `sudo apt install dnsmasq` |
| `qrencode` | QR code display | `sudo apt install qrencode` |
| `speedtest-cli` | Speed test | `sudo apt install speedtest-cli` |
| `vnstat` | Bandwidth history | `sudo apt install vnstat` |

> `lnxrouter` is **not** in apt. See installation below.

---

## Installation

### Step 1 — Clone and run the installer

```bash
git clone https://github.com/your-username/hotish
cd hotish
sudo bash ./hotish.sh
```

> **Note:** Use `sudo bash ./hotish.sh` — not `sudo ./hotish.sh`. sudo doesn't resolve `./` paths directly.

The installer will:
1. Install required system packages via apt
2. Clone and install [lnxrouter](https://github.com/garywill/linux-router) from GitHub
3. Copy `hotish` to `/usr/local/bin/hotish`
4. Open the TUI in a new terminal window

### Step 2 — Run it

```bash
hotish          # opens TUI in a new terminal window
hotish --tui    # opens TUI in the current terminal
```

### Manual lnxrouter install (if the installer can't reach GitHub)

```bash
git clone https://github.com/garywill/linux-router
sudo install -m755 linux-router/lnxrouter /usr/local/bin/lnxrouter
```

---

## Usage

### TUI

```
hotish
```

Navigate with arrow keys, select with Enter, go back with `q`.

```
 ▶  Start Hotspot
 ■  Stop Hotspot
 ↺  Restart Hotspot
 ◉  Status & Devices
 ✎  Configure          SSID · Password · Channel · Hidden
 ⊞  Profiles
 ⚿  Device Access      Whitelist · Blacklist
 ≋  Bandwidth Monitor  (live)
 ⚡  Speed Test
 ⊡  Show QR Code
 ☰  View Log
 ✖  Quit
```

### CLI (headless / scripting)

```bash
hotish --start      # start hotspot
hotish --stop       # stop hotspot
hotish --restart    # restart hotspot
hotish --status     # one-line status check
hotish --help       # full help
```

---

## How it works

hotish uses [lnxrouter](https://github.com/garywill/linux-router) as its hotspot engine. lnxrouter handles the low-level work: creating a virtual AP interface, configuring hostapd, running a private dnsmasq instance for DHCP, and setting up iptables NAT rules.

**Startup sequence (important for MT7921 and similar cards):**

```
1. Detect internet uplink interface (ip route)
2. Stop NetworkManager — releases the wireless interface
3. Kill any stale dnsmasq instances
4. Write NM unmanaged config for the AP virtual interface
5. Launch lnxrouter in background
6. Wait 5 seconds for lnxrouter to establish the AP
7. Restart NetworkManager — reconnects uplink (internet)
```

The 5-second wait before restarting NetworkManager is critical. If NM comes back too early, it races with lnxrouter and grabs the virtual interface before lnxrouter can configure it.

**Stop sequence:**

```
1. Kill lnxrouter
2. Remove the NM unmanaged config
3. Reload NetworkManager — it reclaims full control of wlp1s0
```

**Config files** (all in `~/.hotish/`):

```
~/.hotish/default.conf      # SSID, password, channel, hidden flag
~/.hotish/profiles/         # saved profiles
~/.hotish/whitelist.txt     # MAC whitelist (one per line)
~/.hotish/blacklist.txt     # MAC blacklist (one per line)
~/.hotish/hotish.log        # lnxrouter output log
```

---

## Known hardware notes

### MediaTek MT7921 (mt7921e driver)

This is a common chip in modern Lenovo and ASUS laptops. It has a quirk: NetworkManager holds the wireless interface exclusively and blocks lnxrouter from creating a virtual AP interface (`RTNETLINK: Device or resource busy`). The startup sequence above (stop NM → start lnxrouter → restart NM) is the only reliable fix.

Additionally, the system dnsmasq may hold port 53/67 and cause lnxrouter to fail silently after hostapd starts. hotish kills stale dnsmasq instances before launching.

### Channel selection

hotish defaults to **channel 6 (2.4GHz)** for maximum phone compatibility. 5GHz channels (36+) are supported but some phones and IoT devices only scan 2.4GHz.

If your uplink is on 5GHz, the MT7921 card handles concurrent STA (uplink) + AP (hotspot) on different bands — this is normal and works well.

---

## Uninstalling

```bash
hotish --coldish
```

This will:
- Back up your config to `/tmp/hotish-config-backup-TIMESTAMP.tar.gz`
- Stop any running hotspot
- Remove `/usr/local/bin/hotish`
- Remove `/usr/local/bin/lnxrouter`
- Remove `~/.hotish/` (all config, profiles, logs)
- Clean up NetworkManager conf files
- Remove lnxrouter temp files

System packages installed by apt (hostapd, dnsmasq, iw, etc.) are **not** removed as they may be used by other tools.

---

## File structure

```
hotish.sh               # the entire program — one self-contained bash script
README.md               # this file
```

hotish is intentionally a single file. Copy it anywhere, run it, done.

---

## Built with

- [lnxrouter](https://github.com/garywill/linux-router) by garywill — the hotspot engine
- Pure bash — no Python, no Node, no compiled dependencies
- Tested on Kali Linux with MediaTek MT7921 (mt7921e)

---

*by graham-creator
