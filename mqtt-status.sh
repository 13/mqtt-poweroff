#!/bin/bash
# Publish minimal online/offline status to MQTT

BROKER="${MQTT_BROKER:-192.168.22.5}"
#HOSTNAME=$(hostname | tr 'A-Z' 'a-z')
HOSTNAME="$(hostname | tr 'A-Z' 'a-z').muh"
IP=$(hostname -I | awk '{print $1}')
MAC=$(cat /sys/class/net/*/address | grep -Ev '^00:00:00' | head -n1 | tr 'A-Z' 'a-z')
TOPIC="muh/pc/$HOSTNAME"

# Check if mosquitto_sub is installed
if ! command -v mosquitto_sub >/dev/null 2>&1; then
    echo "[ERROR] mosquitto_sub is not installed"
    echo "[INFO] Please install mosquitto-clients package"
    exit 1
fi

publish_status() {
    local alive=$1
    mosquitto_pub -h "$BROKER" \
      -t "$TOPIC" \
      -m "{\"name\":\"$HOSTNAME\",\"ip\":\"$IP\",\"mac\":\"$MAC\",\"alive\":$alive}" \
      -r
}

# Publish online
publish_status true

# Setup LWT for offline detection
mosquitto_pub -h "$BROKER" \
  -t "$TOPIC" \
  -i "$HOSTNAME" \
  -m "{\"name\":\"$HOSTNAME\",\"ip\":\"$IP\",\"mac\":\"$MAC\",\"alive\":true}" \
  -lwt "$TOPIC" \
  -lm "{\"name\":\"$HOSTNAME\",\"ip\":\"$IP\",\"mac\":\"$MAC\",\"alive\":false}" \
  -r
