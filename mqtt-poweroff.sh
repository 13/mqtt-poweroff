#!/bin/bash
# MQTT Poweroff Listener (MAC matched)

set -euo pipefail

# Check dependencies; report all missing tools at once
MISSING=()
for cmd in mosquitto_sub mosquitto_pub ip awk sed grep systemctl; do
    command -v "$cmd" >/dev/null 2>&1 || MISSING+=("$cmd")
done
if [ "${#MISSING[@]}" -gt 0 ]; then
    echo "[ERROR] Missing required tools: ${MISSING[*]}"
    echo "[INFO] Install mosquitto-clients, iproute2, gawk, sed, grep and systemd"
    exit 1
fi

HAVE_JQ=0
if command -v jq >/dev/null 2>&1; then
    HAVE_JQ=1
else
    echo "[WARN] jq not installed, falling back to sed for JSON parsing"
fi

# Configuration from environment (see /etc/default/mqtt-poweroff) or defaults
BROKER="${MQTT_BROKER:-192.168.22.5}"
TOPIC="${MQTT_TOPIC:-muh/poweroff}"
MQTT_USER="${MQTT_USER:-}"
MQTT_PASS="${MQTT_PASS:-}"
MQTT_QOS="${MQTT_QOS:-1}"
MQTT_SECRET="${MQTT_SECRET:-}"
NODE_SUFFIX="${NODE_SUFFIX:-.muh}"
STATUS_PREFIX="${STATUS_PREFIX:-muh/pc}"
MQTT_WOL="${MQTT_WOL:-1}"
MQTT_IFACE="${MQTT_IFACE:-}"

AUTH_ARGS=()
if [ -n "$MQTT_USER" ]; then
    AUTH_ARGS+=(-u "$MQTT_USER")
    if [ -n "$MQTT_PASS" ]; then
        AUTH_ARGS+=(-P "$MQTT_PASS")
    fi
fi

NODE_NAME="$(cat /etc/hostname | tr '[:upper:]' '[:lower:]')${NODE_SUFFIX}"
STATUS_TOPIC="$STATUS_PREFIX/$NODE_NAME"

# Wait for an IP address; the service may start before DHCP has finished
IP=""
for _ in $(seq 1 30); do
    IP=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
    if [ -n "$IP" ]; then break; fi
    sleep 1
done
[ -n "$IP" ] || echo "[WARN] No IP address found, continuing without it"

# Use the interface of the default route unless overridden
IFACE="$MQTT_IFACE"
if [ -z "$IFACE" ]; then
    IFACE=$(ip route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i+1); exit}}')
fi

if [ -n "$IFACE" ] && [ -r "/sys/class/net/$IFACE/address" ]; then
    LOCAL_MAC=$(tr '[:upper:]' '[:lower:]' < "/sys/class/net/$IFACE/address")
else
    [ -z "$IFACE" ] || echo "[WARN] Interface $IFACE not found"
    echo "[WARN] Falling back to first non-zero MAC"
    IFACE=""
    LOCAL_MAC=$(cat /sys/class/net/*/address | grep -Ev '^00:00:00' | head -n1 | tr '[:upper:]' '[:lower:]')
fi

# Enable Wake-on-LAN (magic packet) on $IFACE; sets WOL_ACTIVE.
# Many drivers reset this on reboot, so it runs at startup and before poweroff.
WOL_ACTIVE=false
enable_wol() {
    WOL_ACTIVE=false
    [ "$MQTT_WOL" = "1" ] || return 0
    if ! command -v ethtool >/dev/null 2>&1; then
        echo "[WARN] ethtool not installed, cannot enable Wake-on-LAN"
        return 0
    fi
    if [ -z "$IFACE" ]; then
        echo "[WARN] No interface known, cannot enable Wake-on-LAN"
        return 0
    fi

    local info supported current
    info=$(ethtool "$IFACE" 2>/dev/null) || true
    supported=$(awk -F': *' '/Supports Wake-on:/ {print $2; exit}' <<<"$info")
    current=$(awk -F': *' '/^[[:space:]]*Wake-on:/ {print $2; exit}' <<<"$info")

    if [[ "$supported" != *g* ]]; then
        echo "[WARN] $IFACE does not support Wake-on-LAN magic packet"
        return 0
    fi
    if [[ "$current" == *g* ]]; then
        WOL_ACTIVE=true
        return 0
    fi
    if ethtool -s "$IFACE" wol g; then
        echo "[INFO] Wake-on-LAN enabled on $IFACE"
        WOL_ACTIVE=true
    else
        echo "[WARN] Failed to enable Wake-on-LAN on $IFACE"
    fi
}

enable_wol

status_msg() {
    printf '{"name":"%s","ip":"%s","mac":"%s","wol":%s,"alive":%s}' \
        "$NODE_NAME" "$IP" "$LOCAL_MAC" "$WOL_ACTIVE" "$1"
}

ALIVE_MSG=$(status_msg true)
DEAD_MSG=$(status_msg false)

publish_status() {
    mosquitto_pub -h "$BROKER" ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} -q "$MQTT_QOS" \
        -t "$STATUS_TOPIC" -m "$1" -r \
        || echo "[WARN] Failed to publish status"
}

extract_field() {
    local field="$1" msg="$2"
    if [ "$HAVE_JQ" -eq 1 ]; then
        jq -r --arg f "$field" '.[$f] // empty' <<<"$msg" 2>/dev/null || true
    else
        sed -n "s/.*\"$field\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" <<<"$msg"
    fi
}

# Publish alive:false when the service stops for any reason; the MQTT Last
# Will below covers unclean disconnects where this trap never runs.
trap 'publish_status "$DEAD_MSG"' EXIT

echo "[INFO] Interface: ${IFACE:-unknown}, MAC: $LOCAL_MAC, Wake-on-LAN: $WOL_ACTIVE"
echo "[INFO] Publishing alive status to $STATUS_TOPIC"
publish_status "$ALIVE_MSG"

# -R skips retained messages: a retained poweroff command would otherwise
# shut the machine down on every boot.
echo "[INFO] Subscribing to $TOPIC on $BROKER"
mosquitto_sub -h "$BROKER" ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} \
    -q "$MQTT_QOS" -i "mqtt-poweroff-$NODE_NAME" -R \
    --will-topic "$STATUS_TOPIC" --will-payload "$DEAD_MSG" \
    --will-qos "$MQTT_QOS" --will-retain \
    -t "$TOPIC" | while read -r msg; do
    MAC=$(extract_field mac "$msg" | tr '[:upper:]' '[:lower:]')

    if [ -z "$MAC" ]; then
        echo "[WARN] Invalid payload: $msg"
        continue
    fi

    if [ -n "$MQTT_SECRET" ]; then
        SECRET=$(extract_field secret "$msg")
        if [ "$SECRET" != "$MQTT_SECRET" ]; then
            echo "[WARN] Secret mismatch — ignored"
            continue
        fi
    fi

    echo "[INFO] Received MAC: $MAC"

    if [ "$MAC" = "$LOCAL_MAC" ]; then
        echo "[ACTION] MAC match — powering off"
        enable_wol
        DEAD_MSG=$(status_msg false)
        publish_status "$DEAD_MSG"
        systemctl poweroff
    else
        echo "[INFO] MAC mismatch — ignored"
    fi
done
