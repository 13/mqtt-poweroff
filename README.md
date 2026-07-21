# MQTT Poweroff

A small script and systemd service to power off a Linux machine when it receives an MQTT message containing its MAC address.

On boot, the script publishes a retained "alive" status message to MQTT with the machine's hostname, IP, and MAC address. When the machine shuts down or loses its connection, the broker publishes `alive: false` via an MQTT Last Will, so the status topic always reflects reality.

## Installation

Run the installer:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/13/mqtt-poweroff/main/install.sh)"
```

To install from a specific tag or commit instead of `main`:

```bash
MQTT_POWEROFF_REF=<tag-or-commit> bash -c "$(curl -fsSL https://raw.githubusercontent.com/13/mqtt-poweroff/<tag-or-commit>/install.sh)"
```

Requires `mosquitto-clients`. Installing `jq` is recommended for robust JSON parsing (the script falls back to `sed` without it).

## Configuration

The installer writes `/etc/default/mqtt-poweroff` (mode 600, may contain credentials). Edit it and run `systemctl restart mqtt-poweroff` to apply changes.

| Variable | Default | Description |
|---|---|---|
| `MQTT_BROKER` | `192.168.22.5` | Broker host/IP |
| `MQTT_TOPIC` | `muh/poweroff` | Topic to listen on for poweroff commands |
| `MQTT_USER` / `MQTT_PASS` | *(none)* | Broker credentials |
| `MQTT_QOS` | `1` | QoS for subscribe and publish |
| `MQTT_SECRET` | *(none)* | If set, poweroff payloads must include a matching `"secret"` field |
| `NODE_SUFFIX` | `.muh` | Suffix appended to the hostname in the status topic |
| `STATUS_PREFIX` | `muh/pc` | Status topic prefix (`<prefix>/<hostname><suffix>`) |

## Usage

Power off a machine by publishing its MAC address:

```bash
mosquitto_pub -h 192.168.22.5 -t muh/poweroff -m '{"mac":"aa:bb:cc:dd:ee:ff"}'
```

With a shared secret configured:

```bash
mosquitto_pub -h 192.168.22.5 -t muh/poweroff -m '{"mac":"aa:bb:cc:dd:ee:ff","secret":"<secret>"}'
```

**Never publish to the poweroff topic with the retain flag.** The listener skips retained messages (`mosquitto_sub -R`) as a safety net, but a retained poweroff command would still sit on the broker for any other subscriber.

## Security

Anyone who can publish to the poweroff topic can shut down your machines — MAC addresses are easy to discover on a LAN. Recommended:

- Enable authentication on your broker and set `MQTT_USER` / `MQTT_PASS`.
- Set `MQTT_SECRET` so poweroff commands need a shared secret.
- Restrict topic access with broker ACLs.

## Uninstallation

To uninstall:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/13/mqtt-poweroff/main/uninstall.sh)"
```
