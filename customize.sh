#!/system/bin/sh

ui_print "***************************************"
ui_print "******       Breakout Box        ******"
ui_print "***************************************"
ui_print "Installing self-healing routing service"
ui_print "Installing updater.sh and default-config.conf"

set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/updater.sh" 0 0 0755
set_perm "$MODPATH/default-config.conf" 0 0 0644
set_perm "$MODPATH/customize.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755

# v1.0.3 ships with automatic update checks disabled.
# If a persistent config from an earlier test build exists, preserve all other
# user settings but force AUTO_UPDATE=false for this install.
STATE_DIR="/data/adb/breakout-box"
PERSISTENT_CONFIG="$STATE_DIR/config.conf"
mkdir -p "$STATE_DIR" 2>/dev/null
if [ -f "$PERSISTENT_CONFIG" ]; then
  if grep -q '^AUTO_UPDATE=' "$PERSISTENT_CONFIG" 2>/dev/null; then
    sed -i 's/^AUTO_UPDATE=.*/AUTO_UPDATE=false/' "$PERSISTENT_CONFIG"
  else
    echo 'AUTO_UPDATE=false' >> "$PERSISTENT_CONFIG"
  fi

  # Migrate only the old v1.0.2 default priorities that collided with Android
  # netd. Custom user-selected priorities are left untouched.
  sed -i 's/^VPN_TO_CLIENT_PRIORITY="9999"/VPN_TO_CLIENT_PRIORITY="9000"/' "$PERSISTENT_CONFIG" 2>/dev/null
  sed -i 's/^VPN_FROM_CLIENT_PRIORITY="10000"/VPN_FROM_CLIENT_PRIORITY="9001"/' "$PERSISTENT_CONFIG" 2>/dev/null
  sed -i 's/^VPN_IIF_PRIORITY="10001"/VPN_IIF_PRIORITY="9002"/' "$PERSISTENT_CONFIG" 2>/dev/null

  chmod 0600 "$PERSISTENT_CONFIG" 2>/dev/null
fi
