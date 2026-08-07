# Changelog

## v1.0.2

### Added
- Persistent `default-config.conf` / `config.conf` system.
- Self-healing routing and firewall health checks.
- Service supervisor with automatic worker restart.
- Dedicated `BB_FORWARD` and `BB_NAT` iptables chains.
- Log files with automatic size-based rotation.
- Universal secure `updater.sh`.
- SHA-256 and module/version validation for updates.
- Optional Wi-Fi-only update checks.
- Runtime status reporting.

### Changed
- Reduced network check interval from 10 seconds to 3 seconds.
- Changed policy-routing priorities to `9000`, `9001`, and `9002` for better Android compatibility.
- Improved Wi-Fi gateway handling for custom routing table `101`.
- Improved Android/Toybox command compatibility.
- Improved ADB-over-TCP handling and made it configurable.
- Replaced fixed boot delay with Android boot-state detection.

### Fixed
- Fixed routing conflicts with Android system policy rules.
- Fixed custom WAN table gateway reachability.
- Fixed service startup failures caused by command detection.
- Removed global conntrack flushing that could affect unrelated Android connections.

### Security
- Automatic updates are disabled by default:
  ```bash
  AUTO_UPDATE=false
  ```
- Update downloads require HTTPS.
- Update ZIPs can be verified with SHA-256 before installation.

---

## v1.0.1

- Initial Breakout Box release.
- OpenVPN `tun0` breakout routing.
- Wi-Fi/mobile WAN detection.
- Policy routing using tables `100` and `101`.
- NAT/MASQUERADE for VPN clients.
- Automatic handling of OpenVPN reconnects and WAN changes.
- ADB-over-TCP support on port `5555`.