# Ubiquiti UNAS and UNVR Fan Control

Retune the fan controller on [Ubiquiti UNAS and UNVR products](https://ui.com/us/en/integrations/network-storage) to keep the HDDs cooler than the stock settings allow.

UniFi OS already has a perfectly good fan controller: `uhwd` runs a PID loop over the CPU, HDD, and NVMe temperatures and computes a fan speed from them. The problem is only its setpoints: stock aims for **83°C CPU** and **48°C HDD**, which is hotter than most people want their drives to run.

So rather than fighting `uhwd` for control of the PWM channels, this project simply **reconfigures it**. `fan_control.py` rewrites the PID setpoints in the UniFi Status Database (`config.fan`) so `uhwd` itself keeps the box cooler:

| Setting | Stock | This project |
| --- | --- | --- |
| CPU setpoint | 83°C | **70°C** |
| HDD setpoint | 48°C | **40°C** |
| NVMe setpoint | 60°C | 60°C (unchanged) |
| HDD gains (Kp / Ki) | -1 / -0.01 | **-2 / -0.02** |
| Idle fan output | 15 | 15 (unchanged) |

Lowering the setpoints does most of the work: the PID ramps the fans up on its own as temperatures rise past the setpoint.

`config.fan` is volatile, so a `fan_control.service` systemd unit re-applies the setpoints on every boot.

> [!NOTE]
> **Upgrading from the old `fan_control.sh`?** Just run the installer below. `fan_control.py` replaces the previous version of this project, which auto-detected sensors and drove the PWM channels directly with its own linear fan curve. That approach fought the UniFi PID controller for ~30 minutes after every start, oscillating the fan speed. It is kept in [`old/`](old/) for reference, but is no longer recommended.
>
> Both versions use the same `fan_control.service` unit name, so installing this one takes over cleanly: the installer stops the old service, hands the fans back to `uhwd`, deletes `/root/fan_control.sh`, and replaces the unit. There is nothing to remove by hand.

## How it works

`uhwd` publishes its live fan config to the Status Database under `config.fan`. Reading it on a stock UNAS Pro gives:

```json
{
  "PID": {
    "cpu": [83, -1, -0.1, 0.0, false, 2, 15],
    "hdd": [48, -1, -0.01, 0.0, false, 2, 15]
  },
  "standby": 15,
  "calc_type": "pid",
  "active_profile": "default"
}
```

Each per-category PID array is:

```
[ setpoint_C, Kp, Ki, Kd, bool, target_group, MIN_FLOOR ]
      ^0                                          ^6
```

- **Index 0 — setpoint (°C).** The temperature the PID tries to hold, and the value most worth changing: lower it and the fans work harder, sooner.
- **Indices 1 and 2 — Kp and Ki.** The proportional and integral gains, i.e. how hard the loop reacts to the current error and to accumulated error over time. This project doubles the HDD pair (to `-2` and `-0.02`) so the drives reach the much lower setpoint in reasonable time; the CPU gains are left stock, since the CPU already responds fast.
- **Index 6 — minimum floor.** A per-category *minimum* fan output, **not** a max cap. Leave it at `15` for a quiet idle; raising it only makes the box louder while idle without helping under load. (The stock "cooling" preset is just this value set to `100`, i.e. fans pinned at full.)
- **`standby`** is the global idle/standby fan output, also left at `15`.

The floor and `standby` are both "what the fans do when there's no heat to shift", and stock keeps them equal, so this project drives them from a single `--idle` setting rather than exposing two knobs.

For reference, the stock UniFi presets only differ in the HDD setpoint (and, for cooling, the floor):

| Preset | CPU setpoint | HDD setpoint | HDD Kp / Ki | NVMe setpoint | Floor |
| --- | --- | --- | --- | --- | --- |
| Quiet | 83°C | 53°C | -1 / -0.01 | 60ºC | 15 |
| Default | 83°C | 48°C | -1 / -0.01 | 60ºC | 15 |
| Cooling | 83°C | 43°C | -1 / -0.01 | 60ºC | 100 (fans pinned full) |
| **This project** | **70°C** | **40°C** | **-2 / -0.02** | **60ºC** | **15** |

`fan_control.py` edits **only** the live top-level config, never `fan["profiles"][...]`. Those are the factory Quiet/Balanced/Cooling presets.

## Requirements

- A UNAS, ENAS, UNVR, or ENVR running a UniFi OS build that does fan control in software via `uhwd` (UNAS Pro 4.2.6 and beyond).
- Root SSH access to the device.
- `python3` and the `ustd` Python package, both preinstalled on UniFi OS.

## Install

SSH into the device as root and run the installer.
```bash
curl -fsSL https://raw.githubusercontent.com/hoxxep/UNAS-Pro-fan-control/refs/heads/main/install.sh | bash
```

You will be presented with the target temperatures to configure, no value will use our defaults, which are lower than the default and are a balance between fan noise and lower drive temps for longevity. 

```
Setpoints -- press enter to accept the recommended value.
                               current   new
  Target CPU temperature in C       83   [70]:
  Target HDD temperature in C       48   [40]:
  Target NVMe temperature in C      60   [60]:
  Minimum fan speed, 0-100          15   [15]:
```

The "current" column is read live out of `config.fan`, so on a re-run it shows what you last installed.

The installer downloads `fan_control.py` to `/root`, checks your setpoints against it read-only before committing to them, and writes a `fan_control.service` systemd unit with them baked into its `ExecStart`. The unit is a one-shot: it applies the setpoints, restarts `uhwd` to pick them up, and exits (staying "active" so `systemctl status` shows whether it ran this boot). It is ordered after `uhwd.service` and retries if `config.fan` isn't published yet.

<details>
<summary><strong>Manual install, without the installer</strong></summary>

The installer only copies two files into place and enables a unit, so you can do it by hand. The `fan_control.service` in this repo is the same unit with no setpoint arguments, i.e. it uses the built-in defaults.

From a checkout of this repo:

```bash
scp fan_control.py $HOST:/root/fan_control.py
scp fan_control.service $HOST:/etc/systemd/system/fan_control.service

ssh $HOST -t '\
    systemctl daemon-reload && \
    systemctl enable --now fan_control.service && \
    systemctl status fan_control.service'
```

Or entirely on the device, as root:

```bash
wget -O /root/fan_control.py https://raw.githubusercontent.com/hoxxep/UNAS-Pro-fan-control/refs/heads/main/fan_control.py
wget -O /etc/systemd/system/fan_control.service https://raw.githubusercontent.com/hoxxep/UNAS-Pro-fan-control/refs/heads/main/fan_control.service

systemctl daemon-reload
systemctl enable --now fan_control.service
systemctl status fan_control.service
```

To use setpoints other than the defaults, add the flags to the unit's `ExecStart` yourself:

```ini
ExecStart=/usr/bin/python3 /root/fan_control.py --write --hdd 40
```

Then `systemctl daemon-reload && systemctl restart fan_control.service`.

</details>

### Check it worked

Run the script with no arguments for a read-only dump of the live PID config:

```bash
ssh $HOST 'python3 /root/fan_control.py'
```

The `cpu` and `hdd` setpoints (index 0 of each array) should read back whatever you installed. To see the resulting temperatures and fan RPM, use `sensors.sh`, it's read-only and needn't be installed:

```bash
ssh $HOST 'bash -s' < sensors.sh
```

Wait at least 60 minutes after install before judging the temperatures and fan speeds; the PID algorithm takes time to settle.

## Tuning

Re-run the installer. It rewrites the unit and re-applies immediately, so there's nothing else to do:

```bash
curl -fsSL https://raw.githubusercontent.com/hoxxep/UNAS-Pro-fan-control/refs/heads/main/install.sh | bash -s -- --hdd 40
```

The settings, all of which `install.sh` prompts for and passes straight through to `fan_control.py`:

- `--cpu 70`: target CPU temperature in °C.
- `--hdd 40`: target HDD temperature in °C. **This is the one to tune.** Lower it for cooler drives and louder fans; raise it for a quieter box.
- `--nvme 60`: target NVMe temperature in °C, on the models that have it. Left at stock; these drives idle well below it.
- `--idle 15`: fan output with no heat to shift — the per-category PID floor and the global standby output together. Raising it makes the box louder at idle without improving loaded temperatures; leave it alone unless you want more constant baseline airflow.

To try a change without installing anything, `fan_control.py` is read-only unless given `--write`:

```bash
ssh $HOST 'python3 /root/fan_control.py --hdd 40'          # show what would change
ssh $HOST 'python3 /root/fan_control.py --hdd 40 --write'  # apply until the next reboot
```

## Caveats

- **`config.fan` is volatile.** `uhwd` re-initialises it to stock defaults on a full reboot, which is exactly why the systemd unit exists. A plain `systemctl restart uhwd` keeps the retuned values.
- **Changing the fan preset in the UniFi UI reverts these values**, because `uhwd` re-derives the live config from the newly selected profile. Re-run `systemctl restart fan_control.service` afterwards, or reboot.
- **The UniFi UI will still show whichever preset is selected.** There is no indication in the UI that the setpoints have been changed underneath it.

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/hoxxep/UNAS-Pro-fan-control/refs/heads/main/uninstall.sh | bash
```

This disables the service, restores the stock setpoints, removes both files, and restarts `uhwd` with **no reboot needed**. The stock values are read back out of the factory profile stored in `config.fan`, so whichever preset you have selected in the UniFi UI is exactly what you get back.

<details>
<summary><strong>Manual uninstall, without the script</strong></summary>

```bash
# Stop and disable the service so the setpoints are not re-applied at boot.
systemctl disable --now fan_control.service

# Restore the stock setpoints, before removing the script that does it.
python3 /root/fan_control.py --restore --write

# Remove the files.
rm /root/fan_control.py /etc/systemd/system/fan_control.service
systemctl daemon-reload
```

If you skip the `--restore` step, reboot or switch the fan preset in the UniFi UI to get the stock setpoints back.

</details>

## Device support

The current `uhwd`-based approach has been developed and tested on the **UNAS Pro**. It relies only on `uhwd`'s `config.fan`, which is common across UniFi OS, so it is expected to work across the UNAS and UNVR range. Note that the drive temps may take around 30-60 minutes to settle with the PID controller, including after boot.

<details>
<summary><strong>Help confirm device support!</strong></summary>

Reports for issues with this fan control service are very welcome.

- Run `python3 /root/fan_control.py` (read-only) and confirm `config.fan` is found and has the `PID.cpu` / `PID.hdd` shape described above. The script refuses to write if the PID arrays aren't the expected shape. If you hit that error, or your device has extra or differently-named PID categories, please paste the output into a GitHub issue.
- Apply the setpoints, then run `sensors.sh` to dump the full sensor and fan topology (chip names, temp labels, fan RPM and PWM channels). It's read-only and needn't be installed: `ssh $HOST 'bash -s' < sensors.sh`.
- Confirm the fans respond: the tachometers should show your fans spinning faster than before, and the HDD temperatures should settle lower after 30+ minutes of operation.

</details>
