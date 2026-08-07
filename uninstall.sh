#!/system/bin/sh
STATE_DIR="/data/adb/breakout-box"
CONFIG="$STATE_DIR/config.conf"
VPN_INTERFACE="tun0"; VPN_NETWORK="10.8.0.0/24"; VPN_TABLE="100"; WAN_TABLE="101"
VPN_TO_CLIENT_PRIORITY="9000"; VPN_FROM_CLIENT_PRIORITY="9001"; VPN_IIF_PRIORITY="9002"
FILTER_CHAIN="BB_FORWARD"; NAT_CHAIN="BB_NAT"
[ -r "$CONFIG" ] && . "$CONFIG"
ip rule del to "$VPN_NETWORK" lookup "$VPN_TABLE" priority "$VPN_TO_CLIENT_PRIORITY" 2>/dev/null
ip rule del from "$VPN_NETWORK" lookup "$WAN_TABLE" priority "$VPN_FROM_CLIENT_PRIORITY" 2>/dev/null
ip rule del iif "$VPN_INTERFACE" lookup "$WAN_TABLE" priority "$VPN_IIF_PRIORITY" 2>/dev/null
ip route flush table "$VPN_TABLE" 2>/dev/null
ip route flush table "$WAN_TABLE" 2>/dev/null
iptables -D FORWARD -j "$FILTER_CHAIN" 2>/dev/null
iptables -F "$FILTER_CHAIN" 2>/dev/null
iptables -X "$FILTER_CHAIN" 2>/dev/null
iptables -t nat -D POSTROUTING -j "$NAT_CHAIN" 2>/dev/null
iptables -t nat -F "$NAT_CHAIN" 2>/dev/null
iptables -t nat -X "$NAT_CHAIN" 2>/dev/null
rm -rf "$STATE_DIR"
