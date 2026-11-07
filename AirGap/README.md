# AirGap

`airgap.sh` locks a Mac down to **IPv4 over Wi-Fi only** and keeps it that way, without turning off System Integrity Protection (SIP). Wi-Fi stays under your control: turn it on and off as usual. Every other way in or out (Ethernet, USB adapters, iPhone tethering, Thunderbolt Bridge, Bluetooth, AirDrop, VPN tunnels, IPv6) is shut.

Works on macOS 10.15 Catalina and later, on Intel and Apple silicon Macs.

## Quick start

```bash
git clone https://github.com/shaybenavi/MacUtils.git
cd MacUtils/AirGap
sudo bash airgap.sh install
```

No `git` on the Mac? Download the repository as a ZIP from GitHub, unzip it, and run the same `sudo bash airgap.sh install` from the `AirGap` folder.

## Syntax

```
sudo bash airgap.sh <command>
```

| Command | What it does |
| --- | --- |
| `install` | Saves your current network settings, applies everything below and starts the background enforcer. Safe to run again (for example after a macOS upgrade). |
| `status` | Shows the firewall state and rules, every network service with its IPv6 setting, the T2 link, the profile, Application Firewall, FileVault, macOS version and the last log lines. |
| `uninstall` | Puts network services and IPv6 back the way they were before `install`, removes the firewall rules, enforcer and profile, and turns Bluetooth back on. |
| `enforce` | Internal: run by the background enforcer. You never need to call it yourself. |

All commands need `sudo`. After `install`, the script also lives at `/Library/Application Support/airgap/airgap.sh`, so you can run `status` and `uninstall` from there even if you delete your copy.

## What `install` does

### Kept enforced permanently

A LaunchDaemon re-applies these at every boot, whenever network settings change (for example when you plug in a new adapter), whenever `/etc/pf.conf` changes (for example after a macOS update), and every 5 minutes.

| Area | Setting |
| --- | --- |
| pf firewall | Loopback open; all IPv6 dropped; IPv4 allowed only outbound over Wi-Fi (plus replies and DHCP); everything else dropped, including all unsolicited inbound traffic |
| Network services | Every service except Wi-Fi is disabled, including adapters added later |
| IPv6 | Set to Off on every network service, Wi-Fi included |
| Wi-Fi multicast | Nothing sent to 224.0.0.0/4 over Wi-Fi, so Bonjour (mDNS) and SSDP announcements stay off the local network |
| T2 chip link | On Macs with a T2 chip, the internal interface with the fixed MAC `ac:de:48:00:11:22` (usually `en5`) is left open. It connects macOS to the T2 chip on the logic board, not to any network, and the Touch Bar and camera depend on it. |

The firewall rules generated on a T2 Mac with Wi-Fi on `en0`:

```
pass quick on lo0 all
pass quick on en5 all
block drop quick inet6 all
pass in quick on en0 inet proto udp from any port 67 to any port 68
block drop out quick on en0 inet from any to 224.0.0.0/4
pass out quick on en0 inet all keep state
block drop quick all
```

If the rules ever fail to load, the script fails closed: it loads a block-everything ruleset (Wi-Fi included) and writes the error to the log.

### Applied once

- Application Firewall on, block all incoming connections, stealth mode.
- Bluetooth off.
- AirDrop off and undiscoverable, Handoff off.
- A configuration profile, "Airgap restrictions", that keeps AirDrop, Handoff, AirPlay Receiver and Bluetooth off. On Catalina the script installs it itself. On macOS 11 and later Apple only allows installing profiles by hand, so the script opens it and you approve it (see below).

## Steps only you can do

- [ ] Use a standard (non-admin) account day to day. Anyone with admin rights can undo all of this.
- [ ] macOS 11 or later: approve the profile in System Settings > General > Device Management (or Privacy & Security > Profiles) > Airgap restrictions > Install. On macOS 11 and 12 it is System Preferences > Profiles.
- [ ] Apple silicon laptops on macOS 13 or later: System Settings > Privacy & Security > Accessories > "Allow accessories to connect" > Always ask.
- [ ] Macs with a T2 chip or Apple silicon: start up in Recovery, open Utilities > Startup Security Utility, and set Full Security, disallow booting from external media, and (T2) turn on a firmware password. Write the password down: if it is forgotten, only Apple can remove it.
- [ ] While in Recovery, open Terminal and check that `csrutil status` reports SIP as enabled.
- [ ] Keep FileVault on.
- [ ] Keep macOS up to date. macOS 10.15 Catalina stopped receiving security updates in 2022; Intel Macs that support it should move to macOS 26 Tahoe, the last version for Intel. Run `install` again after upgrading.

## Checking that it works

```bash
sudo bash airgap.sh status
```

Expect: pf Enabled, the enforcer running, every service except Wi-Fi disabled, and IPv6 Off on all of them.

To watch live traffic with the interface and sending process on every packet:

```bash
sudo tcpdump -n -k INP -i any
```

To watch only what goes over the Wi-Fi radio:

```bash
ipconfig getifaddr en0                  # your Wi-Fi IP
sudo tcpdump -n -i en0 udp port 5353    # Bonjour on Wi-Fi
```

| What you see | What it means |
| --- | --- |
| Source `127.0.0.1` or `fe80::1`, interface `lo0` | Loopback: stays inside the Mac |
| Interface `en5` (T2 Macs) | The T2 chip's internal link: stays inside the Mac |
| Your Wi-Fi IP sending to `224.0.0.251:5353` | Bonjour going out over the radio: should not appear after install |
| Other devices' addresses on `en0` | Incoming packets: tcpdump sees them before pf drops them |
| Anything else outbound | Should only be IPv4 from your Wi-Fi IP |

## Files it creates or changes

| Path | Purpose |
| --- | --- |
| `/Library/Application Support/airgap/` | Installed copy of the script, saved pre-install network settings, the profile |
| `/Library/LaunchDaemons/local.airgap.plist` | The background enforcer |
| `/etc/pf.anchors/airgap` | The generated firewall rules |
| `/etc/pf.conf` | Two lines added that load the rules (a backup is kept at `/etc/pf.conf.before-airgap`) |
| `/var/log/airgap.log` | Everything the enforcer changes, and any errors |

`uninstall` removes all of these except the log and the `pf.conf` backup.

## Limits

- This is a software lockdown, not a physical air gap. The Wi-Fi and Bluetooth hardware is built in, so only software keeps it off, and anything running with admin or root rights can undo it.
- On macOS 15, one developer reported some Apple processes sending traffic despite a pf block-all rule ([Apple Developer Forums](https://developer.apple.com/forums/thread/776914)). Verify with `tcpdump` on your Mac.
- Side effects: VPNs, Ethernet, tethering, AirPrint and AirPlay discovery stop working, and IPv6-only networks have no connectivity.
- The script was tested against simulated macOS tools, not on every macOS version. Run `status` after installing and check the output.
