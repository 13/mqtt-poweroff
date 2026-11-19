# MQTT Poweroff

A small script and systemd service to power off (or reboot, or suspend) a Linux machine when it receives an MQTT message containing its MAC address.

On boot, the script publishes a retained "alive" status message to MQTT with the machine's hostname, IP, MAC address and interface. The message is republished every minute (`MQTT_HEARTBEAT`). This keeps the IP current and corrects the status after a network outage. When the machine shuts down or loses its connection, the broker publishes `alive: false` via an MQTT Last Will, so the status topic reflects reality.

## Installation

Run the installer:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/13/mqtt-poweroff/main/install.sh)"
```

To install from a specific tag or commit instead of `main`:

```bash
sudo MQTT_POWEROFF_REF=v1.3.0 bash -c "$(curl -fsSL https://raw.githubusercontent.com/13/mqtt-poweroff/v1.3.0/install.sh)"
```

Running the installer again uses the current configuration as defaults and keeps settings it does not ask about. To update the script and unit without any questions:

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/13/mqtt-poweroff/main/install.sh)" _ --upgrade
```

To install from a local checkout, set `MQTT_POWEROFF_SRC=/path/to/checkout`.

Requires `mosquitto-clients`, `iproute2`, `coreutils`, `curl` and systemd. Optional: `ethtool` for Wake-on-LAN and `jq` for robust JSON parsing (the script falls back to `sed` without it). The installer lists any missing tools, shows the install command for `apt`, `dnf`, `pacman` or `zypper`, and offers to run it.

## Configuration

The installer writes `/etc/default/mqtt-poweroff` (mode 600, may contain credentials). Edit it and run `systemctl restart mqtt-poweroff` to apply changes. Values are double-quoted; escape `\`, `"`, `$` and `` ` `` with a backslash.

| Variable | Default | Description |
|---|---|---|
| `MQTT_BROKER` | `192.168.22.5` | Broker host/IP |
| `MQTT_PORT` | *(client default)* | Broker port, e.g. `8883` for TLS |
| `MQTT_TOPIC` | `muh/poweroff` | Topic to listen on for commands |
| `MQTT_USER` / `MQTT_PASS` | *(none)* | Broker credentials |
| `MQTT_CAFILE` | *(none)* | CA certificate file; enables TLS |
| `MQTT_CERT` / `MQTT_KEY` | *(none)* | Client certificate and key for TLS client authentication |
| `MQTT_QOS` | `1` | QoS for subscribe and publish |
| `MQTT_CLIENT_ID` | `mqttpoff-<mac>` | MQTT client ID |
| `MQTT_SECRET` | *(none)* | Shared secret commands must prove (see [Security](#security)) |
| `MQTT_SECRET_MODE` | `plain` | `plain`: secret in the payload. `hmac`: signed, time-limited payload |
| `MQTT_HMAC_WINDOW` | `60` | Maximum clock difference in seconds for `hmac` payloads |
| `MQTT_ACTIONS` | `poweroff reboot suspend` | Allowed actions (`poweroff`, `reboot`, `suspend`, `hibernate`) |
| `MQTT_MATCH_ALL_MACS` | `0` | `1`: accept the MAC of any physical interface, not only the primary one |
| `MQTT_HEARTBEAT` | `60` | Seconds between alive status republishes (`0` to disable) |
| `MQTT_NET_WAIT` | `30` | Seconds to wait for an IP address at startup |
| `MQTT_DRYRUN` | `0` | `1`: log the action instead of running it |
| `MQTT_HA_DISCOVERY` | `0` | `1`: publish Home Assistant MQTT discovery |
| `MQTT_HA_PREFIX` | `homeassistant` | Home Assistant discovery prefix |
| `NODE_SUFFIX` | `.muh` | Suffix appended to the hostname in the status topic |
| `STATUS_PREFIX` | `muh/pc` | Status topic prefix (`<prefix>/<hostname><suffix>`) |
| `MQTT_WOL` | `1` | Enable Wake-on-LAN (magic packet) on the interface (`0` to disable) |
| `MQTT_IFACE` | *(auto)* | Network interface; defaults to the interface of the default route |

Certificate and key files must be outside `/home` (the service runs with `ProtectHome=yes`), e.g. in `/etc/mqtt-poweroff/`.

## Usage

Power off a machine by publishing its MAC address:

```bash
mosquitto_pub -h 192.168.22.5 -t muh/poweroff -m '{"mac":"aa:bb:cc:dd:ee:ff"}'
```

Other actions (must be listed in `MQTT_ACTIONS`):

```bash
mosquitto_pub -h 192.168.22.5 -t muh/poweroff -m '{"mac":"aa:bb:cc:dd:ee:ff","action":"reboot"}'
```

With `MQTT_SECRET_MODE=plain`:

```bash
mosquitto_pub -h 192.168.22.5 -t muh/poweroff -m '{"mac":"aa:bb:cc:dd:ee:ff","secret":"<secret>"}'
```

With `MQTT_SECRET_MODE=hmac`, sign `<mac>|<ts>|<action>` (MAC lowercase, `ts` in Unix seconds) with HMAC-SHA256:

```bash
mac=aa:bb:cc:dd:ee:ff; action=poweroff; ts=$(date +%s)
hmac=$(printf '%s|%s|%s' "$mac" "$ts" "$action" | openssl dgst -sha256 -hmac "$SECRET" -r | cut -d' ' -f1)
mosquitto_pub -h 192.168.22.5 -t muh/poweroff \
  -m "{\"mac\":\"$mac\",\"action\":\"$action\",\"ts\":$ts,\"hmac\":\"$hmac\"}"
```

The listener rejects payloads older or newer than `MQTT_HMAC_WINDOW` seconds and any timestamp it has already accepted. Both machines need a synchronised clock (NTP).

**Never publish to the command topic with the retain flag.** The listener skips retained messages (`mosquitto_sub -R`) as a safety net, but a retained command would still sit on the broker for any other subscriber.

## Home Assistant

With `MQTT_HA_DISCOVERY=1` each machine appears as a device with a "Status" sensor and one button per allowed action. Buttons are not published when `MQTT_SECRET` is set, because the retained discovery config would expose the secret to every reader. In that case, send commands from a Home Assistant script instead.

## Wake-on-LAN

With `MQTT_WOL=1` the listener runs `ethtool -s <iface> wol g` at startup and again right before the action, because many drivers reset the setting on reboot. The status message includes `"wol": true` when it is active.

- Wake-on-LAN must also be enabled in the BIOS/UEFI.
- Wi-Fi interfaces usually do not support it; use a wired connection.
- Wake a machine with its MAC address, e.g. `wakeonlan aa:bb:cc:dd:ee:ff` or `etherwake -i <iface> aa:bb:cc:dd:ee:ff`.

## Security

Anyone who can publish to the command topic can shut down your machines — MAC addresses are easy to discover on a LAN. Recommended:

- Enable authentication on your broker and set `MQTT_USER` / `MQTT_PASS`. The listener passes them to the mosquitto clients through a private config file in `/run/mqtt-poweroff`, not on the command line.
- Use TLS (`MQTT_PORT=8883`, `MQTT_CAFILE`) so credentials and secrets are not sent in plaintext.
- Set `MQTT_SECRET` with `MQTT_SECRET_MODE=hmac`. A `plain` secret can be replayed by anyone who sees one message.
- Restrict topic access with broker ACLs.

The systemd unit runs with a reduced capability set (`CAP_NET_ADMIN` for Wake-on-LAN, `CAP_SYS_BOOT` for poweroff) and a read-only, sandboxed file system.

## Development

```bash
bats tests          # needs bats, jq and openssl
shellcheck *.sh
```

## Uninstallation

To uninstall (this also removes the retained status and Home Assistant topics from the broker):

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/13/mqtt-poweroff/main/uninstall.sh)"
```
