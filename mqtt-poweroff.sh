#!/bin/bash
# MQTT Poweroff Listener (MAC matched)

set -euo pipefail

# Check dependencies
for cmd in mosquitto_sub mosquitto_pub; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "[ERROR] $cmd is not installed"
        echo "[INFO] Please install mosquitto-clients package"
        exit 1
    fi
done

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

AUTH_ARGS=()
if [ -n "$MQTT_USER" ]; then
    AUTH_ARGS+=(-u "$MQTT_USER")
    if [ -n "$MQTT_PASS" ]; then
        AUTH_ARGS+=(-P "$MQTT_PASS")
    fi
fi

# Pick first non-zero MAC
LOCAL_MAC=$(cat /sys/class/net/*/address | grep -Ev '^00:00:00' | head -n1 | tr '[:upper:]' '[:lower:]')
NODE_NAME="$(hostname | tr '[:upper:]' '[:lower:]')${NODE_SUFFIX}"
STATUS_TOPIC="$STATUS_PREFIX/$NODE_NAME"

# Wait for an IP address; the service may start before DHCP has finished
IP=""
for _ in $(seq 1 30); do
    IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    if [ -n "$IP" ]; then break; fi
    sleep 1
done
[ -n "$IP" ] || echo "[WARN] No IP address found, continuing without it"

ALIVE_MSG=$(printf '{"name":"%s","ip":"%s","mac":"%s","alive":true}' "$NODE_NAME" "$IP" "$LOCAL_MAC")
DEAD_MSG=$(printf '{"name":"%s","ip":"%s","mac":"%s","alive":false}' "$NODE_NAME" "$IP" "$LOCAL_MAC")

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

echo "[INFO] Local MAC: $LOCAL_MAC"
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
        publish_status "$DEAD_MSG"
        systemctl poweroff
    else
        echo "[INFO] MAC mismatch — ignored"
    fi
done
