#!/system/bin/sh

ui_print "***************************************"
ui_print "*                                     *"
ui_print "*             Breakout Box            *"
ui_print "*                                     *"
ui_print "***************************************"

STATE_DIR="/data/adb/breakout-box"
DEFAULT_CONFIG="$MODPATH/default-config.conf"
CONFIG_FILE="$STATE_DIR/config.conf"
mkdir -p "$STATE_DIR" 2>/dev/null
chmod 700 "$STATE_DIR" 2>/dev/null
if [ ! -f "$CONFIG_FILE" ]; then
  if [ -f "$DEFAULT_CONFIG" ]; then
    cp -f "$DEFAULT_CONFIG" "$CONFIG_FILE"
    ui_print "- Created persistent configuration:"
    ui_print "  $CONFIG_FILE"
  else
    ui_print "! default-config.conf not found"
  fi
else
  ui_print "- Preserved existing configuration:"
  ui_print "  $CONFIG_FILE"
fi
[ -f "$CONFIG_FILE" ] && chmod 600 "$CONFIG_FILE" 2>/dev/null

set_perm_recursive "$MODPATH" 0 0 0755 0644

set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/upgrader.sh" 0 0 0755
set_perm "$MODPATH/customize.sh" 0 0 0755

[ -f "$MODPATH/uninstall.sh" ] &&
  set_perm "$MODPATH/uninstall.sh" 0 0 0755

ui_print "- Installation complete"