# MQTT Poweroff

A small script and systemd service to power off a Linux machine when it receives an MQTT message containing its MAC address.

On boot, the script also publishes an "alive" status message to MQTT with the machine's hostname, IP, and MAC address.

## Installation

Run the installer:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/13/mqtt-poweroff/main/install.sh)"
```
