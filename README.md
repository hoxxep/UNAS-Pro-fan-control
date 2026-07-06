# Ubiquiti UNAS and UNVR Fan Control Service

This is a fan control service using a linear fan curve that is deployed over SSH and runs via systemd. It's specifically designed for the [Ubiquiti UNAS products](https://ui.com/us/en/integrations/network-storage) to keep the HDDs cooler than the default fan controller.

It polls system (CPU and board), HDD, and SSD temps to compute a fan speed once every minute, aiming to run the fans at the quietest speed that also keeps the HDDs under 40ºC (configurable). All temperature sensors and fans are auto-detected, so it adapts from a 2-bay UNAS 2 up to a multi-fan enterprise chassis. It overrides the Ubiquiti quiet/balanced/fast fan presets and persists between reboots and updates.

Supported devices:
- UNAS Pro
- UNAS Pro 4 (confirmed by [@LuaPuglife](https://github.com/hoxxep/UNAS-Pro-fan-control/discussions/9))
- UNAS Pro 8 (confirmed by [@toscano](https://github.com/hoxxep/UNAS-Pro-fan-control/pull/4))
- UNAS 2 (confirmed by [@Jordo-o](https://github.com/hoxxep/UNAS-Pro-fan-control/issues/5))
- UNAS 4 (confirmed by [@sketcheroo86](https://github.com/hoxxep/UNAS-Pro-fan-control/issues/13))
- UNVR Pro (confirmed by [@timeguy147](https://github.com/hoxxep/UNAS-Pro-fan-control/issues/10))
- UNVR (confirmed by [@gormic75](https://github.com/hoxxep/UNAS-Pro-fan-control/issues/8))
- ENAS (confirmed by [@arcaderat22](https://www.reddit.com/user/arcaderat22/) via DMs)
- ENVR (confirmed by [@arcaderat22](https://www.reddit.com/user/arcaderat22/) via DMs)

<details>
<summary><strong>Help confirm device support!</strong></summary>

As of June 2026, all current UNAS and UNVR models are supported. This section is specifically for future devices, thank you!

Please follow this checklist when confirming device support:
- Run the `/root/fan_control.sh` script manually on your UNAS (or `query.sh` remotely), which will output logs with sensor readings. To dump the full sensor and fan topology (chip names, temp labels, fan RPM and PWM channels) — especially useful when confirming a new device — run `sensors.sh`. It's read-only and needn't be installed: `ssh $HOST 'bash -s' < sensors.sh`.
- Confirm the system (CPU and board), HDD, and any SSD/NVMe temperature sensors are reading correctly, and there is a reading for each of your installed drives. The system temperature is the hottest of the CPU die (a `cpu-thermal`/SoC thermal zone) and the board/airflow sensors on the fan-controller chip (an `adt7475` here). Example output below (from a UNAS Pro 8 with 8 HDDs and 2 NVMe cache drives).
    ```
    /sys/class/thermal/thermal_zone0/temp (cpu-thermal) System Temperature: 55°C
    /sys/class/hwmon/hwmon0/temp1_input (adt7475) System Temperature: 44°C
    /sys/class/hwmon/hwmon0/temp2_input (adt7475) System Temperature: 35°C
    /sys/class/hwmon/hwmon0/temp3_input (adt7475) System Temperature: 55°C
    /dev/sda HDD Temperature: 34°C
    /dev/sdb HDD Temperature: 34°C
    /dev/sdc HDD Temperature: 35°C
    /dev/sdd HDD Temperature: 34°C
    /dev/sde HDD Temperature: 36°C
    /dev/sdf HDD Temperature: 34°C
    /dev/sdg HDD Temperature: 35°C
    /dev/sdh HDD Temperature: 35°C
    /dev/nvme0 SSD Temperature: 52°C
    /dev/nvme1 SSD Temperature: 54°C
    Max HDD Temperature: 36°C
    Max SSD Temperature: 54°C
    Max System Temperature: 55°C
    ```
- Confirm the fan speed is being set correctly, and that the tachometers show your fans actually spinning. Note that Unifi OS can also change the fan speed, so occasional mismatches between the set and read fan speeds are acceptable, and `fan_control.sh` can be run multiple times. Example output below (`fan3`/`fan4` are empty headers reading 0 RPM).
    ```
    Min Fan Speed: 39
    HDD Fan Speed: 56
    SSD Fan Speed: 51
    System Fan Speed: 63
    Final Fan Speed (Max): 63
    Fan /sys/class/hwmon/hwmon0/pwm1 (adt7475) set to 63/255, reading 63/255.
    Fan /sys/class/hwmon/hwmon0/pwm2 (adt7475) set to 63/255, reading 63/255.
    Fan /sys/class/hwmon/hwmon0/pwm3 (adt7475) set to 63/255, reading 63/255.
    Tach fan1_input (adt7475): 3170 RPM
    Tach fan2_input (adt7475): 3182 RPM
    Tach fan3_input (adt7475): 0 RPM
    Tach fan4_input (adt7475): 0 RPM
    ```
- When running the systemd service, confirm the HDD temperatures and fan speeds reach your expected range after 30+ minutes of operation.

Please raise a GitHub issue to confirm if this script is working (or not!), or to log what the issue is and we can try to add support if you're willing to help us test. Patches for new temperature sensors or fan devices are also welcome. Thanks!

</details>

## Deployment

### Remote SSH Deployment

- **Deploy remotely:** `./deploy.sh $HOST` to deploy to the UNAS over SSH.
- **Query remotely:** `./query.sh $HOST` to query temperatures and fan speeds.

### Manual Deployment

To be run on the UNAS Pro directly as root.
```bash
# Download latest fan_control.sh and fan_control.service from GitHub to their destinations
wget -O /root/fan_control.sh https://raw.githubusercontent.com/hoxxep/UNAS-Pro-fan-control/refs/heads/main/fan_control.sh
wget -O /etc/systemd/system/fan_control.service https://raw.githubusercontent.com/hoxxep/UNAS-Pro-fan-control/refs/heads/main/fan_control.service

# Make fan_control executable
chmod +x /root/fan_control.sh

# Set up and restart the fan_control service
systemctl daemon-reload
systemctl enable fan_control.service
systemctl restart fan_control.service

# Check fan_control.service is running
systemctl status fan_control.service
```

<details>
<summary><strong>Query temps and fan speed (Manual)</strong></summary>

Simply run the `fan_control.sh` script to query current temperatures and computed fan speed.

```bash
/root/fan_control.sh
```

</details>

<details>
<summary><strong>Temporarily Disable (Manual)</strong></summary>

```bash
# stop service, will still start fan_control again on next reboot
systemctl stop fan_control.service

# stop and disable service, won't start fan_control on next reboot
systemctl disable fan_control.service
```

Stopping the service automatically hands the fans back to the chip's automatic
thermal control (via the unit's `ExecStopPost` hook), so they are never left
pinned at a fixed manual speed. You can re-enable with:

```bash
systemctl enable fan_control.service
systemctl start fan_control.service
```

</details>

<details>
<summary><strong>Restore automatic fan control (Manual)</strong></summary>

While running, `fan_control.sh` puts the fans into manual mode (`pwm*_enable=1`)
and holds them at a fixed speed. If the service is stopped this is undone
automatically, but you can also force the fans back to the chip's own automatic
temperature control at any time:

```bash
/root/fan_control.sh --restore
```

This is safe to run anytime and is the recommended first step if you ever
suspect the fans are stuck (e.g. after a crash, or if the script was deleted
without stopping the service first). `sensors.sh` reports each PWM channel's
`enable` mode, so you can confirm whether a fan is still in manual mode.

</details>

<details>
<summary><strong>Uninstall (Manual)</strong></summary>

```bash
# Stop and disable the service. Its ExecStopPost hook restores automatic fan
# control, so the fans are not left pinned in manual mode.
systemctl disable --now fan_control.service

# Belt-and-braces: explicitly restore automatic fan control before removing the
# script (harmless to run even if the fans are already on automatic control).
/root/fan_control.sh --restore

# Remove the files.
rm /root/fan_control.sh
rm /etc/systemd/system/fan_control.service
systemctl daemon-reload

# Recommended: reboot to guarantee the fans return to UniFi OS control.
reboot
```

We recommend rebooting after removal. The `pwm*_enable` flags are volatile
runtime state (not saved config), so a reboot resets them to their UniFi
OS-controlled defaults, guaranteeing the fans are fully handed back regardless of
what state they were left in.

> [!IMPORTANT]
> Run the restore step (or `systemctl disable --now`) **before** deleting
> `/root/fan_control.sh`. Removing the script while the fans are still in manual
> mode leaves them pinned at their last speed, where they will not spin up as the
> system heats. If that has already happened, just reboot: that resets the fan
> state to the UniFi OS defaults.

</details>

## MQTT / Home Assistant (Optional)

An optional `mqtt_bridge` service publishes temperatures and fan speeds to an
MQTT broker (e.g. mosquitto) with Home Assistant discovery, and lets you tune
the fan curve's target temperatures from Home Assistant. It is fully opt-in
(inactive without `/root/mqtt_bridge.conf`), and fan control never depends on
it. See [MQTT.md](MQTT.md) for setup, entities, and uninstall.

## Algorithm Parameters

Adjust the `fan_control.sh` parameters to suit your needs. These fan curves, specifically `MAX` and `TGT` temps, are currently set to keep the drives under 40ºC in a warm cabinet (30ºC ambient).

- `SYS_TGT=50`: The target system temp (hottest of the CPU die and board sensors) in celcius, at which fans will run at `MIN_FAN`.
- `SYS_MAX=75`: The max system temp in celcius, where fans will run at 100%.
- `HDD_TGT=32`: The target HDD temp in celcius, at which fans will run at `MIN_FAN`.
- `HDD_MAX=50`: The max HDD temp in celcius, where fans will run at 100%.
- `SSD_TGT=50`: The target SSD/NVMe temp in celcius, at which fans will run at `MIN_FAN`.
- `SSD_MAX=70`: The max SSD/NVMe temp in celcius, where fans will run at 100%. Tuned for NVMe drives with little airflow, and safe for SATA SSDs too.
- `MIN_FAN=39`: The minimum fan speed, 15% of 255 (fan speeds are out of 255).

Fan speed is set linearly between the TGT temp (`MIN_FAN` fan speed) and MAX temp (100% fan speed). All sensors and fans are auto-detected: system temperatures come from the SoC thermal zones (the CPU die) and the board sensors on the fan-controller chip, while drives are discovered via SMART and classified as HDD or SSD (both SATA SSDs and NVMe), each with their own fan curve. The hottest sensor within each class sets that class's temp, and the highest computed fan speed across the system, HDD, and SSD curves is used. Every PWM channel on each detected fan-controller chip is then driven (drive and PSU/PMBus chips are skipped, so a PSU/BMC-managed fan is never touched). Pseudocode and fan speed chart below.

![Default fan speed chart](https://github.com/hoxxep/UNAS-Pro-fan-control/blob/main/charts/CHART.png?raw=true)

```python
SYS_TEMP = max(CPU die temps + board sensor temps)
HDD_TEMP = max(all HDD temps)
SSD_TEMP = max(all SSD temps)

# How far each sensor sits between its target and max temp, as 0..1.
# 0 at (or below) the TGT temp, 1 at (or above) the MAX temp.
SYS_RATIO = clip((SYS_TEMP - SYS_TGT) / (SYS_MAX - SYS_TGT), 0, 1)
HDD_RATIO = clip((HDD_TEMP - HDD_TGT) / (HDD_MAX - HDD_TGT), 0, 1)
SSD_RATIO = clip((SSD_TEMP - SSD_TGT) / (SSD_MAX - SSD_TGT), 0, 1)

# The hottest sensor (relative to its own curve) wins.
RATIO = max(SYS_RATIO, HDD_RATIO, SSD_RATIO)

# Map 0..1 onto the fan range: MIN_FAN at the target, 100% at the max.
FAN_SPEED = MIN_FAN + RATIO * (100% - MIN_FAN)
```

<details>
<summary><strong>Tips for setting parameters</strong></summary>

Typically we leave the MAX variables fixed, and experiment with the TGT to find an ideal fan speed/noise/temperature trade off.

Set the HDD and system max temperatures where you would like to run the fans at 100%, where the system is definitely too hot. Then experiment with different HDD and system target (TGT) temperatures for where you would like to run at the minimum fan speed. **A lower TGT temperature will result in higher fan speeds** which should keep the system cooler.

Look out for which temperature is setting the fan speed. The system, HDD, and SSD temps each compute a separate fan curve, and the highest computed fan speed is chosen. The systemd service will check temperatures and set fan speeds once every minute.

#### Remote edit and redeploy
Adjust algorithm parameters in `fan_control.sh` remotely and redeploy remotely with `./deploy.sh $HOST`. Temperatures and computed fan speeds can be queried with `./query.sh $HOST`.

#### Manual edit and redeploy
Adjust algorithm parameters in `/root/fan_control.sh`, and then restart the systemd unit with:

```bash
systemctl daemon-reload
systemctl restart fan_control.service
```

Temperatures and fan speeds can be queried by running `/root/fan_control.sh` directly.

</details>

## Requirements

- **Unifi OS:** UNAS Pro 4.2.6 and beyond.
- **Dependencies:** `smartctl` (smartmontools) to read drive temperatures and `jq` to parse its JSON output. Both are preinstalled on Unifi OS.
- **Deployment:** Root SSH access to the UNAS Pro via an SSH key and `~/.ssh/config` host [configured](https://goteleport.com/blog/how-to-set-up-ssh-keys/).
