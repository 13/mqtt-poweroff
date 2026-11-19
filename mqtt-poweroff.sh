#!/bin/bash
# MQTT Poweroff Listener (MAC matched)

set -euo pipefail

VERSION="1.3.0"

# Test hooks: let the test suite point at fake sysfs/procfs trees
SYS_NET="${MQTT_POWEROFF_SYS_NET:-/sys/class/net}"
HOSTNAME_FILE="${MQTT_POWEROFF_HOSTNAME_FILE:-/proc/sys/kernel/hostname}"

MODE="run"
case "${1:-}" in
    "") ;;
    --cleanup) MODE="cleanup" ;;
    --version) echo "mqtt-poweroff $VERSION"; exit 0 ;;
    *) echo "Usage: $0 [--cleanup|--version]"; exit 2 ;;
esac

# Check dependencies; report all missing tools at once
MISSING=()
for cmd in mosquitto_sub mosquitto_pub ip awk sed grep systemctl od sha256sum; do
    command -v "$cmd" >/dev/null 2>&1 || MISSING+=("$cmd")
done
if [ "${#MISSING[@]}" -gt 0 ]; then
    echo "[ERROR] Missing required tools: ${MISSING[*]}"
    echo "[INFO] Install mosquitto-clients, iproute2, gawk, sed, grep, coreutils and systemd"
    exit 1
fi

HAVE_JQ=0
if command -v jq >/dev/null 2>&1; then
    HAVE_JQ=1
else
    echo "[WARN] jq not installed, falling back to sed for JSON parsing"
fi

# Configuration from environment (see /etc/default/mqtt-poweroff) or defaults
BROKER="${MQTT_BROKER:-192.168.22.5}"
MQTT_PORT="${MQTT_PORT:-}"
TOPIC="${MQTT_TOPIC:-muh/poweroff}"
MQTT_USER="${MQTT_USER:-}"
MQTT_PASS="${MQTT_PASS:-}"
MQTT_QOS="${MQTT_QOS:-1}"
MQTT_CAFILE="${MQTT_CAFILE:-}"
MQTT_CERT="${MQTT_CERT:-}"
MQTT_KEY="${MQTT_KEY:-}"
MQTT_CLIENT_ID="${MQTT_CLIENT_ID:-}"
MQTT_SECRET="${MQTT_SECRET:-}"
MQTT_SECRET_MODE="${MQTT_SECRET_MODE:-plain}"
MQTT_HMAC_WINDOW="${MQTT_HMAC_WINDOW:-60}"
MQTT_ACTIONS="${MQTT_ACTIONS:-poweroff reboot suspend}"
MQTT_MATCH_ALL_MACS="${MQTT_MATCH_ALL_MACS:-0}"
MQTT_HEARTBEAT="${MQTT_HEARTBEAT:-60}"
MQTT_NET_WAIT="${MQTT_NET_WAIT:-30}"
MQTT_DRYRUN="${MQTT_DRYRUN:-0}"
MQTT_HA_DISCOVERY="${MQTT_HA_DISCOVERY:-0}"
MQTT_HA_PREFIX="${MQTT_HA_PREFIX:-homeassistant}"
NODE_SUFFIX="${NODE_SUFFIX:-.muh}"
STATUS_PREFIX="${STATUS_PREFIX:-muh/pc}"
MQTT_WOL="${MQTT_WOL:-1}"
MQTT_IFACE="${MQTT_IFACE:-}"

ALL_ACTIONS="poweroff reboot suspend hibernate"

die() { echo "[ERROR] $*"; exit 1; }

# Validate configuration up front so typos fail loudly instead of later
[[ "$MQTT_QOS" =~ ^[012]$ ]] || die "MQTT_QOS must be 0, 1 or 2"
[[ "$MQTT_HEARTBEAT" =~ ^[0-9]+$ ]] || die "MQTT_HEARTBEAT must be a number of seconds"
[[ "$MQTT_HMAC_WINDOW" =~ ^[0-9]+$ ]] || die "MQTT_HMAC_WINDOW must be a number of seconds"
[[ "$MQTT_NET_WAIT" =~ ^[0-9]+$ ]] || die "MQTT_NET_WAIT must be a number of seconds"
case "$MQTT_SECRET_MODE" in
    plain) ;;
    hmac) [ -n "$MQTT_SECRET" ] || die "MQTT_SECRET_MODE=hmac requires MQTT_SECRET" ;;
    *) die "MQTT_SECRET_MODE must be plain or hmac" ;;
esac
for a in $MQTT_ACTIONS; do
    case " $ALL_ACTIONS " in
        *" $a "*) ;;
        *) die "Unknown action '$a' in MQTT_ACTIONS (allowed: $ALL_ACTIONS)" ;;
    esac
done
for v in "$MQTT_USER" "$MQTT_PASS"; do
    [[ "$v" != *$'\n'* ]] || die "MQTT_USER/MQTT_PASS must not contain newlines"
done

# Connection options shared by every mosquitto_pub/mosquitto_sub call.
# Credentials are not passed here; see setup_credentials.
CONN_ARGS=(-h "$BROKER")
[ -z "$MQTT_PORT" ] || CONN_ARGS+=(-p "$MQTT_PORT")
[ -z "$MQTT_CAFILE" ] || CONN_ARGS+=(--cafile "$MQTT_CAFILE")
[ -z "$MQTT_CERT" ] || CONN_ARGS+=(--cert "$MQTT_CERT")
[ -z "$MQTT_KEY" ] || CONN_ARGS+=(--key "$MQTT_KEY")

# Lowercase hostname; /proc always exists, unlike /etc/hostname or hostname(1)
HOST=""
{ read -r HOST < "$HOSTNAME_FILE"; } 2>/dev/null || true
HOST="${HOST,,}"
[ -n "$HOST" ] || HOST="localhost"
NODE_NAME="${HOST}${NODE_SUFFIX}"
STATUS_TOPIC="$STATUS_PREFIX/$NODE_NAME"

default_iface() {
    ip route show default 2>/dev/null \
        | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i+1); exit}}'
}

# IPv4 address of $IFACE only, so docker0/virbr0 addresses are never reported
iface_ip() {
    [ -n "$IFACE" ] || return 0
    ip -4 -o addr show dev "$IFACE" scope global 2>/dev/null \
        | awk '{split($4, a, "/"); print a[1]; exit}'
}

# Print the normalised MAC of interface $1, or fail if it has no usable one
read_mac() {
    local mac=""
    { read -r mac < "$SYS_NET/$1/address"; } 2>/dev/null || true
    mac="${mac,,}"
    [[ "$mac" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] || return 1
    [ "$mac" != "00:00:00:00:00:00" ] || return 1
    printf '%s\n' "$mac"
}

# Interfaces backed by real hardware have a "device" link in sysfs
list_ifaces() {
    local path name
    for path in "$SYS_NET"/*; do
        name="${path##*/}"
        [ -e "$path" ] && [ "$name" != "lo" ] || continue
        if [ "$1" = "physical" ] && [ ! -e "$path/device" ]; then continue; fi
        printf '%s\n' "$name"
    done
}

# Wait for the interface and its address; the service may start before DHCP
# has finished. Cleanup mode only needs the MAC, so it does not wait.
[ "$MODE" = "run" ] || MQTT_NET_WAIT=1
IFACE=""
IP=""
for ((i = 0; i < MQTT_NET_WAIT; i++)); do
    IFACE="${MQTT_IFACE:-$(default_iface)}"
    IP=$(iface_ip)
    [ -z "$IP" ] || break
    [ "$MODE" = "run" ] || break
    sleep 1
done

LOCAL_MAC=""
if [ -n "$IFACE" ]; then
    LOCAL_MAC=$(read_mac "$IFACE") || {
        echo "[WARN] Interface $IFACE not found or has no MAC"
        IFACE=""
    }
fi
[ -n "$IP" ] || [ "$MODE" != "run" ] || echo "[WARN] No IP address found on ${IFACE:-any interface}, continuing without it"

# Fallback: first physical interface, then any interface with a real MAC
if [ -z "$LOCAL_MAC" ]; then
    echo "[WARN] Falling back to the first interface with a usable MAC"
    for kind in physical any; do
        while read -r name; do
            if LOCAL_MAC=$(read_mac "$name"); then break 2; fi
        done < <(list_ifaces "$kind")
    done
fi
[ -n "$LOCAL_MAC" ] || die "No network interface with a usable MAC address found"

# All MACs this host answers to; with MQTT_MATCH_ALL_MACS=1 every physical
# interface counts, not just the primary one
LOCAL_MACS=" $LOCAL_MAC "
if [ "$MQTT_MATCH_ALL_MACS" = "1" ]; then
    while read -r name; do
        if mac=$(read_mac "$name"); then
            [[ "$LOCAL_MACS" == *" $mac "* ]] || LOCAL_MACS+="$mac "
        fi
    done < <(list_ifaces physical)
fi

# Derived from the MAC so it is unique per host and within the 23 characters
# that strict MQTT 3.1.1 brokers accept
CLIENT_ID="${MQTT_CLIENT_ID:-mqttpoff-${LOCAL_MAC//:/}}"

# Credentials go into a private mosquitto client config file instead of the
# command line, where every local user could read them via ps or /proc.
CLEANUP_DIR=""
setup_credentials() {
    [ -n "$MQTT_USER" ] || return 0
    local dir="${RUNTIME_DIRECTORY:-}"
    if [ -z "$dir" ] || [ ! -d "$dir" ]; then
        dir=$(mktemp -d)
        CLEANUP_DIR="$dir"
    fi
    (
        umask 077
        {
            printf -- '-u %s\n' "$MQTT_USER"
            [ -z "$MQTT_PASS" ] || printf -- '-P %s\n' "$MQTT_PASS"
        } > "$dir/mosquitto_pub"
        cp "$dir/mosquitto_pub" "$dir/mosquitto_sub"
    )
    export XDG_CONFIG_HOME="$dir"
}

# Enable Wake-on-LAN (magic packet) on $IFACE; sets WOL_ACTIVE.
# Many drivers reset this on reboot, so it runs at startup and before poweroff.
WOL_ACTIVE=false
enable_wol() {
    WOL_ACTIVE=false
    [ "$MQTT_WOL" = "1" ] || return 0
    if ! command -v ethtool >/dev/null 2>&1; then
        echo "[WARN] ethtool not installed, cannot enable Wake-on-LAN"
        return 0
    fi
    if [ -z "$IFACE" ]; then
        echo "[WARN] No interface known, cannot enable Wake-on-LAN"
        return 0
    fi

    local info supported current
    info=$(ethtool "$IFACE" 2>/dev/null) || true
    supported=$(awk -F': *' '/Supports Wake-on:/ {print $2; exit}' <<<"$info")
    current=$(awk -F': *' '/^[[:space:]]*Wake-on:/ {print $2; exit}' <<<"$info")

    if [[ "$supported" != *g* ]]; then
        echo "[WARN] $IFACE does not support Wake-on-LAN magic packet"
        return 0
    fi
    if [[ "$current" == *g* ]]; then
        WOL_ACTIVE=true
        return 0
    fi
    if ethtool -s "$IFACE" wol g; then
        echo "[INFO] Wake-on-LAN enabled on $IFACE"
        WOL_ACTIVE=true
    else
        echo "[WARN] Failed to enable Wake-on-LAN on $IFACE"
    fi
}

json_escape() {
    local s="${1//\\/\\\\}"
    printf '%s' "${s//\"/\\\"}"
}

status_msg() {
    printf '{"name":"%s","ip":"%s","mac":"%s","iface":"%s","wol":%s,"alive":%s,"version":"%s"}' \
        "$(json_escape "$NODE_NAME")" "$IP" "$LOCAL_MAC" "$(json_escape "$IFACE")" \
        "$WOL_ACTIVE" "$1" "$VERSION"
}

mqtt_pub() {
    mosquitto_pub "${CONN_ARGS[@]}" -q "$MQTT_QOS" "$@"
}

publish_status() {
    mqtt_pub -t "$STATUS_TOPIC" -r -m "$1" || echo "[WARN] Failed to publish status"
}

# Republish the alive status periodically. mosquitto_sub reconnects on its
# own after a network outage, but by then the broker has already published
# the retained Last Will (alive:false); this puts the status right again and
# keeps the IP current after DHCP changes.
HB_PID=""
start_heartbeat() {
    [ "$MQTT_HEARTBEAT" -gt 0 ] || return 0
    (
        trap - EXIT
        SLEEP_PID=""
        trap '[ -z "$SLEEP_PID" ] || kill "$SLEEP_PID" 2>/dev/null; exit 0' TERM
        while :; do
            sleep "$MQTT_HEARTBEAT" &
            SLEEP_PID=$!
            wait "$SLEEP_PID" || true
            # shellcheck disable=SC2030 # refreshed for this subshell only
            IP=$(iface_ip)
            publish_status "$(status_msg true)"
        done
    ) &
    HB_PID=$!
}

stop_heartbeat() {
    if [ -n "$HB_PID" ]; then
        kill "$HB_PID" 2>/dev/null || true
        wait "$HB_PID" 2>/dev/null || true
        HB_PID=""
    fi
}

# Home Assistant MQTT discovery: a connectivity sensor plus one button per
# allowed action. Buttons are skipped when a secret is configured, because
# the retained discovery config would expose it to every reader.
HA_ID="mqtt_poweroff_${LOCAL_MAC//:/}"
ha_config_topic() { printf '%s/%s/%s/%s/config' "$MQTT_HA_PREFIX" "$1" "$HA_ID" "$2"; }

publish_discovery() {
    local device sensor a name press button
    device=$(printf '{"identifiers":["%s"],"name":"%s","connections":[["mac","%s"]],"model":"mqtt-poweroff","sw_version":"%s"}' \
        "$HA_ID" "$(json_escape "$NODE_NAME")" "$LOCAL_MAC" "$VERSION")
    sensor=$(printf '{"name":"Status","unique_id":"%s_status","state_topic":"%s","value_template":"{{ '"'"'ON'"'"' if value_json.alive else '"'"'OFF'"'"' }}","json_attributes_topic":"%s","device_class":"running","device":%s}' \
        "$HA_ID" "$(json_escape "$STATUS_TOPIC")" "$(json_escape "$STATUS_TOPIC")" "$device")
    mqtt_pub -t "$(ha_config_topic binary_sensor status)" -r -m "$sensor" \
        || echo "[WARN] Failed to publish Home Assistant discovery"

    if [ -n "$MQTT_SECRET" ]; then
        echo "[WARN] MQTT_SECRET is set, not publishing Home Assistant buttons (they would expose the secret)"
    fi
    for a in $ALL_ACTIONS; do
        if [ -n "$MQTT_SECRET" ] || [[ " $MQTT_ACTIONS " != *" $a "* ]]; then
            # Remove buttons that are no longer allowed
            mqtt_pub -t "$(ha_config_topic button "$a")" -r -n || true
            continue
        fi
        name="${a^}"
        press=$(printf '{"mac":"%s","action":"%s"}' "$LOCAL_MAC" "$a")
        button=$(printf '{"name":"%s","unique_id":"%s_%s","command_topic":"%s","payload_press":"%s","qos":%s,"retain":false,"device":%s}' \
            "$name" "$HA_ID" "$a" "$(json_escape "$TOPIC")" "$(json_escape "$press")" "$MQTT_QOS" "$device")
        mqtt_pub -t "$(ha_config_topic button "$a")" -r -m "$button" \
            || echo "[WARN] Failed to publish Home Assistant button $a"
    done
}

extract_field() {
    local field="$1" msg="$2"
    if [ "$HAVE_JQ" -eq 1 ]; then
        jq -r --arg f "$field" \
            'if type == "object" then .[$f] else empty end | select(type == "string" or type == "number")' \
            <<<"$msg" 2>/dev/null || true
    else
        sed -n \
            -e "s/.*\"$field\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p;t" \
            -e "s/.*\"$field\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" <<<"$msg"
    fi
}

# HMAC-SHA256 in pure bash + coreutils. The key only ever travels through
# pipes and builtins, never through a command line visible in ps.
HMAC_IPAD=""
HMAC_OPAD=""
hmac_init() {
    local key_hex byte i
    key_hex=$(printf '%s' "$MQTT_SECRET" | od -An -v -tx1 | tr -d ' \n')
    if [ "${#key_hex}" -gt 128 ]; then
        key_hex=$(printf '%s' "$MQTT_SECRET" | sha256sum | cut -c1-64)
    fi
    while [ "${#key_hex}" -lt 128 ]; do key_hex+="00"; done
    for ((i = 0; i < 128; i += 2)); do
        byte=$((16#${key_hex:i:2}))
        HMAC_IPAD+=$(printf '\\x%02x' $((byte ^ 0x36)))
        HMAC_OPAD+=$(printf '\\x%02x' $((byte ^ 0x5c)))
    done
}

hmac_sha256() {
    local inner inner_esc="" i
    inner=$({ printf '%b' "$HMAC_IPAD"; printf '%s' "$1"; } | sha256sum | cut -c1-64)
    for ((i = 0; i < 64; i += 2)); do inner_esc+="\\x${inner:i:2}"; done
    { printf '%b' "$HMAC_OPAD"; printf '%b' "$inner_esc"; } | sha256sum | cut -c1-64
}

# Check the message's credentials; sets REJECT_REASON and fails if rejected
LAST_TS=0
REJECT_REASON=""
authorize() {
    local msg="$1" mac="$2" action="$3" secret ts sig now age
    case "$MQTT_SECRET_MODE" in
        plain)
            [ -n "$MQTT_SECRET" ] || return 0
            secret=$(extract_field secret "$msg")
            [ "$secret" = "$MQTT_SECRET" ] || { REJECT_REASON="secret mismatch"; return 1; }
            ;;
        hmac)
            ts=$(extract_field ts "$msg")
            sig=$(extract_field hmac "$msg")
            [[ "$ts" =~ ^[0-9]{1,12}$ ]] || { REJECT_REASON="missing or invalid ts"; return 1; }
            ts=$((10#$ts))
            now=$(date +%s)
            age=$((now - ts))
            [ "$age" -ge 0 ] || age=$((-age))
            [ "$age" -le "$MQTT_HMAC_WINDOW" ] || { REJECT_REASON="timestamp outside ${MQTT_HMAC_WINDOW}s window (clock skew?)"; return 1; }
            [ "$ts" -gt "$LAST_TS" ] || { REJECT_REASON="replayed timestamp"; return 1; }
            [ "${sig,,}" = "$(hmac_sha256 "$mac|$ts|$action")" ] || { REJECT_REASON="HMAC mismatch"; return 1; }
            LAST_TS="$ts"
            ;;
    esac
}

run_action() {
    local action="$1"
    echo "[ACTION] MAC match — $action"
    if [ "$MQTT_DRYRUN" = "1" ]; then
        echo "[DRYRUN] Would run: systemctl $action"
        return 0
    fi
    enable_wol
    case "$action" in
        poweroff|reboot) stop_heartbeat ;;
    esac
    publish_status "$(status_msg false)"
    if ! systemctl "$action"; then
        echo "[ERROR] systemctl $action failed"
        publish_status "$(status_msg true)"
        [ -n "$HB_PID" ] || start_heartbeat
    fi
}

handle_message() {
    local msg="$1" mac action
    mac=$(extract_field mac "$msg")
    mac="${mac,,}"
    if [ -z "$mac" ]; then
        # Do not log the payload itself, it may contain the secret
        echo "[WARN] Ignoring payload without \"mac\" field (${#msg} bytes)"
        return 0
    fi
    if [[ ! "$mac" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]]; then
        echo "[WARN] Ignoring payload with malformed MAC"
        return 0
    fi
    if [[ "$LOCAL_MACS" != *" $mac "* ]]; then
        echo "[INFO] MAC $mac mismatch — ignored"
        return 0
    fi

    action=$(extract_field action "$msg")
    action="${action:-poweroff}"
    if [[ ! "$action" =~ ^[a-z]{1,16}$ ]] || [[ " $MQTT_ACTIONS " != *" $action "* ]]; then
        echo "[WARN] Action not allowed — ignored (allowed: $MQTT_ACTIONS)"
        return 0
    fi

    if ! authorize "$msg" "$mac" "$action"; then
        echo "[WARN] Rejected: $REJECT_REASON"
        return 0
    fi

    run_action "$action"
}

STARTED=0
# shellcheck disable=SC2329 # invoked by the EXIT trap
on_exit() {
    stop_heartbeat
    # Publish alive:false when the service stops for any reason; the MQTT
    # Last Will below covers unclean disconnects where this never runs.
    if [ "$STARTED" = "1" ]; then publish_status "$(status_msg false)"; fi
    if [ -n "$CLEANUP_DIR" ]; then rm -rf "$CLEANUP_DIR"; fi
}
trap on_exit EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

setup_credentials

if [ "$MODE" = "cleanup" ]; then
    echo "[INFO] Removing retained status and Home Assistant discovery topics"
    mqtt_pub -t "$STATUS_TOPIC" -r -n || echo "[WARN] Failed to clear $STATUS_TOPIC"
    mqtt_pub -t "$(ha_config_topic binary_sensor status)" -r -n || true
    for a in $ALL_ACTIONS; do
        mqtt_pub -t "$(ha_config_topic button "$a")" -r -n || true
    done
    exit 0
fi

[ "$MQTT_SECRET_MODE" != "hmac" ] || hmac_init
enable_wol

echo "[INFO] mqtt-poweroff $VERSION"
# shellcheck disable=SC2031 # the heartbeat subshell is not started yet
echo "[INFO] Interface: ${IFACE:-unknown}, IP: ${IP:-none}, MAC: $LOCAL_MAC, Wake-on-LAN: $WOL_ACTIVE"
echo "[INFO] Publishing alive status to $STATUS_TOPIC"
STARTED=1
publish_status "$(status_msg true)"
[ "$MQTT_HA_DISCOVERY" != "1" ] || publish_discovery
start_heartbeat

# -R skips retained messages: a retained poweroff command would otherwise
# shut the machine down on every boot. The loop reads from a process
# substitution so it runs in this shell and state changes stay visible.
echo "[INFO] Subscribing to $TOPIC on $BROKER as $CLIENT_ID"
while read -r msg; do
    handle_message "$msg"
done < <(mosquitto_sub "${CONN_ARGS[@]}" \
    -q "$MQTT_QOS" -i "$CLIENT_ID" -R \
    --will-topic "$STATUS_TOPIC" --will-payload "$(status_msg false)" \
    --will-qos "$MQTT_QOS" --will-retain \
    -t "$TOPIC")

echo "[ERROR] Subscription ended (broker unreachable or connection refused)"
exit 1
