#!/bin/bash
# Installer for MQTT Poweroff
#
# Usage:
#   install.sh             interactive install or reconfigure
#   install.sh --upgrade   replace script and unit, keep configuration

set -euo pipefail

# Defaults
BROKER_DEFAULT="192.168.22.5"
TOPIC_POWER_DEFAULT="muh/poweroff"

# Pin to a tag or commit via MQTT_POWEROFF_REF for reproducible installs.
# MQTT_POWEROFF_SRC installs from a local checkout instead of downloading.
REF="${MQTT_POWEROFF_REF:-main}"
BASE_URL="https://raw.githubusercontent.com/13/mqtt-poweroff/$REF"
SRC_DIR="${MQTT_POWEROFF_SRC:-}"

ENV_FILE="/etc/default/mqtt-poweroff"
BIN_PATH="/usr/local/bin/mqtt-poweroff.sh"
UNIT_PATH="/etc/systemd/system/mqtt-poweroff.service"

UPGRADE=0
case "${1:-}" in
    "") ;;
    --upgrade) UPGRADE=1 ;;
    *) echo "Usage: $0 [--upgrade]"; exit 2 ;;
esac

# Check for root
if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] This installer must be run as root."
    echo "Try: sudo bash -c \"\$(curl -fsSL $BASE_URL/install.sh)\""
    exit 1
fi

if [ "$UPGRADE" -eq 1 ] && [ ! -f "$ENV_FILE" ]; then
    echo "[ERROR] No existing installation found ($ENV_FILE missing); run without --upgrade."
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
        od|sha256sum) echo coreutils ;;
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
    for cmd in mosquitto_sub mosquitto_pub ip awk sed grep od sha256sum systemctl; do
        command -v "$cmd" >/dev/null 2>&1 || MISSING_REQ+=("$cmd")
    done
    if [ -z "$SRC_DIR" ]; then
        command -v curl >/dev/null 2>&1 || MISSING_REQ+=(curl)
    fi
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

    if [ -n "$PKG_MGR" ] && [ -t 0 ]; then
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

# Quote a value for both systemd EnvironmentFile and shell parsing: inside
# double quotes both treat \ " $ ` as escapable and keep everything else.
env_quote() {
    local v="$1"
    v="${v//\\/\\\\}"
    v="${v//\"/\\\"}"
    v="${v//\$/\\\$}"
    v="${v//\`/\\\`}"
    printf '"%s"' "$v"
}

# Keys the installer asks for; any other line in an existing file is kept
PROMPTED_KEYS="MQTT_BROKER MQTT_PORT MQTT_TOPIC MQTT_USER MQTT_PASS MQTT_CAFILE MQTT_SECRET MQTT_SECRET_MODE MQTT_WOL MQTT_IFACE"

if [ "$UPGRADE" -eq 0 ]; then
    # Use the current configuration as defaults when reconfiguring
    if [ -r "$ENV_FILE" ]; then
        echo "[INFO] Existing configuration found, using it as defaults"
        set +u
        # shellcheck disable=SC1090
        . "$ENV_FILE"
        set -u
    fi

    ask() {
        local prompt="$1" default="$2" answer
        read -rp "$prompt [${default}]: " answer
        printf '%s' "${answer:-$default}"
    }

    BROKER=$(ask "MQTT broker host/IP" "${MQTT_BROKER:-$BROKER_DEFAULT}")
    PORT=$(ask "MQTT port (empty for default 1883, 8883 with TLS)" "${MQTT_PORT:-}")
    CAFILE=$(ask "CA file for TLS, e.g. /etc/ssl/certs/ca-certificates.crt (empty for no TLS)" "${MQTT_CAFILE:-}")
    TOPIC_POWER=$(ask "MQTT poweroff topic" "${MQTT_TOPIC:-$TOPIC_POWER_DEFAULT}")
    USER_NAME=$(ask "MQTT username (empty for none)" "${MQTT_USER:-}")

    PASS="${MQTT_PASS:-}"
    if [ -n "$USER_NAME" ]; then
        if [ -n "$PASS" ]; then
            read -rsp "MQTT password (empty to keep current): " NEW_PASS
        else
            read -rsp "MQTT password: " NEW_PASS
        fi
        echo
        [ -z "$NEW_PASS" ] || PASS="$NEW_PASS"
    else
        PASS=""
    fi

    SECRET="${MQTT_SECRET:-}"
    if [ -n "$SECRET" ]; then
        read -rsp "Shared secret for poweroff payloads (empty to keep current, '-' to disable): " NEW_SECRET
    else
        read -rsp "Shared secret for poweroff payloads (empty to disable): " NEW_SECRET
    fi
    echo
    case "$NEW_SECRET" in
        "") ;;
        -) SECRET="" ;;
        *) SECRET="$NEW_SECRET" ;;
    esac

    SECRET_MODE="plain"
    if [ -n "$SECRET" ]; then
        SECRET_MODE=$(ask "Secret mode: plain (secret in payload) or hmac (signed, replay-safe)" "${MQTT_SECRET_MODE:-plain}")
        case "$SECRET_MODE" in
            plain|hmac) ;;
            *) echo "[ERROR] Secret mode must be plain or hmac"; exit 1 ;;
        esac
    fi

    WOL_DEFAULT="Y/n"
    [ "${MQTT_WOL:-1}" = "1" ] || WOL_DEFAULT="y/N"
    read -rp "Enable Wake-on-LAN? [$WOL_DEFAULT]: " WOL_ANSWER
    WOL=1
    if [[ "$WOL_ANSWER" =~ ^[Nn]$ ]] || { [ -z "$WOL_ANSWER" ] && [ "$WOL_DEFAULT" = "y/N" ]; }; then
        WOL=0
    fi

    IFACE_NAME=$(ask "Network interface (empty to auto-detect from default route)" "${MQTT_IFACE:-}")

    for v in "$BROKER" "$PORT" "$CAFILE" "$TOPIC_POWER" "$USER_NAME" "$PASS" "$SECRET" "$IFACE_NAME"; do
        if [[ "$v" == *$'\n'* ]]; then echo "[ERROR] Values must not contain newlines"; exit 1; fi
    done
fi

# Temp working dir, cleaned up on any exit
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

fetch() {
    if [ -n "$SRC_DIR" ]; then
        cp "$SRC_DIR/$1" "$WORKDIR/$1"
    else
        curl -fsSL "$BASE_URL/$1" -o "$WORKDIR/$1"
    fi
}

echo "[INFO] Fetching files (${SRC_DIR:-ref: $REF})..."
fetch mqtt-poweroff.sh
fetch mqtt-poweroff.service
bash -n "$WORKDIR/mqtt-poweroff.sh"

# Install script and systemd service
install -m 755 "$WORKDIR/mqtt-poweroff.sh" "$BIN_PATH"
install -m 644 "$WORKDIR/mqtt-poweroff.service" "$UNIT_PATH"
echo "[INFO] Installed $("$BIN_PATH" --version)"

if [ "$UPGRADE" -eq 0 ]; then
    # Write configuration; mode 600 because it may contain credentials.
    # Lines for keys the installer does not ask about are carried over.
    echo "[INFO] Writing $ENV_FILE"
    NEW_ENV="$WORKDIR/env"
    (
        umask 077
        {
            echo "MQTT_BROKER=$(env_quote "$BROKER")"
            [ -z "$PORT" ] || echo "MQTT_PORT=$(env_quote "$PORT")"
            [ -z "$CAFILE" ] || echo "MQTT_CAFILE=$(env_quote "$CAFILE")"
            echo "MQTT_TOPIC=$(env_quote "$TOPIC_POWER")"
            [ -z "$USER_NAME" ] || echo "MQTT_USER=$(env_quote "$USER_NAME")"
            [ -z "$PASS" ] || echo "MQTT_PASS=$(env_quote "$PASS")"
            [ -z "$SECRET" ] || echo "MQTT_SECRET=$(env_quote "$SECRET")"
            [ -z "$SECRET" ] || echo "MQTT_SECRET_MODE=$(env_quote "$SECRET_MODE")"
            echo "MQTT_WOL=\"$WOL\""
            [ -z "$IFACE_NAME" ] || echo "MQTT_IFACE=$(env_quote "$IFACE_NAME")"
            if [ -r "$ENV_FILE" ]; then
                while IFS= read -r line || [ -n "$line" ]; do
                    key="${line%%=*}"
                    key="${key#"${key%%[![:space:]]*}"}"
                    [[ " $PROMPTED_KEYS " == *" $key "* ]] || printf '%s\n' "$line"
                done < "$ENV_FILE"
            fi
        } > "$NEW_ENV"
    )
    install -m 600 "$NEW_ENV" "$ENV_FILE"
else
    echo "[INFO] Keeping configuration in $ENV_FILE"
fi

# Stop and disable old mqtt-status service if it exists
systemctl stop mqtt-status.service 2>/dev/null || true
systemctl disable mqtt-status.service 2>/dev/null || true
rm -f /etc/systemd/system/mqtt-status.service
rm -f /usr/local/bin/mqtt-status.sh

# Enable & (re)start service
systemctl daemon-reload
systemctl enable mqtt-poweroff.service
systemctl restart mqtt-poweroff.service

echo "[DONE] MQTT Poweroff installed and running."
echo "[INFO] Configuration: $ENV_FILE (edit and 'systemctl restart mqtt-poweroff' to apply)"
echo "[INFO] Logs: journalctl -u mqtt-poweroff -f"
