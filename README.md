# time-server
Install and configure GPSD and Chrony on Debian-based systems.
Automatically detects and configures connected GPS/GNSS devices and starts responding to NTP client requests.
## How to use?
1. Install your favorite Debian-based distro on a server. Preferably on real hardware, but modern virtualization systems will be good enough for many use cases.
2. Connect your GPS/GNSS receiver to the server. Basically any cheap USB dongle will work as long as it has a decent view of the sky.
3. Run the script.
```
Options:
  -d, --domain <DOMAIN>             Domain name for TLS certificate (e.g., "ntp.example.com").
                                    Overrides the DOMAIN environment variable.
  -e, --email <EMAIL>               Email address for TLS certificate (e.g., "info@example.com").
                                    Overrides the EMAIL environment variable.
  -t, --token <CLOUDFLARE_TOKEN>    Cloudflare API token for DNS challenge.
                                    Overrides the CLOUDFLARE_TOKEN environment variable.
  --debug                           Enable debug messages.
                                    Overrides the DEBUG environment variable (sets to "true").
  --force                           Force re-creation of configuration files and hooks.
                                    Overrides the FORCE environment variable (sets to "true").
                                    By default, existing configuration files are not overwritten.
  -h, --help                        Show this help message and exit.

Environment Variables:
  DOMAIN:                           Domain name for TLS support (e.g., "ntp.example.com").
  EMAIL:                            Email address for TLS support (e.g., "info@example.com").
  CLOUDFLARE_TOKEN:                 Cloudflare API token for DNS challenge.
  DEBUG:                            Set to "1" or "true" to enable debug messages.
  FORCE:                            Set to "1" or "true" to force re-creation of configuration
                                    files and hooks.
```

## I want a TLS certficate for Network Time Security (NTS) protocol.

### Port 80 is reachable from the internet
* Set `DOMAIN` and `EMAIL` variables. Certbot will take care of the rest and the server starts listening to NTS requests.

### Port 80 is **NOT** reachable from the internet
* Set `DOMAIN`, `EMAIL` and `CLOUDFLARE_TOKEN` variables. Certbot will take care of the rest and the server starts listening to NTS requests.

## Pulse Per Second (PPS) / PTP Hardware Clock (PHC)

### Example for Raspberry Pi 5: PPS Connected to GPIO 18 (Physical/Board pin 12)
Run these commands before executing this script
```sh
grep "gpiopin=18" /boot/firmware/config.txt || echo "dtoverlay=pps-gpio,gpiopin=18" | sudo tee -a /boot/firmware/config.txt
```
After reboot `sudo reboot` you can verify that 2 numbers: timestamp, sequence, are increasing. The script searches for these.
```sh
cat /sys/class/pps/pps0/assert
```

### Example for Raspberry Pi Compute Module 5 with IO Board: PPS Connected to SYNC_Out
Run these commands before executing this script
```sh
echo 1 0 | sudo tee /sys/class/ptp/ptp0/pins/SYNC_OUT
echo 0 1 | sudo tee /sys/class/ptp/ptp0/extts_enable
```
You can verify the output consists of 3 numbers: channel number, which is zero in this case, seconds count, nanoseconds count. The script searches for these.
```sh
cat /sys/class/ptp/ptp0/fifo
```
More info about these commands can be found at https://github.com/jclark/rpi-cm4-ptp-guide/blob/main/os.md

**IMPORTANT NOTE**: The 'SYNC_Out' label on the initial CM5 IO Board revision (the first production version) is in the wrong place, on pin 9 of J2. The correct pin is pin 6. The datasheet is correct, the IO Board silkscreen is wrong.

![Image](https://github.com/user-attachments/assets/fddde188-677b-4dd8-abe7-9119dfba71df)
On CM5-PoE-BASE-A from Waveshare the pin is correctly labeled.

## Precision Time Protocol (PTP)?

This script doesn't configure PTP, or Precision Time Protocol. In other words the server offers millisecond to tens of microsecond accuracy, which should be good enough for 99% of use cases. If you need nanosecond-accurate time, you might want to take a look at [Jeff Geerling's Time Pi-project](https://github.com/geerlingguy/time-pi) or [jclark's SatPulse](https://satpulse.net/) which is basically a gpsd replacement.
