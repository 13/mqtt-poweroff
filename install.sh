#!/bin/bash
# One-liner installer for mqtt-poweroff

set -euo pipefail

# Defaults
BROKER_DEFAULT="192.168.22.5"
TOPIC_DEFAULT="muh/poweroff"

echo "=== MQTT Poweroff Installer ==="

# Check if mosquitto_sub is installed
if ! command -v mosquitto_sub >/dev/null 2>&1; then
    echo "[ERROR] mosquitto_sub is not installed"
    echo "[INFO] Please install mosquitto-clients package:"
    echo "       - Debian/Ubuntu: sudo apt-get install mosquitto-clients"
    echo "       - RHEL/CentOS: sudo yum install mosquitto-clients"
    echo "       - Arch: sudo pacman -S mosquitto"
    exit 1
fi
echo "[INFO] mosquitto_sub found"

read -rp "Enter MQTT broker IP [${BROKER_DEFAULT}]: " BROKER
BROKER=${BROKER:-$BROKER_DEFAULT}

read -rp "Enter MQTT topic [${TOPIC_DEFAULT}]: " TOPIC
TOPIC=${TOPIC:-$TOPIC_DEFAULT}

TMPDIR=$(mktemp -d)
cd "$TMPDIR"

echo "[INFO] Downloading files..."
curl -fsSL "https://raw.githubusercontent.com/13/mqtt-poweroff/main/mqtt-poweroff.sh" -o mqtt-poweroff.sh
curl -fsSL "https://raw.githubusercontent.com/13/mqtt-poweroff/main/mqtt-poweroff.service" -o mqtt-poweroff.service

# Inject broker & topic using environment variables
sed -i "s|^BROKER=.*|BROKER=\"$BROKER\"|" mqtt-poweroff.sh
sed -i "s|^TOPIC=.*|TOPIC=\"$TOPIC\"|" mqtt-poweroff.sh

# Install
sudo cp mqtt-poweroff.sh /usr/local/bin/mqtt-poweroff.sh
sudo chmod +x /usr/local/bin/mqtt-poweroff.sh
sudo cp mqtt-poweroff.service /etc/systemd/system/mqtt-poweroff.service

# Enable & start
sudo systemctl daemon-reload
sudo systemctl enable --now mqtt-poweroff.service

cd /
rm -rf "$TMPDIR"

echo "[DONE] MQTT Poweroff installed and running."
