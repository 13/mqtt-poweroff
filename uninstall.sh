#!/bin/bash
# Uninstaller for MQTT Poweroff

set -euo pipefail

# Check for root
if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] This uninstaller must be run as root."
    echo "Try: sudo bash uninstall.sh"
    exit 1
fi

echo "=== MQTT Poweroff Uninstaller ==="

# Stop and disable the service
echo "[INFO] Stopping and disabling mqtt-poweroff service..."
systemctl stop mqtt-poweroff.service 2>/dev/null || true
systemctl disable mqtt-poweroff.service 2>/dev/null || true

# Remove systemd service file
echo "[INFO] Removing systemd service file..."
rm -f /etc/systemd/system/mqtt-poweroff.service

# Remove script
echo "[INFO] Removing mqtt-poweroff script..."
rm -f /usr/local/bin/mqtt-poweroff.sh

# Also clean up old mqtt-status files if they exist
echo "[INFO] Cleaning up old mqtt-status files (if any)..."
systemctl stop mqtt-status.service 2>/dev/null || true
systemctl disable mqtt-status.service 2>/dev/null || true
rm -f /etc/systemd/system/mqtt-status.service
rm -f /usr/local/bin/mqtt-status.sh

# Reload systemd
echo "[INFO] Reloading systemd daemon..."
systemctl daemon-reload

echo "[DONE] MQTT Poweroff has been uninstalled."
