# Changelog

## v1.0.2

### Added

- Persistent configuration through `default-config.conf` and `/data/adb/breakout-box/config.conf`.
- `customize.sh` to create persistent configuration on first install and preserve it during upgrades.
- Self-healing routing and firewall health checks.
- Supervisor/worker architecture with automatic worker restart after repeated repair failures.
- Dedicated `BB_FORWARD` and `BB_NAT` iptables chains.
- Persistent service logging to `/data/adb/breakout-box/breakout-box.log`.
- Size-based service log rotation.
- Runtime status file at `/data/adb/breakout-box/status`.
- Single-instance service locking.
- Universal `upgrader.sh` with `check`, `loop`, and `status` commands.
- HTTPS-only manifest and module ZIP downloads.
- Multi-module `update.json` support with selection by the installed module ID.
- Backward-compatible support for the legacy single-module manifest format.
- Optional SHA-256 verification of downloaded module ZIPs.
- Validation of the downloaded ZIP's module ID and `versionCode` before installation.
- Configurable automatic upgrade interval and initial delay.
- Optional Wi-Fi-only upgrade checks.
- Independent upgrader PID, status, and rotating log files.
- Android logcat tag `breakout-box-upgrader`.
- BusyBox `awk` preference in the upgrader for better Android/vendor-ROM compatibility.
- `uninstall.sh` cleanup support.
- Configurable VPN interface and VPN subnet, allowing the routing engine to be used with interfaces such as OpenVPN `tun0` or WireGuard `wg0`.

### Changed

- Generalized the routing logic from OpenVPN-specific interface assumptions to a configurable VPN interface/subnet model.
- WAN detection now excludes the configured VPN interface instead of relying on a `tun*` interface-name assumption.
- Renamed tunnel-specific runtime variables to generic VPN names such as `CURRENT_VPN_INDEX`, `CURRENT_VPN_ADDR`, `LAST_VPN_INDEX`, and `LAST_VPN_ADDR`.
- Routing status output now reports `VPN_ADDR=` instead of `TUN=`.
- Reduced the default network-state polling interval from 10 seconds to 3 seconds.
- Added a separate full routing/firewall health-check interval of 15 seconds.
- Changed the default policy-routing priorities from `9999/10000/10001` to `9000/9001/9002`.
- Made routing tables and priorities configurable.
- Improved custom WAN-table gateway handling by adding explicit gateway reachability before installing the default route.
- Added an `onlink` fallback for gateway-based WAN routes.
- Improved support for cellular/direct WAN interfaces that do not expose an explicit gateway.
- Reworked firewall management around module-owned chains instead of repeatedly manipulating shared rules directly.
- Made ADB-over-TCP enablement and port configurable.
- Avoids restarting `adbd` when the configured ADB TCP state is already correct.
- Replaced the fixed startup delay with Android boot-completed detection.
- Added an explicit Android/Magisk `PATH` for more reliable command resolution.
- Renamed the update component from `updater.sh` to `upgrader.sh` and renamed its runtime files accordingly.
- Made the upgrader hosting-neutral: `UPDATE_JSON_URL` and `zipUrl` can point to any accessible HTTPS server, not only GitHub.
- Updated the module description to:

  ```properties
  description=Self-healing VPN breakout routing/NAT with secure HTTPS upgrader
  ```

### Fixed / Improved

- Improved recovery when Android `netd` or another component removes routing or firewall state without changing interfaces.
- Improved recovery from VPN interface recreation and VPN address changes.
- Improved recovery from Wi-Fi/mobile-data WAN changes and gateway changes.
- Prevented the configured VPN interface from being selected as the breakout WAN.
- Improved custom routing-table gateway reachability on Android.
- Removed the v1.0.1 global `conntrack -F` behavior that could interrupt unrelated Android connections.
- Reduced dependence on hardcoded lists of possible Android WAN interface names.
- Improved compatibility with Android/Toybox and vendor-ROM command implementations.

### Security / Upgrade Safety

- Automatic upgrades remain disabled by default with `AUTO_UPDATE=false`.
- Upgrade manifest and ZIP URLs must use HTTPS.
- SHA-256 verification can be required with `UPDATE_REQUIRE_SHA256=true`.
- Downloaded ZIPs are checked for the expected module ID and `versionCode` before Magisk installation.
- Partial downloads use temporary `.part` files.
- Upgrade locking prevents overlapping upgrade operations.


## v1.0.1

- Initial Breakout Box release.
- OpenVPN `tun0` breakout routing.
- Wi-Fi/mobile WAN detection.
- Policy routing using tables `100` and `101`.
- NAT/MASQUERADE for VPN clients.
- Automatic handling of OpenVPN reconnects and WAN changes.
- ADB-over-TCP support on port `5555`.