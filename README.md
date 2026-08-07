# Breakout Box

**Version:** 1.0.2
**Version Code:** 102
**Platform:** Android / Magisk
**Module ID:** `breakout-box`

Breakout Box turns a rooted Android device into a small VPN breakout gateway.

Traffic arriving through an OpenVPN tunnel such as `tun0` can be forwarded through the Android device's currently active Internet connection, including:

* Wi-Fi
* Mobile data
* Supported Android WAN interfaces

The module automatically manages IPv4 forwarding, policy routing, NAT, firewall rules, WAN changes, VPN reconnects, ADB-over-TCP, health monitoring, persistent configuration, logging, and optional automatic updates.

---

# Features

## VPN breakout routing

Traffic arriving from the configured OpenVPN network is routed through the Android device's real Internet connection.

Default configuration:

```text
VPN interface: tun0
VPN network:   10.8.0.0/24
VPN table:     100
WAN table:     101
```

The module dynamically detects the currently active WAN interface.

Examples include:

```text
wlan0
rmnet_data0
rmnet_data1
ccmni0
wwan0
```

No WAN interface needs to be hardcoded.

---

## Automatic WAN detection

Breakout Box determines the active Internet path using the Android routing table.

For example:

```sh
ip route get 8.8.8.8
```

may return:

```text
8.8.8.8 via 10.0.1.1 dev wlan0 src 10.0.1.9
```

or on mobile data:

```text
8.8.8.8 via 10.132.5.142 dev rmnet_data0 src 10.132.5.141
```

Breakout Box detects:

```text
WAN interface
Gateway
VPN interface
VPN address
```

and automatically rebuilds its routing configuration whenever these values change.

---

# Routing Architecture

Breakout Box uses dedicated policy-routing tables.

Default tables:

```text
100 = VPN/client return routing
101 = breakout WAN routing
```

Default policy priorities:

```text
9000
9001
9002
```

These priorities are intentionally below Android's normal networking policy rules, which commonly begin around priority `10000`.

Typical rules look similar to:

```text
9000: from all to 10.8.0.0/24 lookup 100
9001: from 10.8.0.0/24 lookup 101
9002: from all iif tun0 lookup 101
```

Table `100` contains the route back toward VPN clients:

```text
10.8.0.0/24 dev tun0
```

Table `101` contains the breakout route toward the currently active WAN.

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

For WAN interfaces without an explicit gateway, Breakout Box can use:

```text
default dev <WAN>
```

---

# IPv4 Forwarding

Breakout Box automatically enables IPv4 forwarding:

```text
/proc/sys/net/ipv4/ip_forward = 1
```

It also enables per-interface forwarding where available and disables strict reverse-path filtering for the relevant Android interfaces.

This is required for traffic arriving through `tun0` to leave through the Android device's Wi-Fi or cellular interface.

---

# Firewall and NAT

Breakout Box uses dedicated iptables chains rather than continuously modifying large Android system chains directly.

## Filter chain

```text
BB_FORWARD
```

## NAT chain

```text
BB_NAT
```

The module hooks them into:

```text
FORWARD
POSTROUTING
```

Typical forwarding behavior:

```text
tun0 -> WAN
    ACCEPT

WAN -> tun0
    ACCEPT RELATED,ESTABLISHED
```

Traffic from the configured VPN subnet is masqueraded through the active WAN:

```text
10.8.0.0/24 -> WAN -> MASQUERADE
```

This allows VPN clients to use the Android device's current Internet connection.

---

# Self-Healing Routing

Android networking can recreate routing tables, firewall rules, or interfaces when:

* Wi-Fi reconnects
* Mobile data reconnects
* Airplane mode changes
* OpenVPN reconnects
* Android `netd` changes firewall state
* The active WAN changes
* Network interfaces are recreated

Breakout Box monitors these conditions automatically.

Default network-state check:

```text
3 seconds
```

Default health check:

```text
15 seconds
```

The health checker verifies:

* IPv4 forwarding is enabled
* VPN interface exists
* VPN IPv4 address exists
* WAN interface exists
* Policy rules exist
* Table `100` contains the VPN route
* Table `101` contains the WAN route
* `BB_FORWARD` exists
* `BB_NAT` exists
* Firewall hooks exist
* NAT masquerading rule exists

If something disappears, Breakout Box attempts to repair it automatically.

---

# Service Supervisor

The routing worker runs under a supervisor.

If repeated repairs fail, the worker exits and the supervisor automatically restarts it.

Default values:

```text
Maximum repair failures: 3
Restart delay:           3 seconds
```

This prevents a temporary Android networking failure from permanently stopping the module.

---

# VPN Reconnection Handling

If `tun0` disappears, Breakout Box waits for the VPN to return.

Stale policy routes are removed so they cannot interfere with normal Android connectivity.

When `tun0` becomes available again, Breakout Box automatically detects it and rebuilds the breakout routing configuration.

No reboot should normally be required after an OpenVPN reconnect.

---

# Wi-Fi and Mobile Data Switching

Breakout Box automatically detects WAN changes.

For example:

```text
wlan0
    ↓
rmnet_data0
    ↓
wlan0
```

When the WAN interface, gateway, or VPN state changes, the routing and firewall configuration is rebuilt automatically.

---

# ADB over TCP

Breakout Box can optionally enable classic ADB-over-TCP.

Default:

```text
Enabled
Port 5555
```

Configuration:

```sh
ENABLE_ADB_TCP=true
ADB_TCP_PORT="5555"
```

The module configures:

```text
persist.adb.tcp.port
service.adb.tcp.port
```

and restarts `adbd` when required.

To disable this feature:

```sh
ENABLE_ADB_TCP=false
```

---

# Persistent Configuration

The module uses a persistent configuration outside the Magisk module directory.

Default configuration shipped with the module:

```text
/data/adb/modules/breakout-box/default-config.conf
```

Persistent device configuration:

```text
/data/adb/breakout-box/config.conf
```

During the first installation, `default-config.conf` is copied to:

```text
/data/adb/breakout-box/config.conf
```

During future module upgrades, an existing `config.conf` is preserved.

This means customized settings survive module updates.

---

# Configuration

Example configuration:

```sh
###############################################################################
# Breakout Box configuration
###############################################################################

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

UPDATE_CHECK_INTERVAL_SECONDS="86400"
UPDATE_INITIAL_DELAY_SECONDS="120"

UPDATE_JSON_URL="https://raw.githubusercontent.com/AyzinA/breakout-box/master/update.json"

UPDATE_REQUIRE_SHA256=true
UPDATE_INSTALL_ONLY_ON_WIFI=false
UPDATE_KEEP_DOWNLOADED_ZIP=false

UPGRADER_MAX_LOG_SIZE=1048576
UPGRADER_MAX_LOG_FILES=3
```

After installation, edit:

```text
/data/adb/breakout-box/config.conf
```

instead of modifying the module's `default-config.conf`.

---

# Logging

Breakout Box writes events to:

```text
/data/adb/breakout-box/breakout-box.log
```

View the latest log entries:

```sh
tail -n 50 /data/adb/breakout-box/breakout-box.log
```

Follow the log live:

```sh
tail -f /data/adb/breakout-box/breakout-box.log
```

The module also writes events to Android logcat using the `breakout-box` tag.

Example:

```sh
logcat -s breakout-box
```

---

# Log Levels

Breakout Box uses the following log levels:

```text
info
status
warn
error
```

Examples:

```text
[info] Breakout Box service started

[status] Rules applied: VPN=tun0 WAN=rmnet_data0 GW=10.132.5.142 TUN=10.8.0.254/24

[warn] VPN unavailable; stale policy routes removed

[warn] Health check failed; repairing routing and firewall state

[error] Rule repair failed (1/3)
```

---

# Log Rotation

Log rotation prevents the persistent log from growing indefinitely.

Default configuration:

```sh
MAX_LOG_SIZE=1048576
MAX_LOG_FILES=3
```

This means:

```text
breakout-box.log
breakout-box.log.1
breakout-box.log.2
breakout-box.log.3
```

With the default 1 MiB limit, total log usage is approximately 4 MiB at maximum.

---

# Status File

The latest important routing state is stored in:

```text
/data/adb/breakout-box/status
```

Check it with:

```sh
cat /data/adb/breakout-box/status
```

Example healthy status:

```text
Rules applied: VPN=tun0 WAN=rmnet_data0 GW=10.132.5.142 TUN=10.8.0.254/24
```

Possible warning:

```text
VPN unavailable; stale policy routes removed
```

Possible error:

```text
Rule repair failed (1/3)
```

---

# Automatic Upgrader

Breakout Box includes:

```text
upgrader.sh
```

The upgrader can check a remote `update.json` file and verify a newer module package before installation.

Automatic updates are disabled by default:

```sh
AUTO_UPDATE=false
```

This is intentional so an update cannot unexpectedly modify a device carrying active network traffic.

---

# Update Configuration

Example:

```sh
AUTO_UPDATE=false

UPDATE_CHECK_INTERVAL_SECONDS="86400"

UPDATE_INITIAL_DELAY_SECONDS="120"

UPDATE_JSON_URL="https://raw.githubusercontent.com/AyzinA/breakout-box/master/update.json"

UPDATE_REQUIRE_SHA256=true

UPDATE_INSTALL_ONLY_ON_WIFI=false

UPDATE_KEEP_DOWNLOADED_ZIP=false
```

---

# update.json

The upgrader supports a shared `update.json` containing multiple Magisk modules.

Each module is stored under its exact `module.prop` ID. Breakout Box reads:

```properties
id=breakout-box
```

and selects only:

```text
modules.breakout-box
```

All other module entries are ignored.

Example multi-module manifest:

```json
{
  "schemaVersion": 2,
  "modules": {
    "breakout-box": {
      "version": "1.0.2",
      "versionCode": 102,
      "zipUrl": "https://github.com/AyzinA/breakout-box/raw/master/releases/download/v1.0.2/breakout-box-v1.0.2.zip",
      "sha256": "SHA256_OF_BREAKOUT_BOX_ZIP",
      "changelog": "https://raw.githubusercontent.com/AyzinA/breakout-box/master/CHANGELOG.md"
    },
    "android-exporter": {
      "version": "1.0.1",
      "versionCode": 101,
      "zipUrl": "https://github.com/AyzinA/android-exporter/releases/download/v1.0.1/android-exporter-v1.0.1.zip",
      "sha256": "SHA256_OF_ANDROID_EXPORTER_ZIP",
      "changelog": "https://raw.githubusercontent.com/AyzinA/android-exporter/master/CHANGELOG.md"
    },
    "auto-unlock": {
      "version": "1.0.1",
      "versionCode": 101,
      "zipUrl": "https://github.com/AyzinA/auto-unlock/releases/download/v1.0.1/auto-unlock-v1.0.1.zip",
      "sha256": "SHA256_OF_AUTO_UNLOCK_ZIP",
      "changelog": "https://raw.githubusercontent.com/AyzinA/auto-unlock/master/CHANGELOG.md"
    }
  }
}
```

The same `upgrader.sh` can therefore be shared by all modules. Each installed module determines its own ID from `module.prop` and only considers the matching manifest object.

The downloaded ZIP is still validated separately. Its root `module.prop` must contain the same module ID and the expected `versionCode`, so a manifest mistake cannot silently install another module.

For compatibility, `upgrader.sh` also accepts the previous single-module format:

```json
{
  "moduleId": "breakout-box",
  "version": "1.0.2",
  "versionCode": 102,
  "zipUrl": "https://example.com/breakout-box-v1.0.2.zip",
  "sha256": "SHA256_OF_THE_RELEASE_ZIP",
  "changelog": "https://example.com/CHANGELOG.md"
}
```

The URLs must be normal HTTPS URLs. Do not use Markdown links or escaped protocols such as `https\://`.

---

# Manual Update Check

Run:

```sh
/data/adb/modules/breakout-box/upgrader.sh check
```

Check upgrader status:

```sh
/data/adb/modules/breakout-box/upgrader.sh status
```

---

# Automatic Update Loop

When:

```sh
AUTO_UPDATE=true
```

Breakout Box starts the upgrader loop automatically.

The upgrader runs separately from the routing worker so update failures do not interrupt the breakout routing service.

The default polling interval is:

```text
86400 seconds
```

which equals one day.

---

# Update Verification

Before installation, the upgrader can verify:

* HTTPS download source
* Manifest metadata
* Newer `versionCode`
* SHA-256 checksum
* ZIP validity
* Internal `module.prop`
* Module ID
* Downloaded module version

The module ID inside the downloaded package must match:

```text
breakout-box
```

---

# Upgrader Logging and Log Rotation

The upgrader writes its own log independently from the routing service:

```text
/data/adb/breakout-box/upgrader.log
```

Rotated files are:

```text
upgrader.log.1
upgrader.log.2
upgrader.log.3
```

Default limits:

```sh
UPGRADER_MAX_LOG_SIZE=1048576
UPGRADER_MAX_LOG_FILES=3
```

View recent upgrader activity:

```sh
tail -n 50 /data/adb/breakout-box/upgrader.log
```

The Android logcat tag is:

```text
breakout-box-upgrader
```

To watch both the routing service and upgrader in one stream:

```sh
adb logcat -s breakout-box:I breakout-box-upgrader:I
```

---

# SHA-256

For release builds, calculate the ZIP checksum before publishing `update.json`.

Linux:

```sh
sha256sum breakout-box-v1.0.2.zip
```

Android with a compatible utility:

```sh
sha256sum breakout-box-v1.0.2.zip
```

Place the resulting checksum in:

```json
"sha256": "..."
```

---

# Module Files

Typical module structure:

```text
breakout-box/
├── module.prop
├── customize.sh
├── service.sh
├── upgrader.sh
├── uninstall.sh
├── default-config.conf
├── README.md
└── CHANGELOG.md
```

Runtime state is stored separately:

```text
/data/adb/breakout-box/
├── config.conf
├── status
├── breakout-box.log
├── breakout-box.log.1
├── breakout-box.log.2
├── breakout-box.log.3
├── service.lock/
├── upgrader.log
├── upgrader.log.1
├── upgrader.status
├── upgrader.pid
└── upgrade/
```

Not every runtime file will necessarily exist at all times.

---

# Installation

Install the module ZIP through Magisk.

Example release:

```text
breakout-box-v1.0.2.zip
```

After installation:

1. Reboot Android.
2. Start or allow OpenVPN to connect.
3. Confirm `tun0` exists.
4. Check Breakout Box status.
5. Verify policy routing and firewall rules.

---

# Basic Verification

Check status:

```sh
cat /data/adb/breakout-box/status
```

Check logs:

```sh
tail -n 50 /data/adb/breakout-box/breakout-box.log
```

Check IPv4 forwarding:

```sh
cat /proc/sys/net/ipv4/ip_forward
```

Expected:

```text
1
```

---

# Check VPN Interface

```sh
ip -4 addr show tun0
```

Example:

```text
31: tun0: <POINTOPOINT,UP,LOWER_UP> mtu 1500
    inet 10.8.0.254/24 scope global tun0
```

---

# Check Current WAN

```sh
ip route get 8.8.8.8
```

Wi-Fi example:

```text
8.8.8.8 via 10.0.1.1 dev wlan0 src 10.0.1.9
```

Mobile example:

```text
8.8.8.8 via 10.132.5.142 dev rmnet_data0 src 10.132.5.141
```

---

# Check Policy Rules

```sh
ip rule
```

Look for priorities:

```text
9000
9001
9002
```

---

# Check Table 100

```sh
ip route show table 100
```

Expected example:

```text
10.8.0.0/24 dev tun0
```

---

# Check Table 101

```sh
ip route show table 101
```

Example:

```text
10.132.5.142 dev rmnet_data0 scope link
default via 10.132.5.142 dev rmnet_data0
```

---

# Check Firewall

```sh
iptables -L BB_FORWARD -n -v --line-numbers
```

Check the parent hook:

```sh
iptables -L FORWARD -n -v --line-numbers
```

There should be a jump to:

```text
BB_FORWARD
```

---

# Check NAT

```sh
iptables -t nat -L BB_NAT -n -v --line-numbers
```

Check the parent hook:

```sh
iptables -t nat -L POSTROUTING -n -v --line-numbers
```

There should be a jump to:

```text
BB_NAT
```

and the module chain should contain a MASQUERADE rule for the VPN network.

---

# Full Diagnostic Command

For troubleshooting:

```sh
echo "=== STATUS ==="
cat /data/adb/breakout-box/status

echo
echo "=== LOG ==="
tail -n 50 /data/adb/breakout-box/breakout-box.log

echo
echo "=== FORWARDING ==="
cat /proc/sys/net/ipv4/ip_forward

echo
echo "=== TUN ==="
ip -4 addr show tun0

echo
echo "=== WAN ==="
ip route get 8.8.8.8

echo
echo "=== RULES ==="
ip rule

echo
echo "=== TABLE 100 ==="
ip route show table 100

echo
echo "=== TABLE 101 ==="
ip route show table 101

echo
echo "=== FORWARD ==="
iptables -L BB_FORWARD -n -v --line-numbers

echo
echo "=== NAT ==="
iptables -t nat -L BB_NAT -n -v --line-numbers
```

---

# Client Route Test

To test routing for a specific VPN client:

```sh
ip route get 1.1.1.1 from 10.8.0.2 iif tun0
```

Replace:

```text
10.8.0.2
```

with the actual VPN client's IP address.

The resulting route should use the Android device's real WAN interface rather than sending the traffic back through `tun0`.

---

# Restart Breakout Box Manually

For testing:

```sh
pkill -f '/data/adb/modules/breakout-box/service.sh' 2>/dev/null

rm -rf /data/adb/breakout-box/service.lock

nohup /data/adb/modules/breakout-box/service.sh >/dev/null 2>&1 &
```

Then check:

```sh
cat /data/adb/breakout-box/status
```

and:

```sh
tail -n 50 /data/adb/breakout-box/breakout-box.log
```

---

# Clear Logs

To clear current and rotated logs:

```sh
rm -f /data/adb/breakout-box/breakout-box.log
rm -f /data/adb/breakout-box/breakout-box.log.*

touch /data/adb/breakout-box/breakout-box.log
chmod 600 /data/adb/breakout-box/breakout-box.log
```

---

# Configuration Permissions

The persistent directory should normally be:

```text
700
```

The persistent configuration should normally be:

```text
600
```

Example:

```sh
chmod 700 /data/adb/breakout-box
chmod 600 /data/adb/breakout-box/config.conf
```

---

# customize.sh Behavior

During installation, Breakout Box creates:

```text
/data/adb/breakout-box
```

If no persistent configuration exists, it copies:

```text
default-config.conf
```

to:

```text
/data/adb/breakout-box/config.conf
```

If the file already exists, it is preserved.

This allows the Magisk module itself to be upgraded without losing device-specific settings.

---

# Uninstallation

Removing the Magisk module removes the installed module directory.

The uninstall script should also clean Breakout Box-owned routing and firewall state where appropriate.

The persistent directory may contain configuration and logs:

```text
/data/adb/breakout-box
```

If complete removal of persistent settings is desired after uninstalling the module, it can be removed manually:

```sh
rm -rf /data/adb/breakout-box
```

Only do this if the saved configuration and logs are no longer required.

---

# Important Notes

Breakout Box is designed for rooted Android devices using Magisk.

The module expects:

```text
/system/bin/sh
ip
iptables
awk
grep
log
```

to be available in the Android/Magisk environment.

OpenVPN must create the configured VPN interface before breakout routing can become active.

The default interface is:

```text
tun0
```

The default VPN network is:

```text
10.8.0.0/24
```

Change these in:

```text
/data/adb/breakout-box/config.conf
```

if your OpenVPN configuration uses different values.

---

# Troubleshooting

## Watch service and upgrader logs together

From a computer connected through ADB:

```sh
adb logcat -s breakout-box:I breakout-box-upgrader:I
```

This shows routing/service events and upgrade checks in chronological order.

## Check current Breakout Box status

```sh
cat /data/adb/breakout-box/status
```

A healthy example is:

```text
Rules applied: VPN=tun0 WAN=rmnet_data0 GW=10.133.186.121 TUN=10.8.0.254/24
```

## Check routing service log

```sh
tail -n 50 /data/adb/breakout-box/breakout-box.log
```

## Check upgrader log

```sh
tail -n 50 /data/adb/breakout-box/upgrader.log
```

## Check upgrader status

```sh
/data/adb/modules/breakout-box/upgrader.sh status
```

## Run an upgrade check manually

```sh
/data/adb/modules/breakout-box/upgrader.sh check
```

If the shared manifest does not contain `breakout-box`, the upgrader logs:

```text
No update manifest entry found for module=breakout-box
```

## Verify the manifest manually

```sh
curl -fsSL "https://raw.githubusercontent.com/AyzinA/breakout-box/master/update.json"
```

Confirm there is an object named exactly:

```json
"breakout-box": {
```

The name must match `id=breakout-box` in `module.prop`.

## No routing / no BB_FORWARD / no BB_NAT

Check:

```sh
cat /proc/sys/net/ipv4/ip_forward
ip -4 addr show tun0
ip route get 8.8.8.8
ip rule
ip route show table 100
ip route show table 101
iptables -L BB_FORWARD -n -v --line-numbers
iptables -t nat -L BB_NAT -n -v --line-numbers
```

Expected IPv4 forwarding:

```text
1
```

If `tun0` is missing, Breakout Box waits for OpenVPN to recreate it.

## `VPN unavailable; stale policy routes removed`

Confirm the VPN interface and address exist:

```sh
ip -4 addr show tun0
```

Then confirm Android has a usable WAN route:

```sh
ip route get 8.8.8.8
```

## Health check keeps repairing rules

Inspect the policy tables and chains:

```sh
ip route show table 100
ip route show table 101
iptables -L BB_FORWARD -n -v
iptables -t nat -L BB_NAT -n -v
```

Android `netd`, another firewall application, or a VPN reconnect may remove rules. Breakout Box will attempt to restore them automatically.

## Upgrader returns HTTP 404

Check the active persistent configuration, because it overrides `default-config.conf`:

```sh
grep '^UPDATE_JSON_URL=' /data/adb/breakout-box/config.conf
```

Then test that exact URL with:

```sh
curl -fsSL "$(sed -n 's/^UPDATE_JSON_URL="\(.*\)"/\1/p' /data/adb/breakout-box/config.conf)"
```

## SHA-256 mismatch

Recalculate the published module ZIP checksum:

```sh
sha256sum breakout-box-v1.0.2.zip
```

Then update the matching `breakout-box` entry in `update.json`.

## Stale upgrader PID

Check:

```sh
cat /data/adb/breakout-box/upgrader.pid
```

The `status` command reports whether the PID belongs to a running upgrader loop. A stale PID is removed automatically when the service starts a new loop.

---

# v1.0.2 Highlights

Version 1.0.2 adds major reliability improvements over the initial release.

## Added

* Persistent configuration
* Dedicated `BB_FORWARD` firewall chain
* Dedicated `BB_NAT` NAT chain
* Policy-routing health checks
* Automatic repair
* Worker supervisor
* Log file support
* Log levels
* Log rotation
* Status reporting
* Universal upgrader
* SHA-256 update verification
* Optional Wi-Fi-only update checks

## Improved

* Android/Toybox compatibility
* Wi-Fi gateway routing
* Mobile-data routing
* VPN reconnect handling
* WAN switching
* ADB-over-TCP handling
* Android policy-rule compatibility
* Boot handling
* Service recovery

## Changed

Network detection interval:

```text
10 seconds -> 3 seconds
```

Policy priorities:

```text
old:
9999
10000
10001

new:
9000
9001
9002
```

The new priorities avoid collision with Android networking rules commonly beginning at priority `10000`.

---

# Version Information

```text
Module:       Breakout Box
Version:      1.0.2
Version Code: 102
Module ID:    breakout-box
```

`module.prop`:

```properties
id=breakout-box
name=Breakout Box
version=1.0.2
versionCode=102
author=NONAME
description=Adds breakout-box routing and NAT rules at boot
```
