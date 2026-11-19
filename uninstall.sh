#!/bin/bash
# Uninstaller for MQTT Poweroff

set -euo pipefail

ENV_FILE="/etc/default/mqtt-poweroff"
BIN_PATH="/usr/local/bin/mqtt-poweroff.sh"

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

# Remove retained status and Home Assistant discovery messages from the
# broker; needs the installed script and its configuration
if [ -x "$BIN_PATH" ] && "$BIN_PATH" --version >/dev/null 2>&1; then
    echo "[INFO] Clearing retained MQTT topics..."
    (
        set -a
        # shellcheck disable=SC1090
        [ ! -r "$ENV_FILE" ] || . "$ENV_FILE"
        set +a
        timeout 30 "$BIN_PATH" --cleanup
    ) || echo "[WARN] Could not clear retained MQTT topics (broker unreachable?)"
fi

# Remove systemd service file
echo "[INFO] Removing systemd service file..."
rm -f /etc/systemd/system/mqtt-poweroff.service

# Remove script
echo "[INFO] Removing mqtt-poweroff script..."
rm -f "$BIN_PATH"

# Remove configuration
echo "[INFO] Removing configuration..."
rm -f "$ENV_FILE"

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
