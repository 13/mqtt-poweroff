#!/bin/bash
# Installer for MQTT Poweroff + Minimal Status

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

# Check if mosquitto_sub is installed
if ! command -v mosquitto_sub >/dev/null 2>&1; then
    echo "[ERROR] mosquitto_sub is not installed"
    echo "[INFO] Please install mosquitto-clients package"
    exit 1
fi

echo "=== MQTT Poweroff + Status Installer ==="

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
curl -fsSL "https://raw.githubusercontent.com/13/mqtt-poweroff/main/mqtt-status.sh" -o mqtt-status.sh
curl -fsSL "https://raw.githubusercontent.com/13/mqtt-poweroff/main/mqtt-poweroff.service" -o mqtt-poweroff.service
curl -fsSL "https://raw.githubusercontent.com/13/mqtt-poweroff/main/mqtt-status.service" -o mqtt-status.service

# Inject broker & topic into poweroff script
sed -i "s|^BROKER=.*|BROKER=\"$BROKER\"|" mqtt-poweroff.sh
sed -i "s|^TOPIC=.*|TOPIC=\"$TOPIC_POWER\"|" mqtt-poweroff.sh

# Make scripts executable
chmod +x mqtt-poweroff.sh mqtt-status.sh

# Install scripts
cp mqtt-poweroff.sh /usr/local/bin/mqtt-poweroff.sh
cp mqtt-status.sh /usr/local/bin/mqtt-status.sh

# Install systemd services
cp mqtt-poweroff.service /etc/systemd/system/mqtt-poweroff.service
cp mqtt-status.service /etc/systemd/system/mqtt-status.service

# Enable & start services
systemctl daemon-reload
systemctl enable --now mqtt-poweroff.service
systemctl enable --now mqtt-status.service

# Cleanup
cd /
rm -rf "$TMPDIR"

echo "[DONE] MQTT Poweroff + Status installed and running."

