#!/bin/bash
# Installer for MQTT Poweroff

set -euo pipefail

# Defaults
BROKER_DEFAULT="192.168.22.5"
TOPIC_POWER_DEFAULT="muh/poweroff"

# Pin to a tag or commit via MQTT_POWEROFF_REF for reproducible installs
REF="${MQTT_POWEROFF_REF:-main}"
BASE_URL="https://raw.githubusercontent.com/13/mqtt-poweroff/$REF"

ENV_FILE="/etc/default/mqtt-poweroff"

# Check for root
if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] This installer must be run as root."
    echo "Try: sudo bash -c \"\$(curl -fsSL $BASE_URL/install.sh)\""
    exit 1
fi

# Check dependencies
for cmd in mosquitto_sub mosquitto_pub curl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "[ERROR] $cmd is not installed"
        echo "[INFO] Please install the mosquitto-clients (and curl) packages"
        exit 1
    fi
done

if ! command -v jq >/dev/null 2>&1; then
    echo "[WARN] jq not installed — the listener will fall back to sed for JSON parsing."
    echo "[WARN] Installing jq is recommended."
fi

echo "=== MQTT Poweroff Installer ==="

# Ask for configuration
read -rp "Enter MQTT broker IP [${BROKER_DEFAULT}]: " BROKER
BROKER=${BROKER:-$BROKER_DEFAULT}

read -rp "Enter MQTT poweroff topic [${TOPIC_POWER_DEFAULT}]: " TOPIC_POWER
TOPIC_POWER=${TOPIC_POWER:-$TOPIC_POWER_DEFAULT}

read -rp "Enter MQTT username (empty for none): " MQTT_USER
MQTT_PASS=""
if [ -n "$MQTT_USER" ]; then
    read -rsp "Enter MQTT password: " MQTT_PASS
    echo
fi

read -rp "Enter shared secret for poweroff payloads (empty to disable): " MQTT_SECRET

# Temp working dir, cleaned up on any exit
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
cd "$WORKDIR"

echo "[INFO] Downloading scripts (ref: $REF)..."
curl -fsSL "$BASE_URL/mqtt-poweroff.sh" -o mqtt-poweroff.sh
curl -fsSL "$BASE_URL/mqtt-poweroff.service" -o mqtt-poweroff.service

# Install script and systemd service
install -m 755 mqtt-poweroff.sh /usr/local/bin/mqtt-poweroff.sh
install -m 644 mqtt-poweroff.service /etc/systemd/system/mqtt-poweroff.service

# Write configuration; mode 600 because it may contain credentials
echo "[INFO] Writing $ENV_FILE"
{
    echo "MQTT_BROKER=\"${BROKER//\"/\\\"}\""
    echo "MQTT_TOPIC=\"${TOPIC_POWER//\"/\\\"}\""
    if [ -n "$MQTT_USER" ]; then echo "MQTT_USER=\"${MQTT_USER//\"/\\\"}\""; fi
    if [ -n "$MQTT_PASS" ]; then echo "MQTT_PASS=\"${MQTT_PASS//\"/\\\"}\""; fi
    if [ -n "$MQTT_SECRET" ]; then echo "MQTT_SECRET=\"${MQTT_SECRET//\"/\\\"}\""; fi
} > "$ENV_FILE"
chmod 600 "$ENV_FILE"

# Stop and disable old mqtt-status service if it exists
systemctl stop mqtt-status.service 2>/dev/null || true
systemctl disable mqtt-status.service 2>/dev/null || true
rm -f /etc/systemd/system/mqtt-status.service
rm -f /usr/local/bin/mqtt-status.sh

# Enable & start service
systemctl daemon-reload
systemctl enable --now mqtt-poweroff.service

echo "[DONE] MQTT Poweroff installed and running."
echo "[INFO] Configuration: $ENV_FILE (edit and 'systemctl restart mqtt-poweroff' to apply)"
