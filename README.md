# time-server
Install and configure GPSD and Chrony on Debian-based systems.
Automatically detects and configures connected GPS/GNSS devices and starts responding to NTP client requests.
## How to use?
1. Install your favorite Debian-based distro on a server. Preferably on real hardware, but modern virtualization systems will be good enough for many use cases.
2. Connect your GPS/GNSS receiver to the server. Basically any cheap USB dongle will work as long as it has a decent view of the sky.
3. Run the script.
## I want a TLS certficate for Network Time Security (NTS) protocol.
### Port 80 is reachable from the internet
* Set `DOMAIN` and `EMAIL` variables. Certbot will take care of the rest and the server starts listening to NTS requests.
### Port 80 is **NOT** reachable from the internet
* Set `DOMAIN`, `EMAIL` and `CLOUDFLARE_TOKEN` variables. Certbot will take care of the rest and the server starts listening to NTS requests.
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
  -h, --help                        Show this help message and exit.

Environment Variables:
  DOMAIN:                           Domain name for TLS support (e.g., "ntp.example.com").
  EMAIL:                            Email address for TLS support (e.g., "info@example.com").
  CLOUDFLARE_TOKEN:                 Cloudflare API token for DNS challenge.
  DEBUG:                            Set to "1" or "true" to enable debug messages.

```
This script doesn't configure PTP, or Precision Time Protocol. In other words the server offers millisecond to tens of microsecond accuracy, which should be good enough for 99% of use cases. If you need nanosecond-accurate time, you might want to take a look at [Jeff Geerling's Time Pi-project](https://github.com/geerlingguy/time-pi).
