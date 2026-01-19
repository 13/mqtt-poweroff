#!/bin/bash
# Publish minimal online/offline status to MQTT with proper LWT

set -euo pipefail

BROKER="${MQTT_BROKER:-192.168.22.5}"
HOSTNAME="$(hostname | tr 'A-Z' 'a-z').muh"
IP=$(hostname -I | awk '{print $1}')
MAC=$(cat /sys/class/net/*/address | grep -Ev '^00:00:00' | head -n1 | tr 'A-Z' 'a-z')
TOPIC="muh/pc/$HOSTNAME"

# Check if mosquitto_pub is installed
if ! command -v mosquitto_pub >/dev/null 2>&1; then
    echo "[ERROR] mosquitto_pub is not installed"
    echo "[INFO] Please install mosquitto-clients package"
    exit 1
fi

# Messages
ONLINE="{\"name\":\"$HOSTNAME\",\"ip\":\"$IP\",\"mac\":\"$MAC\",\"alive\":true}"
OFFLINE="{\"name\":\"$HOSTNAME\",\"ip\":\"$IP\",\"mac\":\"$MAC\",\"alive\":false}"

echo "[INFO] Connecting to MQTT broker $BROKER and publishing alive status..."

# Persistent connection with LWT
mosquitto_pub -h "$BROKER" \
  -t "$TOPIC" \
  -i "$HOSTNAME" \
  -m "$ONLINE" \
  -lwt "$TOPIC" \
  -lm "$OFFLINE" \
  -r

# Keep the script alive so LWT works on unexpected shutdown
while true; do
    sleep 60
done
