# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## 2026-07-29: Retune UniFi OS's own fan controller instead of driving the fans.

A rewrite of the approach. UniFi OS already runs a perfectly good PID fan
controller in `uhwd`; the problem was only its setpoints (83°C CPU, 48°C HDD).
Rather than fighting it for control of the PWM channels, this version simply
reconfigures it, which removes the ~30 minutes of fan oscillation that followed
every start of the old script.

### Added
- `fan_control.py`: rewrites `uhwd`'s PID setpoints in the UniFi Status Database
  (`config.fan`). Defaults to 70°C CPU and 40°C HDD, with the HDD gains doubled
  (`Kp`/`Ki` of `-2`/`-0.02`) so the drives reach the much lower setpoint in
  reasonable time. It is read-only unless given `--write`, and refuses to write
  at all if the PID arrays are not the expected shape.
- `--restore` puts the stock setpoints back, read out of the factory profile
  stored in `config.fan` (which this project never writes to), so whichever
  preset is selected in the UniFi UI is exactly what you get back. No reboot
  needed.
- `install.sh`: downloads the script, prompts for each setpoint against a
  "current" column read live out of `config.fan`, dry-runs them before
  committing, and writes a `fan_control.service` unit with them baked into its
  `ExecStart`. Re-run it to retune. Non-interactive when passed any option, so
  it works piped from `curl`.
- `uninstall.sh`: disables the service, restores the stock setpoints, removes
  both files, and restarts `uhwd`, again with no reboot needed.
- `sensors.sh` now dumps each SMART drive's temperature alongside the hwmon and
  thermal-zone data, so one read-only run shows both what `uhwd`'s PID loops
  track and the fan speeds that result. `install.sh` now puts it in `/root` too
  (and `uninstall.sh` removes it), since the installer runs on the device, where
  there is no checkout to pipe it from.

### Changed
- The systemd unit is now a one-shot: it applies the setpoints, restarts `uhwd`
  to pick them up, and exits, rather than looping once a minute forever. It
  stays "active" (`RemainAfterExit`) so `systemctl status` shows whether it ran
  this boot, and retries if `config.fan` has not been published yet. It exists
  only because `config.fan` is volatile: `uhwd` re-initialises it to the stock
  defaults on every full reboot.
- Nothing in this project writes `pwm*` or `pwm*_enable` any more, so the fans
  can no longer be left pinned at a fixed speed.
- The old sensor-detection, fan-curve, and PWM-driving implementation is kept in
  [`old/`](old/) for reference, but is no longer recommended.

### Upgrading
- Both versions use the same `fan_control.service` unit name, so run
  `install.sh` as normal. It stops the old service, hands the fans back to
  `uhwd`, deletes `/root/fan_control.sh`, and replaces the unit. There is
  nothing to remove by hand.

### Dependencies
- `smartctl` and `jq` are no longer needed to control the fans, only to read
  drive temperatures in `sensors.sh`. Now requires `python3` and the `ustd`
  Python package, both preinstalled on UniFi OS.

## 2026-06-25: Overhaul to support all UNAS devices correctly.

### Added
- Distinct HDD and SSD fan curves. Drives are classified as HDD or SSD and the
  hottest of each class drives its own curve, so SSDs can run to a higher target
  and max temperature (`SSD_TGT`/`SSD_MAX`) than spinning disks.
- NVMe drive temperature support, read from the NVMe SMART health log.
- `sensors.sh`: a read-only discovery tool that dumps every hwmon chip, thermal
  zone, fan tachometer, and PWM channel (with chip names and labels), to map
  sensors and fans correctly across the device range. Run it via
  `ssh $HOST 'bash -s' < sensors.sh` without installing it.
- Fan tachometer (RPM) readings are now logged next to each PWM, making it
  visible whether the fans are actually spinning.
- `fan_control.sh --restore` hands the fans back to the chip's automatic thermal
  control (undoing manual mode), so they are never left pinned at a fixed speed.
- The systemd unit now runs `--restore` via `ExecStopPost`, so stopping,
  disabling, crashing, or uninstalling the service always returns the fans to
  automatic control rather than leaving them stuck in manual mode.

### Changed
- System temperatures (CPU die + board) are now auto-discovered from
  `/sys/class/thermal/thermal_zone*` and the hwmon board/fan-controller chips,
  instead of a hardcoded `hwmon0/temp1..3` plus `thermal_zone0`. The true CPU
  die (`cpu-thermal`) is now read correctly, rather than a board sensor being
  mislabeled as the CPU.
- Renamed `CPU_TGT`/`CPU_MAX` to `SYS_TGT`/`SYS_MAX`: it is now a unified
  "system" curve over the hottest of the CPU die and board sensors. The 
  `SYS_MAX` value has been increased by 5ºC to 75ºC.
- Fans are now auto-discovered. Every PWM channel on each fan-controller chip
  (an hwmon chip exposing both `pwm*` outputs and `fan*_input` tachometers) is
  driven and switched to manual mode, instead of a hardcoded `pwm1..4` on
  `hwmon0`. This supports devices with more or fewer fans (e.g. a 5-fan
  ENVR/EUNAS) and skips drive (`nvme`/`drivetemp`) and PSU/PMBus chips, so a
  PSU/BMC-managed fan is never hijacked.
- Drives are now auto-discovered via a single `smartctl --scan-open` instead of
  a hardcoded `sda`–`sdh` list, so any number of drives (and non-`sd*` devices
  such as NVMe) are picked up automatically.
- Drive temperatures are parsed from `smartctl`'s JSON output, reading known
  temperature fields in priority order (`temperature.current`, then the NVMe
  health log, then ATA SMART attributes 194/190 or named temperature attributes)
  instead of `awk`-matching a single attribute line. This is more reliable
  across drive types and firmware.

### Dependencies
- Now requires `jq` (in addition to `smartctl`) to parse SMART JSON output. Both
  are preinstalled on Unifi OS.
