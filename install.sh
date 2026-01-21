#!/bin/bash
# Installer for MQTT Poweroff

set -euo pipefail

# Defaults
BROKER_DEFAULT="192.168.22.5"
TOPIC_POWER_DEFAULT="muh/poweroff"

# Check for root
if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] This installer must be run as root."
    echo "Try: sudo bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/13/mqtt-poweroff/main/install.sh)\""
    exit 1
fi

# Check if mosquitto_sub and mosquitto_pub are installed
if ! command -v mosquitto_sub >/dev/null 2>&1; then
    echo "[ERROR] mosquitto_sub is not installed"
    echo "[INFO] Please install mosquitto-clients package"
    exit 1
fi

if ! command -v mosquitto_pub >/dev/null 2>&1; then
    echo "[ERROR] mosquitto_pub is not installed"
    echo "[INFO] Please install mosquitto-clients package"
    exit 1
fi

echo "=== MQTT Poweroff Installer ==="

# Ask for broker & poweroff topic
read -rp "Enter MQTT broker IP [${BROKER_DEFAULT}]: " BROKER
BROKER=${BROKER:-$BROKER_DEFAULT}

read -rp "Enter MQTT poweroff topic [${TOPIC_POWER_DEFAULT}]: " TOPIC_POWER
TOPIC_POWER=${TOPIC_POWER:-$TOPIC_POWER_DEFAULT}

# Temp working dir
TMPDIR=$(mktemp -d)
cd "$TMPDIR"

echo "[INFO] Downloading scripts..."
curl -fsSL "https://raw.githubusercontent.com/13/mqtt-poweroff/main/mqtt-poweroff.sh" -o mqtt-poweroff.sh
curl -fsSL "https://raw.githubusercontent.com/13/mqtt-poweroff/main/mqtt-poweroff.service" -o mqtt-poweroff.service

# Inject broker & topic into poweroff script
sed -i "s|^BROKER=.*|BROKER=\"$BROKER\"|" mqtt-poweroff.sh
sed -i "s|^TOPIC=.*|TOPIC=\"$TOPIC_POWER\"|" mqtt-poweroff.sh

# Make scripts executable
chmod +x mqtt-poweroff.sh

# Install scripts
cp mqtt-poweroff.sh /usr/local/bin/mqtt-poweroff.sh

# Install systemd services
cp mqtt-poweroff.service /etc/systemd/system/mqtt-poweroff.service

# Stop and disable old mqtt-status service if it exists
systemctl stop mqtt-status.service 2>/dev/null || true
systemctl disable mqtt-status.service 2>/dev/null || true
rm -f /etc/systemd/system/mqtt-status.service
rm -f /usr/local/bin/mqtt-status.sh

# Enable & start services
systemctl daemon-reload
systemctl enable --now mqtt-poweroff.service

# Cleanup
cd /
rm -rf "$TMPDIR"

echo "[DONE] MQTT Poweroff installed and running."

