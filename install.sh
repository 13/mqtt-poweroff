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

# Detect package manager for install hints
PKG_MGR=""
for pm in apt-get dnf pacman zypper; do
    if command -v "$pm" >/dev/null 2>&1; then PKG_MGR="$pm"; break; fi
done

# Map a command to its package name for the detected package manager
pkg_for() {
    case "$1" in
        mosquitto_sub|mosquitto_pub)
            if [ "$PKG_MGR" = "pacman" ] || [ "$PKG_MGR" = "dnf" ]; then echo mosquitto; else echo mosquitto-clients; fi ;;
        ip)
            if [ "$PKG_MGR" = "dnf" ] || [ "$PKG_MGR" = "zypper" ]; then echo iproute; else echo iproute2; fi ;;
        awk) echo gawk ;;
        systemctl) echo systemd ;;
        *) echo "$1" ;;
    esac
}

install_cmd() {
    case "$PKG_MGR" in
        apt-get) echo "apt-get install -y $*" ;;
        dnf)     echo "dnf install -y $*" ;;
        pacman)  echo "pacman -S --needed --noconfirm $*" ;;
        zypper)  echo "zypper install -y $*" ;;
    esac
}

# Collect missing tools: required ones abort, optional ones only warn
check_deps() {
    MISSING_REQ=()
    MISSING_OPT=()
    for cmd in mosquitto_sub mosquitto_pub curl ip awk sed grep systemctl; do
        command -v "$cmd" >/dev/null 2>&1 || MISSING_REQ+=("$cmd")
    done
    for cmd in ethtool jq; do
        command -v "$cmd" >/dev/null 2>&1 || MISSING_OPT+=("$cmd")
    done
}

check_deps
if [ "${#MISSING_REQ[@]}" -gt 0 ] || [ "${#MISSING_OPT[@]}" -gt 0 ]; then
    PKGS=()
    for cmd in ${MISSING_REQ[@]+"${MISSING_REQ[@]}"} ${MISSING_OPT[@]+"${MISSING_OPT[@]}"}; do
        pkg=$(pkg_for "$cmd")
        [[ " ${PKGS[*]-} " == *" $pkg "* ]] || PKGS+=("$pkg")
    done

    [ "${#MISSING_REQ[@]}" -eq 0 ] || echo "[ERROR] Missing required tools: ${MISSING_REQ[*]}"
    [ "${#MISSING_OPT[@]}" -eq 0 ] || echo "[WARN] Missing optional tools: ${MISSING_OPT[*]} (ethtool: Wake-on-LAN, jq: JSON parsing)"

    if [ -n "$PKG_MGR" ]; then
        CMD=$(install_cmd "${PKGS[@]}")
        read -rp "Install missing packages now ($CMD)? [y/N]: " ANSWER
        if [[ "$ANSWER" =~ ^[Yy]$ ]]; then
            [ "$PKG_MGR" != "apt-get" ] || apt-get update || true
            $CMD || echo "[WARN] Package installation failed"
            check_deps
        fi
    else
        echo "[INFO] Please install: ${PKGS[*]}"
    fi

    if [ "${#MISSING_REQ[@]}" -gt 0 ]; then
        echo "[ERROR] Still missing required tools: ${MISSING_REQ[*]}"
        exit 1
    fi
    for cmd in ${MISSING_OPT[@]+"${MISSING_OPT[@]}"}; do
        case "$cmd" in
            ethtool) echo "[WARN] ethtool not installed — Wake-on-LAN cannot be enabled." ;;
            jq) echo "[WARN] jq not installed — the listener will fall back to sed for JSON parsing." ;;
        esac
    done
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

read -rp "Enable Wake-on-LAN? [Y/n]: " WOL_ANSWER
MQTT_WOL=1
if [[ "$WOL_ANSWER" =~ ^[Nn]$ ]]; then MQTT_WOL=0; fi

read -rp "Network interface (empty to auto-detect from default route): " MQTT_IFACE

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
    echo "MQTT_WOL=\"$MQTT_WOL\""
    if [ -n "$MQTT_IFACE" ]; then echo "MQTT_IFACE=\"${MQTT_IFACE//\"/\\\"}\""; fi
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
