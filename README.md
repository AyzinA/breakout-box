# Breakout Box v1.0.2

Files:

- `service.sh` - self-healing OpenVPN breakout routing/NAT service.
- `update.sh` - GitHub updater (`check`, `download`, `install`, `daemon`, `status`).
- `default-config.conf` - defaults copied once to `/data/adb/breakout-box/config.conf`.
- `module.prop` - Magisk module metadata and standard `updateJson` URL.

## First setup

Replace `YOUR_GITHUB_USERNAME` in:

- `module.prop`
- `default-config.conf`
- your GitHub `update.json`

The updater creates `/data/adb/breakout-box/config.conf` on first boot. That persistent config is not overwritten by future module updates.

Default behavior checks once per day but does not silently install. To enable verified automatic installation:

```sh
su
sed -i 's/^AUTO_INSTALL=.*/AUTO_INSTALL=true/' /data/adb/breakout-box/config.conf
```

No automatic reboot occurs unless `AUTO_REBOOT=true` is explicitly configured.

## Manual updater commands

```sh
su -c /data/adb/modules/breakout-box/update.sh status
su -c /data/adb/modules/breakout-box/update.sh check
su -c /data/adb/modules/breakout-box/update.sh download
su -c /data/adb/modules/breakout-box/update.sh install
```

Updater log:

```text
/data/adb/breakout-box/update.log
```


## v1.0.2 fixed Android compatibility notes

- `AUTO_UPDATE=false` by default.
- Uses Android/Toybox command lookup without standalone-file `-x` checks.
- Breakout policy rules default to priorities 9000/9001/9002 to avoid Android netd rules starting at 10000.
- Adds an explicit WAN-gateway host route to custom table 101 before its default route.
- The updater daemon is not launched while `AUTO_UPDATE=false`.
