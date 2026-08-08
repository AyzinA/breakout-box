# Breakout Box

**Version:** 1.0.2  
**Version Code:** 102  
**Platform:** Android / Magisk  
**Module ID:** `breakout-box`

Breakout Box turns a rooted Android device into a small, self-healing VPN breakout gateway.

Traffic arriving through a configured VPN interface can be forwarded through the Android device's currently active Internet connection, including Wi-Fi and mobile data. The default configuration uses an OpenVPN-style `tun0` interface and `10.8.0.0/24`, but the routing code is interface-agnostic and can also be configured for interfaces such as WireGuard `wg0`.

The module manages IPv4 forwarding, policy routing, NAT, firewall rules, WAN changes, VPN reconnects, ADB-over-TCP, health monitoring, persistent configuration, rotating logs, runtime status, and an optional secure HTTPS upgrader.

---

## Features

- VPN breakout routing through the Android device's active WAN.
- Configurable VPN interface and client subnet.
- Dynamic Wi-Fi/mobile-data WAN detection.
- Policy routing using dedicated routing tables.
- Automatic IPv4 forwarding and reverse-path-filter adjustment.
- Dedicated `BB_FORWARD` and `BB_NAT` iptables chains.
- Self-healing routing and firewall health checks.
- Supervisor-based worker restart after repeated repair failures.
- Automatic handling of VPN reconnects, interface recreation, and WAN changes.
- Configurable ADB over TCP.
- Persistent per-device configuration under `/data/adb/breakout-box/`.
- Main service file logging with size-based rotation.
- Independent upgrader logging with size-based rotation.
- Secure HTTPS update manifests and ZIP downloads.
- Multi-module `update.json` support with module-ID selection.
- Backward-compatible support for legacy single-module manifests.
- Optional SHA-256 verification before installation.
- ZIP validation against expected module ID and `versionCode`.
- Optional Wi-Fi-only upgrade checks.
- Automatic upgrades disabled by default.

---

## Default Network Configuration

```text
VPN interface: tun0
VPN network:   10.8.0.0/24
VPN table:     100
WAN table:     101
```

Default routing priorities:

```text
9000  VPN/client return routing
9001  VPN client traffic to WAN table
9002  traffic arriving on the VPN interface to WAN table
```

The default config is OpenVPN-oriented:

```sh
VPN_INTERFACE="tun0"
VPN_NETWORK="10.8.0.0/24"
```

For WireGuard, only the interface/subnet configuration normally needs to change, for example:

```sh
VPN_INTERFACE="wg0"
VPN_NETWORK="10.10.0.0/24"
```

Use the actual interface and peer/client subnet from your WireGuard configuration.

---

## How Routing Works

Breakout Box detects the active Internet route with Android's routing table, conceptually using:

```sh
ip route get 8.8.8.8
```

Examples:

```text
8.8.8.8 via 10.0.1.1 dev wlan0 src 10.0.1.9
```

or:

```text
8.8.8.8 via 10.132.5.142 dev rmnet_data0 src 10.132.5.141
```

The configured VPN interface is explicitly excluded from WAN selection. This allows the same routing logic to work with names such as `tun0`, `wg0`, or another configured VPN interface.

Breakout Box tracks:

```text
VPN interface
VPN interface index
VPN IPv4 address
WAN interface
WAN gateway
```

When one of those values changes, the routing and firewall state is rebuilt.

---

## Policy Routing

Breakout Box uses two custom routing tables.

### Table 100

Routes traffic back toward VPN clients.

Example:

```text
10.8.0.0/24 dev tun0
```

### Table 101

Routes VPN client traffic out through the active Android WAN.

Wi-Fi example:

```text
10.0.1.1 dev wlan0 scope link
default via 10.0.1.1 dev wlan0
```

Mobile-data example:

```text
10.132.5.142 dev rmnet_data0 scope link
default via 10.132.5.142 dev rmnet_data0
```

If Android exposes a direct/point-to-point WAN without an explicit gateway, the module can use:

```text
default dev <WAN>
```

Typical policy rules with the default configuration look similar to:

```text
9000: from all to 10.8.0.0/24 lookup 100
9001: from 10.8.0.0/24 lookup 101
9002: from all iif tun0 lookup 101
```

The interface and subnet in the actual rules follow `VPN_INTERFACE` and `VPN_NETWORK`.

---

## IPv4 Forwarding

The service enables:

```text
/proc/sys/net/ipv4/ip_forward = 1
```

It also enables forwarding on available IPv4 interfaces and sets `rp_filter` to `0` where supported.

This is necessary for packets arriving through the VPN interface to leave through Wi-Fi or mobile data.

---

## Firewall and NAT

Breakout Box owns two dedicated iptables chains:

```text
BB_FORWARD
BB_NAT
```

They are attached to:

```text
filter/FORWARD
nat/POSTROUTING
```

The forwarding behavior is conceptually:

```text
VPN -> WAN
    ACCEPT

WAN -> VPN
    ACCEPT RELATED,ESTABLISHED
```

Traffic from the configured VPN network is masqueraded through the active WAN:

```text
VPN_NETWORK -> WAN -> MASQUERADE
```

Using dedicated chains avoids repeatedly scanning and modifying many Android system rules.

---

## Self-Healing and Health Checks

Android can recreate interfaces, routing tables, and firewall state when connectivity changes. Examples include:

- Wi-Fi reconnects.
- Mobile-data reconnects.
- Wi-Fi to mobile-data switching.
- Mobile-data to Wi-Fi switching.
- VPN reconnects.
- VPN interface recreation.
- Android `netd` firewall changes.
- Airplane-mode transitions.

The default state-check interval is:

```text
3 seconds
```

The default full health-check interval is:

```text
15 seconds
```

The health checker verifies:

- IPv4 forwarding is enabled.
- The configured VPN interface exists.
- The VPN interface has an IPv4 address.
- The detected WAN interface exists.
- Policy rules exist.
- VPN return routing exists in table `100`.
- WAN default routing exists in table `101`.
- `BB_FORWARD` is hooked into `FORWARD`.
- `BB_NAT` is hooked into `POSTROUTING`.
- Required forwarding rules exist.
- The MASQUERADE rule exists.

If a check fails, Breakout Box attempts to rebuild the routing/firewall state.

---

## Service Supervisor

The routing worker runs under a supervisor loop.

Default settings:

```text
MAX_REPAIR_FAILURES=3
SERVICE_RESTART_DELAY_SECONDS=3
```

After repeated repair failures, the worker exits and the supervisor starts it again after the configured delay.

This prevents a temporary Android networking failure from permanently stopping breakout routing.

---

## Persistent Configuration

Packaged defaults are stored in:

```text
/data/adb/modules/breakout-box/default-config.conf
```

The persistent per-device configuration is:

```text
/data/adb/breakout-box/config.conf
```

On first installation, `customize.sh` creates the persistent configuration from the packaged defaults. Existing persistent configuration is preserved during module upgrades.

Configuration precedence is:

```text
service/upgrader built-in defaults
        ↓
default-config.conf
        ↓
/data/adb/breakout-box/config.conf
```

The persistent config wins.

### Default configuration

```sh
VPN_INTERFACE="tun0"
VPN_NETWORK="10.8.0.0/24"

VPN_TABLE="100"
WAN_TABLE="101"

VPN_TO_CLIENT_PRIORITY="9000"
VPN_FROM_CLIENT_PRIORITY="9001"
VPN_IIF_PRIORITY="9002"

CHECK_INTERVAL_SECONDS="3"
HEALTH_CHECK_INTERVAL_SECONDS="15"
SERVICE_RESTART_DELAY_SECONDS="3"
MAX_REPAIR_FAILURES="3"

ENABLE_ADB_TCP=true
ADB_TCP_PORT="5555"

FILTER_CHAIN="BB_FORWARD"
NAT_CHAIN="BB_NAT"

LOG_TAG="breakout-box"
LOG_LEVEL="info"
MAX_LOG_SIZE=1048576
MAX_LOG_FILES=3

AUTO_UPDATE=false
UPDATE_CHECK_INTERVAL_SECONDS=86400
UPDATE_INITIAL_DELAY_SECONDS=120
UPDATE_JSON_URL="https://raw.githubusercontent.com/AyzinA/breakout-box/master/update.json"
UPDATE_REQUIRE_SHA256=true
UPDATE_INSTALL_ONLY_ON_WIFI=false
UPDATE_KEEP_DOWNLOADED_ZIP=false

UPGRADER_MAX_LOG_SIZE=1048576
UPGRADER_MAX_LOG_FILES=3
```

---

## ADB over TCP

ADB-over-TCP support is configurable:

```sh
ENABLE_ADB_TCP=true
ADB_TCP_PORT="5555"
```

When enabled, the service configures Android's persistent and active ADB TCP port and restarts `adbd` when required.

To disable this behavior:

```sh
ENABLE_ADB_TCP=false
```

---

## Logging

### Main service log

The service writes to:

```text
/data/adb/breakout-box/breakout-box.log
```

Default rotation settings:

```sh
MAX_LOG_SIZE=1048576
MAX_LOG_FILES=3
```

Rotated files are:

```text
breakout-box.log
breakout-box.log.1
breakout-box.log.2
breakout-box.log.3
```

The Android logcat tag is:

```text
breakout-box
```

### Upgrader log

The upgrader writes independently to:

```text
/data/adb/breakout-box/upgrader.log
```

Default rotation settings:

```sh
UPGRADER_MAX_LOG_SIZE=1048576
UPGRADER_MAX_LOG_FILES=3
```

Rotated files are:

```text
upgrader.log
upgrader.log.1
upgrader.log.2
upgrader.log.3
```

The Android logcat tag is:

```text
breakout-box-upgrader
```

### Watch both logcat streams

```sh
adb logcat -s breakout-box:I breakout-box-upgrader:I
```

For timestamped output:

```sh
adb logcat -v time -s breakout-box:I breakout-box-upgrader:I
```

To save the combined output while viewing it:

```sh
adb logcat -v time -s breakout-box:I breakout-box-upgrader:I | tee breakout-box-logcat.txt
```

---

## Runtime Status Files

Main routing status:

```text
/data/adb/breakout-box/status
```

Upgrader status:

```text
/data/adb/breakout-box/upgrader.status
```

Upgrader PID:

```text
/data/adb/breakout-box/upgrader.pid
```

Upgrade working directory:

```text
/data/adb/breakout-box/upgrade/
```

---

## Secure HTTPS Upgrader

`upgrader.sh` is designed to be reusable across Magisk modules. It reads the module's identity and version from `module.prop` rather than hardcoding `breakout-box` into its update logic.

The upgrader is not tied to GitHub. The manifest and module ZIP may be hosted on any HTTPS server that the device can access.

The configured manifest URL is:

```sh
UPDATE_JSON_URL="https://raw.githubusercontent.com/AyzinA/breakout-box/master/update.json"
```

This URL is only the default hosting location for this repository.

### Automatic upgrades

Automatic upgrades are disabled by default:

```sh
AUTO_UPDATE=false
```

Enable them in the persistent config with:

```sh
AUTO_UPDATE=true
```

Default schedule:

```sh
UPDATE_INITIAL_DELAY_SECONDS=120
UPDATE_CHECK_INTERVAL_SECONDS=86400
```

The automatic loop will not run more frequently than once per hour even if a lower interval is configured.

### Manual upgrader commands

Check once:

```sh
su -c /data/adb/modules/breakout-box/upgrader.sh check
```

Display status:

```sh
su -c /data/adb/modules/breakout-box/upgrader.sh status
```

Run the continuous loop manually:

```sh
su -c /data/adb/modules/breakout-box/upgrader.sh loop
```

Normally the service starts the loop automatically when `AUTO_UPDATE=true`.

---

## Multi-Module `update.json`

The preferred manifest format allows one HTTPS JSON file to contain update information for multiple modules.

Example:

```json
{
  "schemaVersion": 2,
  "modules": {
    "breakout-box": {
      "version": "1.0.2",
      "versionCode": 102,
      "zipUrl": "https://example.com/modules/breakout-box-v1.0.2.zip",
      "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      "changelog": "https://example.com/modules/CHANGELOG.md"
    },
    "another-module": {
      "version": "2.4.0",
      "versionCode": 240,
      "zipUrl": "https://example.com/modules/another-module-v2.4.0.zip",
      "sha256": "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
      "changelog": "https://example.com/modules/another-module-changelog.md"
    }
  }
}
```

The upgrader reads its local `module.prop`:

```properties
id=breakout-box
```

and selects only:

```text
modules.breakout-box
```

All unrelated entries are ignored.

`schemaVersion` identifies the manifest layout. The current upgrader primarily selects the module entry by structure/module ID and also keeps compatibility with the legacy single-module format.

### Legacy single-module manifest

The upgrader also accepts the older format:

```json
{
  "moduleId": "breakout-box",
  "version": "1.0.2",
  "versionCode": 102,
  "zipUrl": "https://example.com/breakout-box-v1.0.2.zip",
  "sha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "changelog": "https://example.com/CHANGELOG.md"
}
```

---

## Upgrade Security and Validation

Before installing a newer module, the upgrader performs several checks.

### HTTPS only

The manifest URL and ZIP URL must use:

```text
https://
```

Plain HTTP URLs are rejected.

### Version comparison

The remote `versionCode` must be numerically greater than the installed `versionCode`.

For this release:

```text
installed/current: 102
```

A manifest with `versionCode <= 102` is considered up to date.

### SHA-256

With:

```sh
UPDATE_REQUIRE_SHA256=true
```

the downloaded ZIP must match the manifest's SHA-256 value.

### ZIP module validation

Before installation, the upgrader extracts the ZIP's root `module.prop` and verifies:

```text
id == local module ID
versionCode == manifest versionCode
```

This prevents a manifest entry from accidentally installing a ZIP for another module or another version.

### Installation

Verified updates are installed using Magisk:

```sh
magisk --install-module <zip>
```

A reboot is required after a successfully installed upgrade.

---

## Repository Layout

Current source repository layout:

```text
breakout-box/
├── CHANGELOG.md
├── README.md
├── update.json
├── update.json.example
├── breakout-box-v1.0.1.zip
├── breakout-box-v1.0.2.zip
├── docs/
│   └── v1.0.1 vs v1.0.2.md
└── src/
    ├── customize.sh
    ├── default-config.conf
    ├── module.prop
    ├── service.sh
    ├── uninstall.sh
    └── upgrader.sh
```

The installable module ZIP has the Magisk files at its root:

```text
module.prop
customize.sh
default-config.conf
service.sh
uninstall.sh
upgrader.sh
```

---

## Installation

1. Build or download the `breakout-box-v1.0.2.zip` Magisk module.
2. Install it using the Magisk app or another supported Magisk module installation method.
3. Reboot the phone.
4. Confirm the persistent configuration exists:

```sh
su -c ls -l /data/adb/breakout-box/config.conf
```

5. Verify service status and routing.

Existing `/data/adb/breakout-box/config.conf` is preserved during upgrades.

---

## Basic Diagnostics

### Watch service and upgrader logs

```sh
adb logcat -s breakout-box:I breakout-box-upgrader:I
```

### Show main status

```sh
adb shell su -c 'cat /data/adb/breakout-box/status'
```

### Show recent service log

```sh
adb shell su -c 'tail -n 100 /data/adb/breakout-box/breakout-box.log'
```

### Show recent upgrader log

```sh
adb shell su -c 'tail -n 100 /data/adb/breakout-box/upgrader.log'
```

### Check IP forwarding

```sh
adb shell su -c 'cat /proc/sys/net/ipv4/ip_forward'
```

Expected:

```text
1
```

### Check configured VPN interface

For default OpenVPN:

```sh
adb shell su -c 'ip -4 addr show tun0'
```

For WireGuard configured as `wg0`:

```sh
adb shell su -c 'ip -4 addr show wg0'
```

### Check active WAN

```sh
adb shell su -c 'ip route get 8.8.8.8'
```

### Check policy rules

```sh
adb shell su -c 'ip rule show'
```

### Check routing tables

```sh
adb shell su -c 'ip route show table 100'
adb shell su -c 'ip route show table 101'
```

### Check firewall rules

```sh
adb shell su -c 'iptables -L BB_FORWARD -n -v --line-numbers'
adb shell su -c 'iptables -t nat -L BB_NAT -n -v --line-numbers'
```

### Check upgrader status

```sh
adb shell su -c '/data/adb/modules/breakout-box/upgrader.sh status'
```

---

## Troubleshooting

### `VPN unavailable; stale policy routes removed`

Confirm that the configured VPN interface exists and has an IPv4 address:

```sh
adb shell su -c 'grep -E "^(VPN_INTERFACE|VPN_NETWORK)=" /data/adb/breakout-box/config.conf'
adb shell su -c 'ip -4 addr show tun0'
```

Replace `tun0` with the configured interface if necessary.

If using WireGuard, ensure the config contains the correct interface, for example:

```sh
VPN_INTERFACE="wg0"
```

and check:

```sh
adb shell su -c 'ip -4 addr show wg0'
```

### Health check repeatedly repairs the rules

Inspect all runtime state:

```sh
adb shell su -c '
  echo "=== FORWARDING ==="
  cat /proc/sys/net/ipv4/ip_forward
  echo "=== RULES ==="
  ip rule show
  echo "=== TABLE 100 ==="
  ip route show table 100
  echo "=== TABLE 101 ==="
  ip route show table 101
  echo "=== FORWARD ==="
  iptables -L BB_FORWARD -n -v --line-numbers
  echo "=== NAT ==="
  iptables -t nat -L BB_NAT -n -v --line-numbers
'
```

A repeated repair usually means Android or another root/networking component is modifying one of the expected rules.

### No traffic reaches the Internet

Check:

```sh
adb shell su -c 'cat /proc/sys/net/ipv4/ip_forward'
adb shell su -c 'ip route get 8.8.8.8'
adb shell su -c 'ip rule show'
adb shell su -c 'ip route show table 100'
adb shell su -c 'ip route show table 101'
adb shell su -c 'iptables -L BB_FORWARD -n -v'
adb shell su -c 'iptables -t nat -L BB_NAT -n -v'
```

Also verify that `VPN_NETWORK` is the subnet used by the clients being forwarded, not merely the Android device's own VPN address.

### Upgrader says `No update manifest entry found`

Check the local module ID:

```sh
adb shell su -c 'grep "^id=" /data/adb/modules/breakout-box/module.prop'
```

Expected:

```text
id=breakout-box
```

Then inspect the downloaded/remote manifest and ensure it contains the exact matching key:

```json
"modules": {
  "breakout-box": {
```

Also verify the configured URL:

```sh
adb shell su -c 'grep "^UPDATE_JSON_URL=" /data/adb/breakout-box/config.conf'
```

The value must be a plain HTTPS URL, not Markdown link syntax.

Correct:

```sh
UPDATE_JSON_URL="https://example.com/update.json"
```

Incorrect:

```text
[https://example.com/update.json](https://example.com/update.json)
```

### `Segmentation fault` during manifest parsing

The upgrader prefers Magisk/KernelSU BusyBox `awk` where available because vendor Android/Toybox `awk` implementations can be unreliable on some ROMs.

Check BusyBox availability:

```sh
adb shell su -c 'ls -l /data/adb/magisk/busybox 2>/dev/null'
```

Then inspect:

```sh
adb logcat -s breakout-box-upgrader:I
```

and:

```sh
adb shell su -c 'tail -n 100 /data/adb/breakout-box/upgrader.log'
```

### Upgrader reports SHA-256 mismatch

Recalculate the exact published ZIP hash and update the manifest before retrying.

On Linux:

```sh
sha256sum breakout-box-v1.0.2.zip
```

The manifest value must match the exact file being downloaded by `zipUrl`.

### Upgrader reports a ZIP module-ID mismatch

Inspect the ZIP's root `module.prop`:

```sh
unzip -p breakout-box-v1.0.2.zip module.prop
```

It must contain:

```properties
id=breakout-box
```

### Upgrader reports a `versionCode` mismatch

The `versionCode` inside the ZIP's `module.prop` must exactly match the value in the selected manifest entry.

For v1.0.2:

```properties
versionCode=102
```

### Automatic upgrades do not start

Confirm:

```sh
adb shell su -c 'grep "^AUTO_UPDATE=" /data/adb/breakout-box/config.conf'
```

It must be:

```sh
AUTO_UPDATE=true
```

Then check:

```sh
adb shell su -c '/data/adb/modules/breakout-box/upgrader.sh status'
```

and logcat:

```sh
adb logcat -s breakout-box:I breakout-box-upgrader:I
```

### Stale upgrader PID

Check:

```sh
adb shell su -c 'cat /data/adb/breakout-box/upgrader.pid 2>/dev/null'
```

and verify whether that PID still exists. The service removes stale PID files before launching a new automatic loop.

### Persistent config contains old values after upgrading

This is expected. The module deliberately preserves:

```text
/data/adb/breakout-box/config.conf
```

Compare it with:

```text
/data/adb/modules/breakout-box/default-config.conf
```

and manually add/change new settings you want to use.

---

## Uninstall / Reset

Removing the Magisk module removes the module itself, while persistent runtime/configuration data may remain under:

```text
/data/adb/breakout-box/
```

For a complete manual reset after uninstalling:

```sh
su -c 'rm -rf /data/adb/breakout-box'
```

Do this only if you intentionally want to remove the saved configuration, logs, status, and upgrader state.

---

## Version 1.0.2 Highlights

Compared with v1.0.1, v1.0.2 adds:

- Persistent configuration.
- Faster state polling.
- Full routing/firewall health checks.
- Self-healing repair logic.
- Service supervision.
- Dedicated iptables chains.
- Android-aware policy-routing priorities.
- Improved gateway handling.
- Configurable ADB-over-TCP.
- Main service log rotation.
- Runtime status reporting.
- VPN-interface-generic routing logic.
- Secure reusable `upgrader.sh`.
- Multi-module manifest selection.
- Independent upgrader log rotation.
- HTTPS-only downloads.
- Optional SHA-256 verification.
- Module-ID and `versionCode` ZIP validation.
- Optional Wi-Fi-only automatic upgrades.

---

## Module Metadata

```properties
id=breakout-box
name=Breakout Box
version=1.0.2
versionCode=102
author=NONAME
description=Self-healing VPN breakout routing/NAT with secure HTTPS upgrader
```
