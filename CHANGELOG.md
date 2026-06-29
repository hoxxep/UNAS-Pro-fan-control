# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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
