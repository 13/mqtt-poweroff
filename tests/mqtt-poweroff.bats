#!/usr/bin/env bats
# Tests for mqtt-poweroff.sh. External tools (mosquitto, ip, ethtool,
# systemctl) are replaced by stubs that log their arguments; sysfs and the
# hostname come from a fake tree.

SCRIPT="$BATS_TEST_DIRNAME/../mqtt-poweroff.sh"

setup() {
    T="$BATS_TEST_TMPDIR"
    export T
    mkdir -p "$T/bin" "$T/net"

    # Real tools the script needs, linked into a private PATH so single
    # tools (jq) can be removed per test
    for tool in bash awk sed grep tr cut od sha256sum date mktemp rm cp sleep cat seq openssl jq tail head chmod touch; do
        ln -s "$(command -v "$tool")" "$T/bin/$tool"
    done

    stub mosquitto_pub 'printf "%s\n" "$*" >> "$T/pub.log"'
    stub systemctl 'printf "%s\n" "$*" >> "$T/systemctl.log"'
    # Record arguments and the credentials file, then replay the messages
    stub mosquitto_sub '
printf "%s\n" "$*" > "$T/sub.args"
if [ -n "${XDG_CONFIG_HOME:-}" ] && [ -f "$XDG_CONFIG_HOME/mosquitto_sub" ]; then
    cp "$XDG_CONFIG_HOME/mosquitto_sub" "$T/sub.cfg"
fi
[ ! -f "$T/messages" ] || cat "$T/messages"'
    stub ip '
case "$*" in
    "route show default") echo "default via 10.0.0.1 dev eth0 proto dhcp metric 100" ;;
    *"dev eth0"*) echo "2: eth0    inet 10.0.0.5/24 brd 10.0.0.255 scope global dynamic eth0" ;;
    *"dev docker0"*) echo "3: docker0    inet 172.17.0.1/16 scope global docker0" ;;
esac'
    stub ethtool '
if [ "$1" = "-s" ]; then printf "%s\n" "$*" >> "$T/ethtool.log"; touch "$T/wol_on"; exit 0; fi
echo "Settings for $1:"
echo "	Supports Wake-on: pumbg"
if [ -f "$T/wol_on" ]; then echo "	Wake-on: g"; else echo "	Wake-on: d"; fi'

    # docker0 sorts first and is virtual; eth0 and eth1 are physical
    fake_iface docker0 02:42:ac:11:00:01
    fake_iface eth0 AA:BB:CC:DD:EE:01 physical
    fake_iface eth1 aa:bb:cc:dd:ee:02 physical
    fake_iface lo 00:00:00:00:00:00
    echo "TestHost" > "$T/hostname"

    export PATH="$T/bin"
    export MQTT_POWEROFF_SYS_NET="$T/net"
    export MQTT_POWEROFF_HOSTNAME_FILE="$T/hostname"
    export MQTT_BROKER=broker.test MQTT_HEARTBEAT=0 MQTT_NET_WAIT=2
    unset RUNTIME_DIRECTORY XDG_CONFIG_HOME
}

stub() {
    printf '#!%s\n%s\n' "$(command -v bash)" "$2" > "$T/bin/$1"
    chmod +x "$T/bin/$1"
}

fake_iface() {
    mkdir -p "$T/net/$1"
    echo "$2" > "$T/net/$1/address"
    if [ "${3:-}" = physical ]; then mkdir -p "$T/net/$1/device"; fi
}

messages() { printf '%s\n' "$@" > "$T/messages"; }

hmac() {
    printf '%s' "$2" | openssl dgst -sha256 -hmac "$1" -r | cut -d' ' -f1
}

@test "--version prints the version" {
    run "$SCRIPT" --version
    [ "$status" -eq 0 ]
    [[ "$output" == "mqtt-poweroff "* ]]
}

@test "matching MAC powers off" {
    messages '{"mac":"AA:BB:CC:DD:EE:01"}'
    run "$SCRIPT"
    [ "$(cat "$T/systemctl.log")" = "poweroff" ]
}

@test "other MAC is ignored" {
    messages '{"mac":"11:22:33:44:55:66"}'
    run "$SCRIPT"
    [ ! -f "$T/systemctl.log" ]
    [[ "$output" == *"mismatch"* ]]
}

@test "payload without mac is ignored and not logged" {
    messages '{"secret":"topsecret"}' 'not json'
    run "$SCRIPT"
    [ ! -f "$T/systemctl.log" ]
    [[ "$output" != *"topsecret"* ]]
}

@test "IP and MAC come from the default-route interface, not docker0" {
    run "$SCRIPT"
    grep -q '"ip":"10.0.0.5","mac":"aa:bb:cc:dd:ee:01","iface":"eth0"' "$T/pub.log"
    grep -q -- '-t muh/pc/testhost.muh' "$T/pub.log"
}

@test "missing hostname file does not crash" {
    export MQTT_POWEROFF_HOSTNAME_FILE="$T/nope"
    run "$SCRIPT"
    grep -q -- '-t muh/pc/localhost.muh' "$T/pub.log"
}

@test "fallback MAC skips virtual interfaces" {
    export MQTT_IFACE=missing0
    run "$SCRIPT"
    grep -q '"mac":"aa:bb:cc:dd:ee:01"' "$T/pub.log"
}

@test "no usable MAC fails with an error" {
    rm -rf "$T/net/eth0" "$T/net/eth1" "$T/net/docker0"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"No network interface with a usable MAC"* ]]
}

@test "client ID is derived from the MAC and fits 23 characters" {
    run "$SCRIPT"
    grep -q -- '-i mqttpoff-aabbccddee01 ' "$T/sub.args"
}

@test "password is not on the command line" {
    export MQTT_USER=alice MQTT_PASS='s3cr et$"'
    run "$SCRIPT"
    ! grep -q 's3cr' "$T/sub.args"
    ! grep -q 's3cr' "$T/pub.log"
    [ "$(cat "$T/sub.cfg")" = $'-u alice\n-P s3cr et$"' ]
}

@test "TLS and port options are passed through" {
    export MQTT_PORT=8883 MQTT_CAFILE=/etc/ca.pem MQTT_CERT=/etc/c.pem MQTT_KEY=/etc/k.pem
    run "$SCRIPT"
    grep -q -- '-h broker.test -p 8883 --cafile /etc/ca.pem --cert /etc/c.pem --key /etc/k.pem' "$T/sub.args"
}

@test "plain secret: wrong secret rejected, right secret accepted" {
    export MQTT_SECRET=hunter2
    messages '{"mac":"aa:bb:cc:dd:ee:01","secret":"wrong"}' '{"mac":"aa:bb:cc:dd:ee:01"}'
    run "$SCRIPT"
    [ ! -f "$T/systemctl.log" ]
    messages '{"mac":"aa:bb:cc:dd:ee:01","secret":"hunter2"}'
    run "$SCRIPT"
    [ "$(cat "$T/systemctl.log")" = "poweroff" ]
}

@test "hmac: valid signature accepted, replay and stale rejected" {
    export MQTT_SECRET=hunter2 MQTT_SECRET_MODE=hmac
    ts=$(date +%s)
    sig=$(hmac hunter2 "aa:bb:cc:dd:ee:01|$ts|reboot")
    old=$((ts - 600))
    oldsig=$(hmac hunter2 "aa:bb:cc:dd:ee:01|$old|reboot")
    messages \
        "{\"mac\":\"aa:bb:cc:dd:ee:01\",\"action\":\"reboot\",\"ts\":$ts,\"hmac\":\"$sig\"}" \
        "{\"mac\":\"aa:bb:cc:dd:ee:01\",\"action\":\"reboot\",\"ts\":$ts,\"hmac\":\"$sig\"}" \
        "{\"mac\":\"aa:bb:cc:dd:ee:01\",\"action\":\"reboot\",\"ts\":$old,\"hmac\":\"$oldsig\"}" \
        "{\"mac\":\"aa:bb:cc:dd:ee:01\",\"action\":\"poweroff\",\"ts\":$((ts + 1)),\"hmac\":\"$sig\"}"
    run "$SCRIPT"
    [ "$(cat "$T/systemctl.log")" = "reboot" ]
    [[ "$output" == *"replayed timestamp"* ]]
    [[ "$output" == *"outside 60s window"* ]]
    [[ "$output" == *"HMAC mismatch"* ]]
}

@test "hmac: keys longer than 64 bytes match openssl" {
    long=$(printf 'k%.0s' {1..100})
    export MQTT_SECRET="$long" MQTT_SECRET_MODE=hmac
    ts=$(date +%s)
    messages "{\"mac\":\"aa:bb:cc:dd:ee:01\",\"ts\":\"$ts\",\"hmac\":\"$(hmac "$long" "aa:bb:cc:dd:ee:01|$ts|poweroff")\"}"
    run "$SCRIPT"
    [ "$(cat "$T/systemctl.log")" = "poweroff" ]
}

@test "hmac mode without a secret is a config error" {
    export MQTT_SECRET_MODE=hmac
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"requires MQTT_SECRET"* ]]
}

@test "actions: allowed ones run, others are ignored" {
    export MQTT_ACTIONS="poweroff suspend"
    messages '{"mac":"aa:bb:cc:dd:ee:01","action":"reboot"}' \
             '{"mac":"aa:bb:cc:dd:ee:01","action":"rm -rf"}' \
             '{"mac":"aa:bb:cc:dd:ee:01","action":"suspend"}'
    run "$SCRIPT"
    [ "$(cat "$T/systemctl.log")" = "suspend" ]
}

@test "unknown action in MQTT_ACTIONS is a config error" {
    export MQTT_ACTIONS="poweroff format"
    run "$SCRIPT"
    [ "$status" -eq 1 ]
}

@test "second NIC only matches with MQTT_MATCH_ALL_MACS=1" {
    messages '{"mac":"aa:bb:cc:dd:ee:02"}'
    run "$SCRIPT"
    [ ! -f "$T/systemctl.log" ]
    export MQTT_MATCH_ALL_MACS=1
    run "$SCRIPT"
    [ "$(cat "$T/systemctl.log")" = "poweroff" ]
}

@test "dry run does not call systemctl" {
    export MQTT_DRYRUN=1
    messages '{"mac":"aa:bb:cc:dd:ee:01"}'
    run "$SCRIPT"
    [ ! -f "$T/systemctl.log" ]
    [[ "$output" == *"[DRYRUN] Would run: systemctl poweroff"* ]]
}

@test "Wake-on-LAN is enabled and the final status reports it" {
    messages '{"mac":"aa:bb:cc:dd:ee:01"}'
    run "$SCRIPT"
    grep -q -- '-s eth0 wol g' "$T/ethtool.log"
    tail -n1 "$T/pub.log" | grep -q '"wol":true,"alive":false'
}

@test "final status after WoL turned on late is not stale" {
    # Fail the first enable so startup reports wol:false, then succeed
    stub ethtool '
if [ "$1" = "-s" ]; then
    if [ -f "$T/tried" ]; then touch "$T/wol_on"; exit 0; fi
    touch "$T/tried"; exit 1
fi
echo "	Supports Wake-on: g"
if [ -f "$T/wol_on" ]; then echo "	Wake-on: g"; else echo "	Wake-on: d"; fi'
    messages '{"mac":"aa:bb:cc:dd:ee:01"}'
    run "$SCRIPT"
    head -n1 "$T/pub.log" | grep -q '"wol":false,"alive":true'
    tail -n1 "$T/pub.log" | grep -q '"wol":true,"alive":false'
}

@test "Last Will carries alive:false and retain" {
    run "$SCRIPT"
    grep -q -- '--will-topic muh/pc/testhost.muh --will-payload {.*"alive":false' "$T/sub.args"
    grep -q -- '--will-retain' "$T/sub.args"
    grep -q -- ' -R ' "$T/sub.args"
}

@test "heartbeat republishes alive status" {
    export MQTT_HEARTBEAT=1
    stub mosquitto_sub 'sleep 2.5'
    run "$SCRIPT"
    [ "$(grep -c '"alive":true' "$T/pub.log")" -ge 3 ]
    tail -n1 "$T/pub.log" | grep -q '"alive":false'
}

@test "SIGTERM publishes alive:false" {
    stub mosquitto_sub 'sleep 30'
    "$SCRIPT" > "$T/out" 2>&1 &
    pid=$!
    for _ in $(seq 1 50); do grep -q '"alive":true' "$T/pub.log" 2>/dev/null && break; sleep 0.1; done
    kill -TERM "$pid"
    wait "$pid" || true
    tail -n1 "$T/pub.log" | grep -q '"alive":false'
}

@test "sed fallback without jq parses strings and numbers" {
    rm "$T/bin/jq"
    export MQTT_SECRET=hunter2 MQTT_SECRET_MODE=hmac
    ts=$(date +%s)
    messages "{\"mac\": \"AA:BB:CC:DD:EE:01\", \"ts\": $ts, \"hmac\": \"$(hmac hunter2 "aa:bb:cc:dd:ee:01|$ts|poweroff")\"}"
    run "$SCRIPT"
    [[ "$output" == *"jq not installed"* ]]
    [ "$(cat "$T/systemctl.log")" = "poweroff" ]
}

@test "Home Assistant discovery publishes sensor and buttons" {
    export MQTT_HA_DISCOVERY=1 MQTT_ACTIONS="poweroff reboot"
    run "$SCRIPT"
    grep -q -- '-t homeassistant/binary_sensor/mqtt_poweroff_aabbccddee01/status/config -r -m ' "$T/pub.log"
    grep -q -- 'button/mqtt_poweroff_aabbccddee01/poweroff/config -r -m .*"payload_press":"{\\"mac\\":\\"aa:bb:cc:dd:ee:01\\",\\"action\\":\\"poweroff\\"}"' "$T/pub.log"
    grep -q -- 'button/mqtt_poweroff_aabbccddee01/suspend/config -r -n' "$T/pub.log"
}

@test "Home Assistant buttons are not published with a secret" {
    export MQTT_HA_DISCOVERY=1 MQTT_SECRET=hunter2
    run "$SCRIPT"
    ! grep -q 'hunter2' "$T/pub.log"
    grep -q -- 'button/mqtt_poweroff_aabbccddee01/poweroff/config -r -n' "$T/pub.log"
}

@test "--cleanup clears retained topics without subscribing" {
    run "$SCRIPT" --cleanup
    [ "$status" -eq 0 ]
    grep -q -- '-t muh/pc/testhost.muh -r -n' "$T/pub.log"
    grep -q -- 'binary_sensor/mqtt_poweroff_aabbccddee01/status/config -r -n' "$T/pub.log"
    [ ! -f "$T/sub.args" ]
}

@test "subscription ending exits non-zero" {
    run "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Subscription ended"* ]]
}
