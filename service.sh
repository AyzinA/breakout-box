#!/system/bin/sh

# Android/Magisk service PATH. Keep system Toybox utilities reachable even when
# Magisk starts service.sh with a reduced environment.
export PATH="/data/adb/magisk:/data/adb/magisk/bin:/system/bin:/system/xbin:/vendor/bin:/product/bin:/apex/com.android.runtime/bin:$PATH"

###############################################################################
# Breakout Box Magisk service
#
# Purpose:
#   Forward traffic arriving from an OpenVPN tunnel through the Android device's
#   current Wi-Fi or mobile-data connection.
#
# Design:
#   - A supervisor loop restarts the worker if it exits unexpectedly.
#   - The worker watches VPN/WAN state and reapplies rules when it changes.
#   - A periodic health check repairs rules that Android/netd or another app
#     removes without changing the interface state.
#   - Dedicated iptables chains make updates faster and avoid scanning many
#     possible Android WAN interface names.
###############################################################################

# Magisk module directory.
MODDIR="${0%/*}"

# Shared Breakout Box configuration.
STATE_DIR="/data/adb/breakout-box"
DEFAULT_CONFIG="$MODDIR/default-config.conf"
CONFIG="$STATE_DIR/config.conf"

mkdir -p "$STATE_DIR" 2>/dev/null

# Create the persistent configuration only once. Future module upgrades keep it.
if [ ! -f "$CONFIG" ] && [ -f "$DEFAULT_CONFIG" ]; then
  cp "$DEFAULT_CONFIG" "$CONFIG" 2>/dev/null
  chmod 0600 "$CONFIG" 2>/dev/null
fi

# Load persistent device settings when available.
[ -f "$CONFIG" ] && . "$CONFIG"

# OpenVPN interface and subnet.
VPN="${VPN_INTERFACE:-tun0}"
VPN_NET="${VPN_NETWORK:-10.8.0.0/24}"

# Policy-routing tables and rule priorities.
VPN_TABLE="${VPN_TABLE:-100}"
WAN_TABLE="${WAN_TABLE:-101}"
VPN_TO_CLIENT_PRIORITY="${VPN_TO_CLIENT_PRIORITY:-9000}"
VPN_FROM_CLIENT_PRIORITY="${VPN_FROM_CLIENT_PRIORITY:-9001}"
VPN_IIF_PRIORITY="${VPN_IIF_PRIORITY:-9002}"

# Monitoring intervals, in seconds.
CHECK_INTERVAL="${CHECK_INTERVAL_SECONDS:-3}"
HEALTH_INTERVAL="${HEALTH_CHECK_INTERVAL_SECONDS:-15}"
RESTART_DELAY="${SERVICE_RESTART_DELAY_SECONDS:-3}"
MAX_REPAIR_FAILURES="${MAX_REPAIR_FAILURES:-3}"

# Classic ADB-over-TCP configuration.
ADB_PORT="${ADB_TCP_PORT:-5555}"
ENABLE_ADB_TCP="${ENABLE_ADB_TCP:-true}"
case "$ENABLE_ADB_TCP" in
  true|TRUE|yes|YES|1) ENABLE_ADB_TCP="1" ;;
  *) ENABLE_ADB_TCP="0" ;;
esac

# Dedicated firewall chains owned by this script.
FILTER_CHAIN="${FILTER_CHAIN:-BB_FORWARD}"
NAT_CHAIN="${NAT_CHAIN:-BB_NAT}"

# Logging and runtime state.
LOG_TAG="${LOG_TAG:-breakout-box}"
LOG_LEVEL="${LOG_LEVEL:-info}"
MAX_LOG_SIZE="${MAX_LOG_SIZE:-1048576}"
MAX_LOG_FILES="${MAX_LOG_FILES:-3}"
LOG_FILE="$STATE_DIR/breakout-box.log"
STATUS_FILE="$STATE_DIR/status"
LOCK_DIR="$STATE_DIR/service.lock"

# Android/Toybox commands. Use command names directly rather than requiring the
# result of `command -v` to pass -x; some Android applet layouts are executable
# through the shell but do not behave like normal standalone files.
IP_BIN="ip"
IPTABLES_BIN="iptables"
AWK_BIN="awk"
GREP_BIN="grep"
LOG_BIN=""
command -v log >/dev/null 2>&1 && LOG_BIN="log"

# Last successfully applied network state.
LAST_WAN=""
LAST_GW=""
LAST_TUN_INDEX=""
LAST_TUN_ADDR=""
LAST_HEALTH_TIME="0"
REPAIR_FAILURES="0"

# Current state populated by detect_network_state().
CURRENT_WAN=""
CURRENT_GW=""
CURRENT_TUN_INDEX=""
CURRENT_TUN_ADDR=""

###############################################################################
# Utility functions
###############################################################################

rotate_logs() {
  [ -f "$LOG_FILE" ] || return 0
  SIZE="$(wc -c < "$LOG_FILE" 2>/dev/null || echo 0)"
  case "$SIZE" in ''|*[!0-9]*) SIZE=0 ;; esac
  case "$MAX_LOG_SIZE" in ''|*[!0-9]*) MAX_LOG_SIZE=1048576 ;; esac
  case "$MAX_LOG_FILES" in ''|*[!0-9]*) MAX_LOG_FILES=3 ;; esac
  [ "$SIZE" -gt "$MAX_LOG_SIZE" ] || return 0

  [ -f "${LOG_FILE}.${MAX_LOG_FILES}" ] && rm -f "${LOG_FILE}.${MAX_LOG_FILES}"
  I=$((MAX_LOG_FILES - 1))
  while [ "$I" -ge 1 ]; do
    [ -f "${LOG_FILE}.${I}" ] && mv -f "${LOG_FILE}.${I}" "${LOG_FILE}.$((I + 1))"
    I=$((I - 1))
  done
  mv -f "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null
  : > "$LOG_FILE"
  chmod 600 "$LOG_FILE" 2>/dev/null
}

log() {
  LEVEL="$1"; shift
  [ "$LOG_LEVEL" = "off" ] && return 0
  rotate_logs
  MESSAGE="$*"
  printf '[%s] [%s] %s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$LEVEL" "$$" "$MESSAGE" >> "$LOG_FILE" 2>/dev/null
  [ -n "$LOG_BIN" ] && "$LOG_BIN" -t "$LOG_TAG" "[$LEVEL] $MESSAGE" 2>/dev/null
}

log_msg() {
  MESSAGE="$*"
  log info "$MESSAGE"
  echo "$MESSAGE" > "$STATUS_FILE" 2>/dev/null
}

bool_true() {
  case "$1" in 1|true|TRUE|yes|YES|on|ON) return 0 ;; *) return 1 ;; esac
}

start_update_loop() {
  bool_true "$AUTO_UPDATE" || return 0
  UPDATER="$MODDIR/updater.sh"
  [ -x "$UPDATER" ] || { log warn "updater.sh is missing or not executable"; return 1; }

  MODULE_ID="$(sed -n 's/^id=//p' "$MODDIR/module.prop" 2>/dev/null | head -n 1 | tr -d '\r')"
  UPDATER_STATE_DIR="${MODULE_STATE_DIR:-/data/adb/$MODULE_ID}"
  UPDATER_PID_FILE="$UPDATER_STATE_DIR/updater.pid"

  if [ -r "$UPDATER_PID_FILE" ]; then
    UPDATE_PID="$(cat "$UPDATER_PID_FILE" 2>/dev/null)"
    case "$UPDATE_PID" in ''|*[!0-9]*) UPDATE_PID="" ;; esac
    [ -n "$UPDATE_PID" ] && kill -0 "$UPDATE_PID" 2>/dev/null && { log info "Automatic update loop already running (PID $UPDATE_PID)."; return 0; }
    rm -f "$UPDATER_PID_FILE"
  fi

  MODDIR="$MODDIR" nohup "$UPDATER" loop >/dev/null 2>&1 &
  log info "Automatic update loop started."
}

now_seconds() {
  date +%s 2>/dev/null || echo 0
}

command_requirements_ok() {
  command -v "$IP_BIN" >/dev/null 2>&1 || return 1
  command -v "$IPTABLES_BIN" >/dev/null 2>&1 || return 1
  command -v "$AWK_BIN" >/dev/null 2>&1 || return 1
  command -v "$GREP_BIN" >/dev/null 2>&1 || return 1
  return 0
}

wait_for_android_boot() {
  WAITED=0
  while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ]; do
    sleep 2
    WAITED=$((WAITED + 2))
    [ "$WAITED" -ge 120 ] && break
  done
}

acquire_lock() {
  mkdir -p "$STATE_DIR" 2>/dev/null

  if mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "$$" > "$LOCK_DIR/pid" 2>/dev/null
    return 0
  fi

  OLD_PID="$(cat "$LOCK_DIR/pid" 2>/dev/null)"
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    log_msg "Another service.sh instance is already running with PID $OLD_PID"
    return 1
  fi

  rm -rf "$LOCK_DIR" 2>/dev/null
  mkdir "$LOCK_DIR" 2>/dev/null || return 1
  echo "$$" > "$LOCK_DIR/pid" 2>/dev/null
  return 0
}

release_lock() {
  rm -rf "$LOCK_DIR" 2>/dev/null
}

###############################################################################
# Network-state detection
###############################################################################

detect_network_state() {
  CURRENT_WAN=""
  CURRENT_GW=""
  CURRENT_TUN_INDEX=""
  CURRENT_TUN_ADDR=""

  [ -d "/sys/class/net/$VPN" ] || return 1

  CURRENT_TUN_INDEX="$($IP_BIN -o link show "$VPN" 2>/dev/null | "$AWK_BIN" -F': ' 'NR==1 {print $1}')"
  CURRENT_TUN_ADDR="$($IP_BIN -4 -o addr show dev "$VPN" 2>/dev/null | "$AWK_BIN" 'NR==1 {print $4}')"

  [ -n "$CURRENT_TUN_INDEX" ] || return 1
  [ -n "$CURRENT_TUN_ADDR" ] || return 1

  ROUTE_STATE="$($IP_BIN route get 8.8.8.8 2>/dev/null | "$AWK_BIN" '
    NR==1 {
      wan="-"; gw="-"
      for (i=1; i<=NF; i++) {
        if ($i=="dev" && (i+1)<=NF && $(i+1) !~ /^tun/) wan=$(i+1)
        if ($i=="via" && (i+1)<=NF) gw=$(i+1)
      }
      print wan, gw
    }')"

  set -- $ROUTE_STATE
  [ "$1" != "-" ] && CURRENT_WAN="$1"
  [ "$2" != "-" ] && CURRENT_GW="$2"

  # Fallback for Android builds that omit the Wi-Fi gateway in route-get output.
  if [ -z "$CURRENT_GW" ] && [ "$CURRENT_WAN" = "wlan0" ]; then
    WLAN_CIDR="$($IP_BIN -4 -o addr show dev wlan0 2>/dev/null | "$AWK_BIN" 'NR==1 {print $4}')"
    WLAN_IP="${WLAN_CIDR%/*}"
    if [ -n "$WLAN_IP" ]; then
      CURRENT_GW="$(echo "$WLAN_IP" | "$AWK_BIN" -F. 'NF==4 {print $1"."$2"."$3".1"}')"
    fi
  fi

  [ -n "$CURRENT_WAN" ] || return 1
  return 0
}

network_state_changed() {
  [ "$CURRENT_WAN" != "$LAST_WAN" ] && return 0
  [ "$CURRENT_GW" != "$LAST_GW" ] && return 0
  [ "$CURRENT_TUN_INDEX" != "$LAST_TUN_INDEX" ] && return 0
  [ "$CURRENT_TUN_ADDR" != "$LAST_TUN_ADDR" ] && return 0
  return 1
}

save_network_state() {
  LAST_WAN="$CURRENT_WAN"
  LAST_GW="$CURRENT_GW"
  LAST_TUN_INDEX="$CURRENT_TUN_INDEX"
  LAST_TUN_ADDR="$CURRENT_TUN_ADDR"
}

reset_network_state() {
  LAST_WAN=""
  LAST_GW=""
  LAST_TUN_INDEX=""
  LAST_TUN_ADDR=""
  LAST_HEALTH_TIME="0"
}

###############################################################################
# Kernel and ADB configuration
###############################################################################

enable_forwarding() {
  echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null || return 1

  for SYSCTL_DIR in /proc/sys/net/ipv4/conf/*; do
    [ -d "$SYSCTL_DIR" ] || continue
    echo 1 > "$SYSCTL_DIR/forwarding" 2>/dev/null
    echo 0 > "$SYSCTL_DIR/rp_filter" 2>/dev/null
  done

  return 0
}

enable_adb_tcp() {
  [ "$ENABLE_ADB_TCP" = "1" ] || return 0

  CURRENT_ADB_PORT="$(getprop service.adb.tcp.port 2>/dev/null)"
  PERSISTENT_ADB_PORT="$(getprop persist.adb.tcp.port 2>/dev/null)"

  setprop persist.adb.tcp.port "$ADB_PORT"
  setprop service.adb.tcp.port "$ADB_PORT"

  if [ "$CURRENT_ADB_PORT" != "$ADB_PORT" ] || [ "$PERSISTENT_ADB_PORT" != "$ADB_PORT" ]; then
    setprop ctl.restart adbd 2>/dev/null || {
      stop adbd 2>/dev/null
      sleep 1
      start adbd 2>/dev/null
    }
    log_msg "ADB TCP enabled on port $ADB_PORT"
  fi
}

###############################################################################
# Policy routing
###############################################################################

delete_rule_all() {
  while "$IP_BIN" rule del "$@" 2>/dev/null; do :; done
}

clean_policy_rules() {
  delete_rule_all to "$VPN_NET" lookup "$VPN_TABLE" priority "$VPN_TO_CLIENT_PRIORITY"
  delete_rule_all from "$VPN_NET" lookup "$WAN_TABLE" priority "$VPN_FROM_CLIENT_PRIORITY"
  delete_rule_all iif "$VPN" lookup "$WAN_TABLE" priority "$VPN_IIF_PRIORITY"

  "$IP_BIN" route flush table "$VPN_TABLE" 2>/dev/null
  "$IP_BIN" route flush table "$WAN_TABLE" 2>/dev/null
  "$IP_BIN" route flush cache 2>/dev/null
}

apply_policy_rules() {
  WAN="$1"
  GW="$2"

  clean_policy_rules

  "$IP_BIN" rule add to "$VPN_NET" lookup "$VPN_TABLE" priority "$VPN_TO_CLIENT_PRIORITY" 2>/dev/null || return 1
  "$IP_BIN" route replace "$VPN_NET" dev "$VPN" table "$VPN_TABLE" 2>/dev/null || return 1

  "$IP_BIN" rule add from "$VPN_NET" lookup "$WAN_TABLE" priority "$VPN_FROM_CLIENT_PRIORITY" 2>/dev/null || return 1
  "$IP_BIN" rule add iif "$VPN" lookup "$WAN_TABLE" priority "$VPN_IIF_PRIORITY" 2>/dev/null || return 1

  if [ -n "$GW" ]; then
    # Android keeps Wi-Fi/mobile routes in per-network routing tables. A fresh
    # custom table may therefore not know that the gateway is directly
    # reachable. Add an explicit host route first, then install the default.
    "$IP_BIN" route replace "$GW/32" dev "$WAN" scope link table "$WAN_TABLE" 2>/dev/null || return 1
    "$IP_BIN" route replace default via "$GW" dev "$WAN" table "$WAN_TABLE" 2>/dev/null || \
      "$IP_BIN" route replace default via "$GW" dev "$WAN" onlink table "$WAN_TABLE" 2>/dev/null || return 1
  else
    # Cellular interfaces commonly use a point-to-point/direct default without
    # an explicit gateway.
    "$IP_BIN" route replace default dev "$WAN" table "$WAN_TABLE" 2>/dev/null || return 1
  fi

  "$IP_BIN" route flush cache 2>/dev/null
  return 0
}

###############################################################################
# Firewall and NAT
###############################################################################

ensure_iptables_chain() {
  TABLE="$1"
  CHAIN="$2"

  "$IPTABLES_BIN" -t "$TABLE" -N "$CHAIN" 2>/dev/null || true
  "$IPTABLES_BIN" -t "$TABLE" -F "$CHAIN" 2>/dev/null || return 1
  return 0
}

ensure_iptables_hook() {
  TABLE="$1"
  PARENT_CHAIN="$2"
  CHILD_CHAIN="$3"

  if ! "$IPTABLES_BIN" -t "$TABLE" -C "$PARENT_CHAIN" -j "$CHILD_CHAIN" 2>/dev/null; then
    "$IPTABLES_BIN" -t "$TABLE" -I "$PARENT_CHAIN" 1 -j "$CHILD_CHAIN" 2>/dev/null || return 1
  fi
  return 0
}

apply_iptables_rules() {
  WAN="$1"

  ensure_iptables_chain filter "$FILTER_CHAIN" || return 1
  ensure_iptables_chain nat "$NAT_CHAIN" || return 1
  ensure_iptables_hook filter FORWARD "$FILTER_CHAIN" || return 1
  ensure_iptables_hook nat POSTROUTING "$NAT_CHAIN" || return 1

  "$IPTABLES_BIN" -A "$FILTER_CHAIN" -i "$VPN" -o "$WAN" -s "$VPN_NET" -j ACCEPT 2>/dev/null || return 1
  "$IPTABLES_BIN" -A "$FILTER_CHAIN" -i "$WAN" -o "$VPN" -d "$VPN_NET" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || return 1
  "$IPTABLES_BIN" -t nat -A "$NAT_CHAIN" -s "$VPN_NET" -o "$WAN" -j MASQUERADE 2>/dev/null || return 1

  return 0
}

###############################################################################
# Rule application and validation
###############################################################################

apply_rules() {
  WAN="$1"
  GW="$2"

  [ -n "$WAN" ] || return 1
  [ -d "/sys/class/net/$VPN" ] || return 1

  enable_forwarding || return 1
  apply_policy_rules "$WAN" "$GW" || return 1
  apply_iptables_rules "$WAN" || return 1

  log_msg "Rules applied: VPN=$VPN WAN=$WAN GW=${GW:-direct} TUN=$CURRENT_TUN_ADDR"
  return 0
}

policy_rules_healthy() {
  "$IP_BIN" rule show 2>/dev/null | "$GREP_BIN" -q "^${VPN_TO_CLIENT_PRIORITY}:.*to ${VPN_NET}.*lookup ${VPN_TABLE}" || return 1
  "$IP_BIN" rule show 2>/dev/null | "$GREP_BIN" -q "^${VPN_FROM_CLIENT_PRIORITY}:.*from ${VPN_NET}.*lookup ${WAN_TABLE}" || return 1
  "$IP_BIN" rule show 2>/dev/null | "$GREP_BIN" -q "^${VPN_IIF_PRIORITY}:.*iif ${VPN}.*lookup ${WAN_TABLE}" || return 1

  "$IP_BIN" route show table "$VPN_TABLE" 2>/dev/null | "$GREP_BIN" -q "${VPN_NET}.*dev ${VPN}" || return 1
  "$IP_BIN" route show table "$WAN_TABLE" 2>/dev/null | "$GREP_BIN" -q "^default .*dev ${CURRENT_WAN}" || return 1
  return 0
}

iptables_rules_healthy() {
  "$IPTABLES_BIN" -C FORWARD -j "$FILTER_CHAIN" 2>/dev/null || return 1
  "$IPTABLES_BIN" -C "$FILTER_CHAIN" -i "$VPN" -o "$CURRENT_WAN" -s "$VPN_NET" -j ACCEPT 2>/dev/null || return 1
  "$IPTABLES_BIN" -C "$FILTER_CHAIN" -i "$CURRENT_WAN" -o "$VPN" -d "$VPN_NET" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || return 1
  "$IPTABLES_BIN" -t nat -C POSTROUTING -j "$NAT_CHAIN" 2>/dev/null || return 1
  "$IPTABLES_BIN" -t nat -C "$NAT_CHAIN" -s "$VPN_NET" -o "$CURRENT_WAN" -j MASQUERADE 2>/dev/null || return 1
  return 0
}

health_check() {
  [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" = "1" ] || return 1
  [ -d "/sys/class/net/$VPN" ] || return 1
  [ -n "$CURRENT_TUN_ADDR" ] || return 1
  [ -d "/sys/class/net/$CURRENT_WAN" ] || return 1

  policy_rules_healthy || return 1
  iptables_rules_healthy || return 1
  return 0
}

health_check_due() {
  NOW="$(now_seconds)"
  [ "$NOW" -eq 0 ] && return 0

  ELAPSED=$((NOW - LAST_HEALTH_TIME))
  if [ "$ELAPSED" -ge "$HEALTH_INTERVAL" ]; then
    LAST_HEALTH_TIME="$NOW"
    return 0
  fi
  return 1
}

repair_or_restart() {
  if apply_rules "$CURRENT_WAN" "$CURRENT_GW"; then
    REPAIR_FAILURES="0"
    save_network_state
    return 0
  fi

  REPAIR_FAILURES=$((REPAIR_FAILURES + 1))
  log_msg "Rule repair failed ($REPAIR_FAILURES/$MAX_REPAIR_FAILURES)"

  [ "$REPAIR_FAILURES" -lt "$MAX_REPAIR_FAILURES" ] && return 0
  return 1
}

###############################################################################
# Worker and supervisor
###############################################################################

service_worker() {
  reset_network_state
  REPAIR_FAILURES="0"

  while true; do
    if ! detect_network_state; then
      # The VPN may simply be disconnected. Remove stale policy routes so they
      # cannot affect the Android device, then wait for the tunnel to return.
      if [ -n "$LAST_TUN_INDEX" ] || [ -n "$LAST_WAN" ]; then
        clean_policy_rules
        reset_network_state
        log_msg "VPN unavailable; stale policy routes removed"
      fi
      sleep "$CHECK_INTERVAL"
      continue
    fi

    if network_state_changed; then
      repair_or_restart || return 1
    elif health_check_due && ! health_check; then
      log_msg "Health check failed; repairing routing and firewall state"
      repair_or_restart || return 1
    fi

    sleep "$CHECK_INTERVAL"
  done
}

supervisor_loop() {
  while true; do
    service_worker
    EXIT_CODE="$?"
    log_msg "Worker exited with code $EXIT_CODE; restarting in ${RESTART_DELAY}s"
    clean_policy_rules
    reset_network_state
    sleep "$RESTART_DELAY"
  done
}

###############################################################################
# Entry point
###############################################################################

trap release_lock EXIT INT TERM

command_requirements_ok || {
  mkdir -p "$STATE_DIR" 2>/dev/null
  log_msg "Missing required command: ip, iptables, awk, or grep"
  exit 1
}

acquire_lock || exit 0
wait_for_android_boot

# Start the independent universal updater only when explicitly enabled.
start_update_loop

enable_adb_tcp
log_msg "Breakout Box service started"
supervisor_loop
