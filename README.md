# Ubiquiti UNAS Pro Fan Control Service

This is a fan control service using a linear fan curve that is deployed over SSH and runs via systemd. It's specifically designed for the [Ubiquiti UNAS Pro](https://ui.com/us/en/integrations/network-storage) to keep the HDDs cooler than the default fan controller.

It polls CPU and HDD temps to compute a fan speed once every minute, aiming to run the fan at the quietest speed that also keeps the HDDs under 40ºC (configurable). It overrides the Ubiquiti quiet/balanced/fast fan presets and persists between reboots and updates.

**Wanted:** ~~UNAS Pro 8~~, UNAS Pro 4, UNAS 4, and UNAS 2 support. Testing and/or modifications to support these devices would be much appreciated!

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

And you can re-enable with:

```bash
systemctl enable fan_control.service
systemctl start fan_control.service
```

</details>

<details>
<summary><strong>Uninstall (Manual)</strong></summary>

```bash
systemctl disable fan_control.service
rm /root/fan_control.sh
rm /etc/systemd/system/fan_control.service
systemctl daemon-reload
```

</details>

## Algorithm Parameters

Adjust the `fan_control.sh` parameters to suit your needs. These fan curves, specifically `MAX` and `TGT` temps, are currently set to keep the drives under 40ºC in a warm cabinet (30ºC ambient).

- `CPU_TGT=50`: The target CPU temp in celcius, at which fans will run at `MIN_FAN`.
- `CPU_MAX=70`: The max CPU temp in celcius, where fans will run at 100%.
- `HDD_TGT=32`: The target HDD temp in celcius, at which fans will run at `MIN_FAN`.
- `HDD_MAX=50`: The max HDD temp in celcius, where fans will run at 100%.
- `MIN_FAN=39`: The minimum fan speed, 15% of 255 (fan speeds are out of 255).

Fan speed is set linearly between the TGT temp (MIN_FAN fan speed) and MAX temp (100% fan speed). The max temp of all HDDs is used as the HDD temp, and the max computed fan speed between the CPU and HDD speeds is used as the fan speed. Pseudocode and fan speed chart below.

![Default fan speed chart](https://github.com/hoxxep/UNAS-Pro-fan-control/blob/main/CHART.png?raw=true)

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

<details>
<summary><strong>Tips for setting parameters</strong></summary>

Typically we leave the MAX variables fixed, and experiment with the TGT to find an ideal fan speed/noise/temperature trade off.

Set the HDD and CPU max temperatures where you would like to run the fans at 100%, where the system is definitely too hot. Then experiment with different HDD and CPU target (TGT) temperatures to where you would like to run the CPU at the minimum fan speed. **A lower TGT temperature will result in higher fan speeds** which should keep the system cooler.

Look out for which temperature is setting the fan speed. The HDD and CPU temps compute two separate fan curves, and the higher computed fan speed is chosen. The systemd service will check temperatures and set fan speeds once every minute.

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
- **Deployment:** Root SSH access to the UNAS Pro via an SSH key and `~/.ssh/config` host [configured](https://goteleport.com/blog/how-to-set-up-ssh-keys/).
