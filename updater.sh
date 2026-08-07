#!/system/bin/sh
# Universal secure updater for Magisk modules.
# The same file can be used unchanged across modules.

MODDIR="${MODDIR:-${0%/*}}"
export PATH="/data/adb/magisk:/data/adb/magisk/bin:/system/bin:/system/xbin:/vendor/bin:/product/bin:/apex/com.android.runtime/bin:$PATH"

MODULE_PROP="$MODDIR/module.prop"
DEFAULT_CONFIG="$MODDIR/default-config.conf"

[ -r "$MODULE_PROP" ] || { echo "ERROR: module.prop not found: $MODULE_PROP" >&2; exit 1; }

MODULE_ID="$(sed -n 's/^id=//p' "$MODULE_PROP" 2>/dev/null | head -n 1 | tr -d '\r')"
MODULE_NAME="$(sed -n 's/^name=//p' "$MODULE_PROP" 2>/dev/null | head -n 1 | tr -d '\r')"
CURRENT_VERSION="$(sed -n 's/^version=//p' "$MODULE_PROP" 2>/dev/null | head -n 1 | tr -d '\r')"
CURRENT_VERSION_CODE="$(sed -n 's/^versionCode=//p' "$MODULE_PROP" 2>/dev/null | head -n 1 | tr -d '\r')"

[ -n "$MODULE_ID" ] || { echo "ERROR: module ID is missing from module.prop" >&2; exit 1; }

# Universal updater defaults. Module defaults may override these.
AUTO_UPDATE=false
UPDATE_CHECK_INTERVAL_SECONDS=86400
UPDATE_INITIAL_DELAY_SECONDS=120
UPDATE_JSON_URL=""
UPDATE_REQUIRE_SHA256=true
UPDATE_INSTALL_ONLY_ON_WIFI=false
UPDATE_KEEP_DOWNLOADED_ZIP=false
MODULE_STATE_DIR=""

# Load packaged defaults first so a module can override its state directory.
[ -r "$DEFAULT_CONFIG" ] && . "$DEFAULT_CONFIG"

STATE_DIR="${MODULE_STATE_DIR:-/data/adb/$MODULE_ID}"
CONFIG_FILE="$STATE_DIR/config.conf"
UPDATE_DIR="$STATE_DIR/update"
LOG_FILE="$STATE_DIR/update.log"
STATUS_FILE="$STATE_DIR/update.status"
LOCK_DIR="$STATE_DIR/update.lock"
PID_FILE="$STATE_DIR/updater.pid"

# Persistent config always wins over packaged defaults.
[ -r "$CONFIG_FILE" ] && . "$CONFIG_FILE"
# Re-evaluate only if persistent config intentionally overrides MODULE_STATE_DIR.
if [ -n "${MODULE_STATE_DIR:-}" ] && [ "$STATE_DIR" != "$MODULE_STATE_DIR" ]; then
    STATE_DIR="$MODULE_STATE_DIR"
    CONFIG_FILE="$STATE_DIR/config.conf"
    UPDATE_DIR="$STATE_DIR/update"
    LOG_FILE="$STATE_DIR/update.log"
    STATUS_FILE="$STATE_DIR/update.status"
    LOCK_DIR="$STATE_DIR/update.lock"
    PID_FILE="$STATE_DIR/updater.pid"
    [ -r "$CONFIG_FILE" ] && . "$CONFIG_FILE"
fi

mkdir -p "$STATE_DIR" "$UPDATE_DIR" 2>/dev/null
chmod 700 "$STATE_DIR" "$UPDATE_DIR" 2>/dev/null

log_msg() {
    LEVEL="$1"; shift
    MESSAGE="$*"
    TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
    printf '[%s] [%s] %s\n' "$TIMESTAMP" "$LEVEL" "$MESSAGE" >> "$LOG_FILE" 2>/dev/null
    command -v log >/dev/null 2>&1 && log -t "${MODULE_ID}-updater" "[$LEVEL] $MESSAGE" 2>/dev/null
}

bool_true() { case "$1" in 1|true|TRUE|yes|YES|on|ON) return 0 ;; *) return 1 ;; esac; }
is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

find_busybox() {
    for p in /data/adb/magisk/busybox /data/adb/ksu/bin/busybox /system/bin/busybox /system/xbin/busybox; do
        [ -x "$p" ] && { printf '%s\n' "$p"; return 0; }
    done
    command -v busybox 2>/dev/null
}
BB="$(find_busybox)"

cleanup_lock() { rmdir "$LOCK_DIR" 2>/dev/null; }
secure_url() { case "$1" in https://*) return 0 ;; *) return 1 ;; esac; }

download_file() {
    URL="$1"; OUTPUT="$2"; TEMP_FILE="${OUTPUT}.part"
    rm -f "$TEMP_FILE"
    secure_url "$URL" || { log_msg ERROR "Rejected non-HTTPS URL: $URL"; return 1; }

    if command -v curl >/dev/null 2>&1; then
        curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 \
            --connect-timeout 20 --max-time 300 --retry 3 -o "$TEMP_FILE" "$URL" || return 1
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 300 -O "$TEMP_FILE" "$URL" || return 1
    elif [ -n "$BB" ]; then
        "$BB" wget -q -T 300 -O "$TEMP_FILE" "$URL" || return 1
    else
        log_msg ERROR "No curl, wget, or BusyBox wget is available"
        return 1
    fi

    [ -s "$TEMP_FILE" ] || { rm -f "$TEMP_FILE"; log_msg ERROR "Downloaded file is empty"; return 1; }
    mv -f "$TEMP_FILE" "$OUTPUT"
}

json_string() {
    KEY="$1"; FILE="$2"
    tr '\n' ' ' < "$FILE" | sed -n "s/.*\"$KEY\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1
}

json_uint() {
    KEY="$1"; FILE="$2"
    tr '\n' ' ' < "$FILE" | sed -n "s/.*\"$KEY\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" | head -n 1
}

sha256_file() {
    FILE="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$FILE" | awk '{print $1}'
    elif command -v toybox >/dev/null 2>&1; then
        toybox sha256sum "$FILE" | awk '{print $1}'
    elif [ -n "$BB" ]; then
        "$BB" sha256sum "$FILE" | awk '{print $1}'
    else
        return 1
    fi
}

wifi_connected() {
    ip route 2>/dev/null | grep -Eq '(^|[[:space:]])dev[[:space:]]+(wlan|wifi)[^[:space:]]*([[:space:]]|$)'
}

validate_sha256_string() {
    VALUE="$1"
    [ "${#VALUE}" -eq 64 ] || return 1
    case "$VALUE" in *[!0-9a-f]*) return 1 ;; esac
    return 0
}

extract_module_prop() {
    ZIP="$1"; OUT="$2"
    rm -f "$OUT"
    if [ -n "$BB" ]; then
        "$BB" unzip -p "$ZIP" module.prop > "$OUT" 2>/dev/null
    elif command -v unzip >/dev/null 2>&1; then
        unzip -p "$ZIP" module.prop > "$OUT" 2>/dev/null
    else
        log_msg ERROR "No unzip implementation is available"
        return 1
    fi
}

validate_zip() {
    ZIP="$1"; EXPECTED_ID="$2"; EXPECTED_CODE="$3"
    TEMP_PROP="$UPDATE_DIR/module.prop.new"
    extract_module_prop "$ZIP" "$TEMP_PROP" || return 1
    [ -s "$TEMP_PROP" ] || { log_msg ERROR "Downloaded ZIP has no root module.prop"; rm -f "$TEMP_PROP"; return 1; }

    GOT_ID="$(sed -n 's/^id=//p' "$TEMP_PROP" | head -n 1 | tr -d '\r')"
    GOT_CODE="$(sed -n 's/^versionCode=//p' "$TEMP_PROP" | head -n 1 | tr -d '\r')"
    rm -f "$TEMP_PROP"

    [ "$GOT_ID" = "$EXPECTED_ID" ] || { log_msg ERROR "ZIP module ID mismatch: expected=$EXPECTED_ID got=$GOT_ID"; return 1; }
    [ "$GOT_CODE" = "$EXPECTED_CODE" ] || { log_msg ERROR "ZIP versionCode mismatch: expected=$EXPECTED_CODE got=$GOT_CODE"; return 1; }
    log_msg INFO "ZIP verified: id=$GOT_ID versionCode=$GOT_CODE"
    return 0
}

check_once() (
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        log_msg INFO "Update check skipped because another operation is active"
        return 0
    fi
    trap cleanup_lock EXIT INT TERM HUP

    case "$UPDATE_JSON_URL" in
        ''|https://example.invalid/*)
            log_msg ERROR "UPDATE_JSON_URL is not configured"
            cleanup_lock; trap - EXIT INT TERM HUP; return 2 ;;
    esac
    secure_url "$UPDATE_JSON_URL" || { log_msg ERROR "UPDATE_JSON_URL must use HTTPS"; cleanup_lock; trap - EXIT INT TERM HUP; return 2; }

    if bool_true "$UPDATE_INSTALL_ONLY_ON_WIFI" && ! wifi_connected; then
        log_msg INFO "Update skipped because Wi-Fi is not connected"
        cleanup_lock; trap - EXIT INT TERM HUP; return 0
    fi

    MANIFEST="$UPDATE_DIR/update.json"
    ZIP="$UPDATE_DIR/module-update.zip"
    rm -f "$MANIFEST" "$MANIFEST.part" "$ZIP" "$ZIP.part"

    log_msg INFO "Checking for updates"
    download_file "$UPDATE_JSON_URL" "$MANIFEST" || { log_msg ERROR "Failed to download update manifest"; cleanup_lock; trap - EXIT INT TERM HUP; return 1; }

    NEW_CODE="$(json_uint versionCode "$MANIFEST")"
    NEW_VERSION="$(json_string version "$MANIFEST")"
    ZIP_URL="$(json_string zipUrl "$MANIFEST")"
    EXPECTED_SHA="$(json_string sha256 "$MANIFEST" | tr 'A-F' 'a-f')"

    is_uint "$CURRENT_VERSION_CODE" || { log_msg ERROR "Current versionCode is invalid: $CURRENT_VERSION_CODE"; cleanup_lock; trap - EXIT INT TERM HUP; return 1; }
    is_uint "$NEW_CODE" || { log_msg ERROR "Manifest versionCode is invalid"; cleanup_lock; trap - EXIT INT TERM HUP; return 1; }

    if [ "$NEW_CODE" -le "$CURRENT_VERSION_CODE" ]; then
        log_msg INFO "No update available; installed=$CURRENT_VERSION_CODE remote=$NEW_CODE"
        printf '%s\n' "up-to-date installed=$CURRENT_VERSION_CODE remote=$NEW_CODE" > "$STATUS_FILE"
        cleanup_lock; trap - EXIT INT TERM HUP; return 0
    fi

    secure_url "$ZIP_URL" || { log_msg ERROR "Manifest zipUrl is missing or insecure"; cleanup_lock; trap - EXIT INT TERM HUP; return 1; }
    log_msg INFO "Downloading version ${NEW_VERSION:-unknown} ($NEW_CODE)"
    download_file "$ZIP_URL" "$ZIP" || { log_msg ERROR "Failed to download update ZIP"; cleanup_lock; trap - EXIT INT TERM HUP; return 1; }

    if bool_true "$UPDATE_REQUIRE_SHA256"; then
        validate_sha256_string "$EXPECTED_SHA" || { log_msg ERROR "Manifest SHA-256 is missing or invalid"; rm -f "$ZIP"; cleanup_lock; trap - EXIT INT TERM HUP; return 1; }
        ACTUAL_SHA="$(sha256_file "$ZIP" 2>/dev/null | tr 'A-F' 'a-f')"
        validate_sha256_string "$ACTUAL_SHA" || { log_msg ERROR "No valid SHA-256 implementation is available"; rm -f "$ZIP"; cleanup_lock; trap - EXIT INT TERM HUP; return 1; }
        [ "$ACTUAL_SHA" = "$EXPECTED_SHA" ] || { log_msg ERROR "SHA-256 mismatch; update rejected"; rm -f "$ZIP"; cleanup_lock; trap - EXIT INT TERM HUP; return 1; }
        log_msg INFO "SHA-256 verification successful"
    fi

    validate_zip "$ZIP" "$MODULE_ID" "$NEW_CODE" || { log_msg ERROR "Downloaded ZIP validation failed"; rm -f "$ZIP"; cleanup_lock; trap - EXIT INT TERM HUP; return 1; }

    command -v magisk >/dev/null 2>&1 || { log_msg ERROR "Magisk command unavailable; cannot install update"; cleanup_lock; trap - EXIT INT TERM HUP; return 1; }
    log_msg INFO "Installing update version=${NEW_VERSION:-unknown} versionCode=$NEW_CODE"

    if magisk --install-module "$ZIP" >> "$LOG_FILE" 2>&1; then
        log_msg INFO "Update installed successfully; reboot required"
        printf '%s\n' "installed version=${NEW_VERSION:-unknown} versionCode=$NEW_CODE reboot_required=true" > "$STATUS_FILE"
        bool_true "$UPDATE_KEEP_DOWNLOADED_ZIP" || rm -f "$ZIP"
        cleanup_lock; trap - EXIT INT TERM HUP; return 0
    fi

    log_msg ERROR "Magisk rejected the module update"
    printf '%s\n' "install-failed versionCode=$NEW_CODE" > "$STATUS_FILE"
    cleanup_lock; trap - EXIT INT TERM HUP; return 1
)

run_loop() {
    bool_true "$AUTO_UPDATE" || { log_msg INFO "AUTO_UPDATE=false; automatic updater disabled"; return 0; }
    INITIAL_DELAY="$UPDATE_INITIAL_DELAY_SECONDS"
    INTERVAL="$UPDATE_CHECK_INTERVAL_SECONDS"
    is_uint "$INITIAL_DELAY" || INITIAL_DELAY=120
    is_uint "$INTERVAL" || INTERVAL=86400
    [ "$INTERVAL" -lt 3600 ] && INTERVAL=3600

    echo "$$" > "$PID_FILE"
    trap 'rm -f "$PID_FILE"; cleanup_lock; exit 0' INT TERM HUP EXIT
    log_msg INFO "Update loop started: initial_delay=${INITIAL_DELAY}s interval=${INTERVAL}s"
    sleep "$INITIAL_DELAY"
    while true; do
        check_once
        sleep "$INTERVAL"
    done
}

show_status() {
    echo "Module: $MODULE_NAME"
    echo "ID: $MODULE_ID"
    echo "Installed version: $CURRENT_VERSION"
    echo "Installed versionCode: $CURRENT_VERSION_CODE"
    echo "AUTO_UPDATE: $AUTO_UPDATE"
    echo "UPDATE_CHECK_INTERVAL_SECONDS: $UPDATE_CHECK_INTERVAL_SECONDS"
    echo "UPDATE_INITIAL_DELAY_SECONDS: $UPDATE_INITIAL_DELAY_SECONDS"
    echo "UPDATE_INSTALL_ONLY_ON_WIFI: $UPDATE_INSTALL_ONLY_ON_WIFI"
    echo "UPDATE_REQUIRE_SHA256: $UPDATE_REQUIRE_SHA256"
    echo "UPDATE_KEEP_DOWNLOADED_ZIP: $UPDATE_KEEP_DOWNLOADED_ZIP"
    echo "Manifest: $UPDATE_JSON_URL"
    [ -r "$STATUS_FILE" ] && { echo "Last status:"; cat "$STATUS_FILE"; } || echo "Last status: none"
    if [ -r "$PID_FILE" ]; then
        PID="$(cat "$PID_FILE" 2>/dev/null)"
        if is_uint "$PID" && kill -0 "$PID" 2>/dev/null; then echo "Updater loop: running (PID $PID)"; else echo "Updater loop: stale PID"; fi
    else
        echo "Updater loop: stopped"
    fi
}

case "${1:-check}" in
    check) check_once; exit $? ;;
    loop) run_loop; exit $? ;;
    status) show_status; exit 0 ;;
    *) echo "Usage: $0 {check|loop|status}" >&2; exit 2 ;;
esac
