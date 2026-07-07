# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Unreleased: Optional MQTT / Home Assistant bridge.

### Added
- `mqtt_bridge.py` + `mqtt_bridge.service`: an optional, opt-in bridge that
  publishes temperatures, fan duty, and fan RPM to an MQTT broker with Home
  Assistant device-based discovery (HA ≥ 2024.9), including per-drive
  temperature sensors keyed by serial number, availability (LWT), and
  re-discovery on Home Assistant restart. Single-file, stdlib-only python3
  MQTT 3.1.1 client — no apt packages, so it survives UniFi OS firmware
  updates. Inactive unless `/root/mqtt_bridge.conf` exists.
- Fan-curve tuning from Home Assistant: `SYS_TGT`, `HDD_TGT`, `SSD_TGT`,
  `MIN_FAN`, and `MAX_FAN` exposed as number entities. Values are clamped to
  ranges that stay below the fixed `*_MAX` ceilings and persisted to
  `/root/fan_control.conf`.
- `MAX_FAN` parameter in `fan_control.sh`: a fan speed ceiling (default 255)
  the curves ramp to at their MAX temps, for capping fan noise. It caps the
  fans even when overheating; an invalid value (below `MIN_FAN` or above 255)
  fails hot with the full range.
- `fan_control_state.sh`: optional helper sourced by `fan_control.sh`
  providing the conf-override and state-snapshot hooks. Snapshots (an atomic
  JSON file at `/run/fan_control/state.json`, root-only, including drive
  serial numbers) are only written once `/root/mqtt_bridge.conf` exists, so
  non-MQTT installs do no extra work. Overrides are parsed against a strict
  key/integer allowlist — the conf file is never `source`d, so a corrupt file
  can neither crash fan control nor execute code.

### Changed
- Default `SYS_MAX` 75 → 85 and `HDD_MAX` 50 → 55. Wider TGT..MAX spans
  flatten the fan-curve slope (fewer PWM steps per °C), so temperature
  wobbles no longer swing the fans audibly; both ceilings remain within
  SoC throttle and HDD rating limits.
- `fan_control.sh`: defines no-op hook stubs and calls them each iteration;
  installing `fan_control_state.sh` replaces the stubs. Drive serial numbers
  are passed to the state snapshot (console output is unchanged). A missing
  or broken helper file leaves the stubs in place — fan control never depends
  on the MQTT feature.
- `deploy.sh`: also deploys the bridge files and unit (inert without a conf).

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
