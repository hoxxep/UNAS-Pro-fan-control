# MQTT / Home Assistant Bridge (Optional)

The optional `mqtt_bridge` service publishes temperatures and fan speeds to an
MQTT broker (e.g. mosquitto) with [Home Assistant MQTT
discovery](https://www.home-assistant.io/integrations/mqtt/), and lets you tune
the fan curve's target temperatures from Home Assistant.

It is fully opt-in: without `/root/mqtt_bridge.conf` the bridge service stays
inactive and the state-snapshot hooks in `fan_control.sh` are no-ops. Fan
control never depends on the bridge — if MQTT, the broker, or the network is
down (or the bridge crashes), the fan loop keeps running untouched.

## Entities

Device-based discovery (requires Home Assistant ≥ 2024.9). The device appears
under **Settings → Devices & Services → MQTT** as "UNAS Fan Control".

- **Sensors:** max system temperature, max HDD/SSD temperature (only for drive
  classes actually present — no phantom 0°C sensors), one temperature per
  drive (keyed by drive serial number, stable across `/dev` renames), fan
  duty %, and fan RPM per tachometer.
- **Numbers (configuration):** `System target temp` (35–70°C), `HDD target
  temp` (25–45°C), `SSD target temp` (35–62°C), `Minimum fan speed` (5–100%),
  `Maximum fan speed` (30–100%; caps the curve even when overheating, and is
  ignored — full range used — if set below the minimum fan speed).
  These map to `SYS_TGT`/`HDD_TGT`/`SSD_TGT`/`MIN_FAN`/`MAX_FAN` and persist in
  `/root/fan_control.conf`, which `fan_control.sh` re-reads (strict allowlist,
  integers only — never `source`d) every minute. Slider ranges are capped
  below the fixed `*_MAX` ceilings so the curve cannot be inverted from Home
  Assistant; `*_MAX` values stay file-edit only by design.

All entities go `unavailable` if the device stops reporting for 3 minutes —
including when `fan_control.service` is stopped while the bridge is still
running, so a dead fan loop is never mistaken for a healthy one.

> [!NOTE]
> Once the bridge has written `/root/fan_control.conf`, those values override
> the defaults at the top of `fan_control.sh` on every loop. If you later edit
> the script defaults directly, delete `/root/fan_control.conf` (or re-tune
> from Home Assistant) for the edits to take effect.

## Setup

```bash
# 1. Create a broker user (on the broker/Home Assistant side), e.g.:
#    mosquitto_passwd /etc/mosquitto/passwd unas

# 2. On the UNAS, create the config (deploy.sh copies the example over):
cp /root/mqtt_bridge.conf.example /root/mqtt_bridge.conf
chmod 600 /root/mqtt_bridge.conf
vi /root/mqtt_bridge.conf   # set MQTT_HOST/MQTT_USER/MQTT_PASS

# 3. Start the bridge:
systemctl restart mqtt_bridge.service
systemctl status mqtt_bridge.service
```

Running more than one UNAS against the same broker? Set a distinct
`MQTT_DEVICE_ID` on each device — it defaults to the hostname, and two devices
with the same id will fight over one MQTT session and overwrite each other's
entities in Home Assistant.

### Broker security recommendations

- **Restrict the command topics with an ACL.** Any client with publish rights
  to `unas_fan_control/<id>/set/#` can retune the fan curve (within its safe
  ranges — the `*_MAX` ceilings cannot be touched over MQTT, so it cannot
  cause thermal runaway, but it can reduce cooling headroom). With mosquitto:

  ```
  # /etc/mosquitto/acl
  user unas
  topic write unas_fan_control/#
  topic read homeassistant/status

  user homeassistant
  topic readwrite unas_fan_control/#
  topic readwrite homeassistant/#
  ```

- **Credentials are sent unencrypted unless `MQTT_TLS=true`.** Fine on a
  trusted LAN segment; enable TLS if the broker is reachable from guest/IoT
  VLANs or anything you don't fully trust.
- The state topic includes drive serial numbers; scope broker read access
  accordingly, and run the uninstall's `--clear` step to remove retained
  messages from the broker when decommissioning.

## Implementation notes

The bridge is a single-file, stdlib-only python3 daemon (`mqtt_bridge.py`)
speaking MQTT 3.1.1 with username/password auth and optional TLS (certificate
verification always on; point `MQTT_TLS_CA` at a self-signed broker cert). It
deliberately avoids `paho-mqtt`/`mosquitto-clients` because UniFi OS firmware
updates wipe apt-installed packages, while `/root` and `python3` survive.

`fan_control.sh` itself stays MQTT-free: it calls hook functions provided by
`fan_control_state.sh`, which writes an atomic JSON snapshot to
`/run/fan_control/state.json` (root-only, tmpfs) that the bridge reads. The
systemd unit caps the bridge at `MemoryMax=48M` / `CPUQuota=25%` / `Nice=10`,
so even a misbehaving bridge cannot starve the NAS; a memory-cap kill is
auto-restarted cleanly.

Self-check: `python3 mqtt_bridge.py --selftest` runs offline packet/logic
assertions and exits.

## Troubleshooting

```bash
journalctl -u mqtt_bridge -f        # bridge logs (connects, commands, errors)
cat /run/fan_control/state.json     # last snapshot written by fan_control.sh
cat /run/fan_control/jq_error       # only exists if snapshot generation fails
```

## Uninstall

```bash
# 1. Stop the bridge FIRST (a running bridge would republish the discovery
#    config right after it is cleared).
systemctl disable --now mqtt_bridge.service

# 2. Remove the device from Home Assistant (clears retained MQTT messages).
/root/mqtt_bridge.py --clear

# 3. Remove the files.
rm -f /root/mqtt_bridge.py /root/mqtt_bridge.conf /root/mqtt_bridge.conf.example \
      /root/fan_control_state.sh /root/fan_control.conf
rm -f /etc/systemd/system/mqtt_bridge.service
systemctl daemon-reload
```

Removing `/root/fan_control.conf` returns `fan_control.sh` to the defaults
hardcoded at the top of the script.
