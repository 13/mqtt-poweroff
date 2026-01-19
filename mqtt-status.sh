#!/bin/bash
# MQTT Minimal Status Publisher with LWT (Mosquitto 2.x syntax)

set -euo pipefail

BROKER="${MQTT_BROKER:-192.168.22.5}"
HOSTNAME="$(hostname | tr 'A-Z' 'a-z').muh"
IP=$(hostname -I | awk '{print $1}')
MAC=$(cat /sys/class/net/*/address | grep -Ev '^00:00:00' | head -n1 | tr 'A-Z' 'a-z')
TOPIC="muh/pc/$HOSTNAME"

# Check if mosquitto_pub is installed
if ! command -v mosquitto_pub >/dev/null 2>&1; then
    echo "[ERROR] mosquitto_pub is not installed"
    exit 1
fi

# Messages
ONLINE="{\"name\":\"$HOSTNAME\",\"ip\":\"$IP\",\"mac\":\"$MAC\",\"alive\":true}"
OFFLINE="{\"name\":\"$HOSTNAME\",\"ip\":\"$IP\",\"mac\":\"$MAC\",\"alive\":false}"

echo "[INFO] Connecting to MQTT broker $BROKER and publishing alive status..."

# Persistent connection with LWT using MQTT v5 syntax
mosquitto_pub -h "$BROKER" \
  -t "$TOPIC" \
  -i "$HOSTNAME" \
  -m "$ONLINE" \
  --will-topic "$TOPIC" \
  --will-payload "$OFFLINE" \
  --will-retain \
  -r

# Keep script alive so LWT works on unexpected shutdown
while true; do
    sleep 60
done

