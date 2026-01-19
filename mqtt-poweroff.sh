#!/bin/bash
# MQTT Poweroff Listener (MAC matched)

set -euo pipefail

# Check if mosquitto_sub is installed
if ! command -v mosquitto_sub >/dev/null 2>&1; then
    echo "[ERROR] mosquitto_sub is not installed"
    echo "[INFO] Please install mosquitto-clients package"
    exit 1
fi

# Broker and topic from environment variables or defaults
BROKER="${MQTT_BROKER:-192.168.22.5}"
TOPIC="${MQTT_TOPIC:-muh/poweroff}"

# Pick first non-zero MAC
LOCAL_MAC=$(cat /sys/class/net/*/address | grep -Ev '^00:00:00' | head -n1 | tr A-Z a-z)
echo "[INFO] Local MAC: $LOCAL_MAC"

mosquitto_sub -h "$BROKER" -t "$TOPIC" | while read -r msg; do
    MAC=$(echo "$msg" | sed -n 's/.*"mac"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | tr A-Z a-z)

    if [ -z "$MAC" ]; then
        echo "[WARN] Invalid payload: $msg"
        continue
    fi

    echo "[INFO] Received MAC: $MAC"

    if [ "$MAC" = "$LOCAL_MAC" ]; then
        echo "[ACTION] MAC match — powering off"
        systemctl poweroff
    else
        echo "[INFO] MAC mismatch — ignored"
    fi
done
