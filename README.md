# Ubiquiti UNAS Pro Fan Control Service

This is a fan control service using a linear fan curve that is deployed over SSH and runs via systemd.

It polls CPU and HDD temps (via SMART) to compute a fan speed once every minute. It persists between reboots, and hopefully also between updates, and can be quickly re-deployed if not.

## Deployment

- **Deploy remotely:** `./deploy.sh $HOST` to deploy to the UNAS over SSH.
- **Query remotely:** `./query.sh $HOST` to query temperatures and fan speeds.

## Algorithm Parameters

Adjust the `fan_control.sh` parameters to suit your needs. These fan curves, specifically `MAX` and `TGT` temps, are currently set to keep the drives under 40ºC in a warm cabinet (30ºC ambient).

- `CPU_TGT=50`: The target CPU temp, at which fans will run at `MIN_FAN`.
- `CPU_MAX=70`: The max CPU temp, where fans will run at 100%.
- `HDD_TGT=32`: The target HDD temp, at which fans will run at `MIN_FAN`.
- `HDD_MAX=50`: The max HDD temp, where fans will run at 100%.
- `MIN_FAN=39`: The minimum fan speed, 15% of 255 (fan speeds are out of 255).

Fan speed is set linearly between the TGT temp (MIN_FAN fan speed) and MAX temp (100% fan speed). The max temp of all HDDs is used as the HDD temp, and the max computed fan speed between the CPU and HDD speeds is used as the fan speed. Pseudocode and chart for default fan speed below.

```python
CPU_TEMP = max(all CPU temps)
HDD_TEMP = max(all HDD temps)

# compute point linearly between min and max
CPU_FAN = (CPU_TEMP - CPU_MIN) / (CPU_MAX - CPU_MIN)
HDD_FAN = (HDD_TEMP - HDD_MIN) / (HDD_MAX - HDD_MIN)

# clip to range [MIN_FAN, 100%]
FAN_FRAC = max(MIN_FAN, CPU_FAN, HDD_FAN)
FAN_SPEED = 100% * min(FAN_FRAC, 1)
```

![Default fan speed chart](https://github.com/hoxxep/UNAS-Pro-fan-control/blob/main/CHART.png?raw=true)

## Requirements

SSH access to the UNAS Pro, ideally via an SSH key and `~/.ssh/config` host configured.
