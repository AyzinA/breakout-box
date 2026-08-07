#!/system/bin/sh

ui_print "***************************************"
ui_print "******       Breakout Box        ******"
ui_print "***************************************"

STATE_DIR="/data/adb/breakout-box"
DEFAULT_CONFIG="$MODPATH/default-config.conf"
CONFIG_FILE="$STATE_DIR/config.conf"
mkdir -p "$STATE_DIR" 2>/dev/null
chmod 700 "$STATE_DIR"
if [ ! -f "$CONFIG_FILE" ]; then
    cp -f "$DEFAULT_CONFIG" "$CONFIG_FILE"
    ui_print "- Created persistent configuration: $CONFIG_FILE"
else
    ui_print "- Preserved existing configuration: $CONFIG_FILE"
fi
chmod 600 "$CONFIG_FILE"
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/updater.sh" 0 0 0755
set_perm "$MODPATH/customize.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
