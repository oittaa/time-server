#!/bin/sh
# Install and configure GPSD and Chrony on Debian-based systems

set -e

readonly CHRONY_CONF_SERVER="/etc/chrony/conf.d/10-server.conf"
readonly CHRONY_CONF_GPS="/etc/chrony/conf.d/20-gps.conf"

# In addition to the standard NMEA sentences, there might be others like:
# $GPTXT,01,01,02,u-blox ag - www.u-blox.com*50
# $GNTXT,01,01,02,HW UBX-M8030 00080000*60
readonly NMEA_REGEX="^\\\$(BD|GA|GB|GI|GL|GN|GP|GQ)(GGA|RMC|GSA|GSV|VTG|ZDA|TXT)"

# TLS support
readonly CHRONY_CERTS_DIR="/etc/chrony/certs"
readonly CLOUDFLARE_INI=~/.secrets/certbot/cloudflare.ini
readonly CERTBOT_CHRONY_HOOK="/usr/local/bin/certbot-chrony-hook.sh"

APT_NEEDS_UPDATE=1

# --- Helper Functions ---
log_message() {
    printf "[INFO] %s\n" "${1}" >&2
}

debug_message() {
    if [ -z "${DEBUG}" ]; then
        return 0
    fi
    printf "[DEBUG] %s\n" "${1}" >&2
}

error_message() {
    printf "[ERROR] %s\n" "${1}" >&2
    exit 1
}

# shellcheck disable=SC3043 # local is supported in many shells, including bash, ksh, dash, and BusyBox ash.
install_pkg() {
    if ! command -v apt-get >/dev/null 2>&1; then
        error_message "This script requires 'apt-get'."
    fi
    local pkg
    export DEBIAN_FRONTEND=noninteractive
    for pkg in "$@"; do
        if dpkg -s "${pkg}" 2>/dev/null | grep -q -E "^Status: install ok installed$"; then
            debug_message "Package ${pkg} is already installed."
            continue
        fi
        if [ "${APT_NEEDS_UPDATE}" -eq 1 ]; then
            log_message "Updating package lists..."
            apt-get -qq update || error_message "Failed to update package lists."
            APT_NEEDS_UPDATE=0
        fi
        log_message "Installing package: ${pkg}"
        apt-get -y -qq install "${pkg}" || error_message "Failed to install package: ${pkg}"
    done
}

show_help() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Install and configure GPSD and Chrony on Debian-based systems.

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
EOF
}

# --- Core Functions ---
create_certbot_chrony_hook() {
    log_message "Creating ${CERTBOT_CHRONY_HOOK} file..."
    touch "${CERTBOT_CHRONY_HOOK}"
    chmod 755 "${CERTBOT_CHRONY_HOOK}"
    cat <<EOF >"${CERTBOT_CHRONY_HOOK}"
#!/bin/sh
set -e

cp "\${RENEWED_LINEAGE}/fullchain.pem" ${CHRONY_CERTS_DIR}/
cp "\${RENEWED_LINEAGE}/privkey.pem" ${CHRONY_CERTS_DIR}/
chown root:_chrony ${CHRONY_CERTS_DIR}/fullchain.pem
chown root:_chrony ${CHRONY_CERTS_DIR}/privkey.pem
chmod 640 ${CHRONY_CERTS_DIR}/fullchain.pem
chmod 640 ${CHRONY_CERTS_DIR}/privkey.pem
systemctl restart chrony.service
EOF
}

# shellcheck disable=SC3043 # local is supported in many shells, including bash, ksh, dash, and BusyBox ash.
find_and_update_gpsd_device() {
    local found_gps_device=""
    local speed=""
    local pattern
    local potential_device
    local baud_rate
    local timestamp
    local sequence

    log_message "Searching for GPS device..."
    for pattern in /dev/ttyUSB* /dev/ttyACM* /dev/ttyAMA* /dev/ttyS*; do
        for potential_device in ${pattern}; do
            if [ ! -c "${potential_device}" ]; then
                debug_message "Device ${potential_device} does not exist, skipping."
                continue
            fi

            debug_message "Testing ${potential_device}...".
            for baud_rate in 460800 230400 115200 57600 38400 19200 9600 4800; do
                debug_message "Trying baud rate ${baud_rate} on ${potential_device}"
                # If the device responds with valid NMEA data, we assume it's a GPS device.
                if timeout 0.5s stty -F "${potential_device}" "${baud_rate}" raw -echo 2>/dev/null &&
                    timeout 2s head -n 5 "${potential_device}" 2>/dev/null | grep -q -E "${NMEA_REGEX}"; then
                    debug_message "GPS-like NMEA data found on ${potential_device}"
                    found_gps_device="${potential_device}"
                    speed="${baud_rate}"
                    break 3 # Break out of all loops
                fi
            done
            debug_message "No NMEA data or not a GPS device: ${potential_device}"

        done
    done

    if [ -n "${found_gps_device}" ] && [ -n "${speed}" ]; then
        log_message "GPS receiver found: ${found_gps_device}"
        for potential_device in $(cd /dev/ && printf "%s\n" pps*); do
            if [ -c "/dev/${potential_device}" ] && [ -f "/sys/class/pps/${potential_device}/assert" ]; then
                debug_message "Testing PPS device: /dev/${potential_device}..."
                IFS='#' read -r timestamp sequence <"/sys/class/pps/${potential_device}/assert"
                if [ -n "${timestamp}" ] && [ -n "${sequence}" ] && [ "${sequence}" -gt 0 ]; then
                    log_message "PPS device found: /dev/${potential_device}"
                    found_gps_device="${found_gps_device} /dev/${potential_device}"
                    break
                fi
                debug_message "No valid PPS data found on /dev/${potential_device}"
            fi
        done
        sed -i "s|^DEVICES=.*|DEVICES=\"${found_gps_device}\"|" /etc/default/gpsd
        sed -i "s|^GPSD_OPTIONS=.*|GPSD_OPTIONS=\"-n -s ${speed}\"|" /etc/default/gpsd
        log_message "/etc/default/gpsd updated."
        log_message "Restarting GPSD service..."
        systemctl restart gpsd.socket
    else
        log_message "No GPS receiver detected automatically."
    fi
}

chrony_enable_tls() {
    log_message "Enabling TLS support..."
    if [ -z "${DOMAIN}" ] || [ -z "${EMAIL}" ]; then
        error_message "DOMAIN and EMAIL must be set for TLS support (either via environment variables or command-line options)."
    fi
    install_pkg certbot
    if [ ! -e "${CHRONY_CERTS_DIR}" ]; then
        debug_message "Creating ${CHRONY_CERTS_DIR} directory..."
        mkdir -p "${CHRONY_CERTS_DIR}"
        chown root:_chrony "${CHRONY_CERTS_DIR}"
        chmod 750 "${CHRONY_CERTS_DIR}"
    fi
    if [ -f "${CERTBOT_CHRONY_HOOK}" ] && [ -z "${FORCE}" ]; then
        debug_message "Existing ${CERTBOT_CHRONY_HOOK} file..."
    else
        create_certbot_chrony_hook
    fi

    if [ -n "${CLOUDFLARE_TOKEN}" ]; then
        if [ ! -e "${CLOUDFLARE_INI}" ]; then
            log_message "Creating Cloudflare credentials file..."
            mkdir -p "$(dirname "${CLOUDFLARE_INI}")"
            touch "${CLOUDFLARE_INI}"
            chmod 600 "${CLOUDFLARE_INI}"
        fi
        printf "dns_cloudflare_api_token = %s\n" "${CLOUDFLARE_TOKEN}" >"${CLOUDFLARE_INI}"
        install_pkg python3-certbot-dns-cloudflare
        log_message "Obtaining TLS certificate for ${DOMAIN}... using Cloudflare DNS"
        certbot certonly --dns-cloudflare --dns-cloudflare-credentials \
            "${CLOUDFLARE_INI}" --dns-cloudflare-propagation-seconds 30 \
            --email "${EMAIL}" --deploy-hook "${CERTBOT_CHRONY_HOOK}" \
            --agree-tos --non-interactive -d "${DOMAIN}"
    else
        log_message "Obtaining TLS certificate for ${DOMAIN}... using HTTP challenge"
        certbot certonly --standalone --email "${EMAIL}" --deploy-hook \
            "${CERTBOT_CHRONY_HOOK}" --agree-tos --non-interactive -d "${DOMAIN}"
    fi
    if grep -q -F ntsservercert "${CHRONY_CONF_SERVER}"; then
        debug_message "TLS certificate already configured in ${CHRONY_CONF_SERVER}."
    else
        debug_message "Configuring TLS certificate in ${CHRONY_CONF_SERVER}..."
        printf "ntsservercert %s/fullchain.pem\nntsserverkey %s/privkey.pem\n" \
            "${CHRONY_CERTS_DIR}" "${CHRONY_CERTS_DIR}" >>"${CHRONY_CONF_SERVER}"
    fi
    log_message "TLS certificate configured."
    debug_message "You can test the TLS connection with: chronyd -Q -t 3 'server ${DOMAIN} iburst nts maxsamples 1'"
}

# shellcheck disable=SC3043 # local is supported in many shells, including bash, ksh, dash, and BusyBox ash.
main() {
    local current_device=""
    local cmd_output=""
    local total_memory_bytes
    # Parse command-line arguments
    while [ "$#" -gt 0 ]; do
        case "$1" in
        -d | --domain)
            DOMAIN="$2"
            shift 2
            ;;
        -e | --email)
            EMAIL="$2"
            shift 2
            ;;
        -t | --token)
            CLOUDFLARE_TOKEN="$2"
            shift 2
            ;;
        --debug)
            DEBUG="true"
            shift 1
            ;;
        --force)
            FORCE="true"
            shift 1
            ;;
        -h | --help)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            show_help
            exit 1
            ;;
        esac
    done

    case "${DEBUG#}" in
    "1" | [tT][rR][uU][eE]) ;;
    *) unset DEBUG ;;
    esac
    case "${FORCE#}" in
    "1" | [tT][rR][uU][eE]) ;;
    *) unset FORCE ;;
    esac

    debug_message "DOMAIN=${DOMAIN}"
    debug_message "EMAIL=${EMAIL}"
    debug_message "CLOUDFLARE_TOKEN=${CLOUDFLARE_TOKEN:+SET}" # Only indicate if set, not the value itself for security
    debug_message "DEBUG=${DEBUG}"
    debug_message "FORCE=${FORCE}"

    debug_message "##### 1. install and configure gpsd #####"
    install_pkg gpsd
    log_message "Checking if gpsd is active and has a device using gpsctl..."
    if ! systemctl is-active --quiet gpsd.socket; then
        error_message "gpsd service is not active. Please start it with 'systemctl start gpsd.socket' or check its status."
    fi
    debug_message "gpsd service is active."
    if cmd_output=$(timeout 10s gpsctl 2>&1) && [ -n "${cmd_output}" ]; then
        current_device=$(echo "${cmd_output}" | grep -o -m 1 -E '/dev/[a-zA-Z0-9/]+(USB|ACM|AMA|S)[0-9]+' || true)
    else
        debug_message "gpsctl command failed, or produced no output, or gpsd is not connected to a device."
    fi
    debug_message "gpsctl output: ${cmd_output}"
    if [ -n "${current_device}" ]; then
        log_message "gpsd seems to be managing ${current_device} (according to gpsctl)"
    else
        log_message "gpsd not managing any GPS device (according to gpsctl)."
        log_message "Attempting to find a GPS device automatically. This may take some time..."
        find_and_update_gpsd_device
    fi

    debug_message "##### 2. install and configure chrony #####"
    install_pkg chrony
    if [ -f "${CHRONY_CONF_SERVER}" ] && [ -z "${FORCE}" ]; then
        debug_message "Existing ${CHRONY_CONF_SERVER} file..."
    else
        log_message "Creating ${CHRONY_CONF_SERVER} file..."
        touch "${CHRONY_CONF_SERVER}"
        chmod 644 "${CHRONY_CONF_SERVER}"
        printf "allow\nhwtimestamp *\n" >"${CHRONY_CONF_SERVER}"
        total_memory_bytes=$(free -b | grep '^Mem:' | tr -s ' ' | cut -d ' ' -f 2)
        if [ "${total_memory_bytes}" -ge 4294967296 ]; then
            debug_message "System has more than 4GB of RAM, setting clientloglimit to 2GB."
            printf "clientloglimit 2147483648\n" >>"${CHRONY_CONF_SERVER}"
        elif [ "${total_memory_bytes}" -ge 128000000 ]; then
            debug_message "System has less than 4GB of RAM, setting clientloglimit to half of the memory."
            printf "clientloglimit %d\n" $((total_memory_bytes / 2)) >>"${CHRONY_CONF_SERVER}"
        fi
    fi
    if [ -f "${CHRONY_CONF_GPS}" ] && [ -z "${FORCE}" ]; then
        debug_message "Existing ${CHRONY_CONF_GPS} file..."
    else
        log_message "Creating ${CHRONY_CONF_GPS} file..."
        touch "${CHRONY_CONF_GPS}"
        chmod 644 "${CHRONY_CONF_GPS}"
        printf "refclock SHM 0 refid GPS0 poll 0 filter 3 prefer trust\n" >"${CHRONY_CONF_GPS}" # default SHM configuration
        current_device=$(grep -o -E '^DEVICES="[^"]*"' /etc/default/gpsd | tail -n 1 | grep -o -E '/dev/pps[0-9]*' || true)
        if [ -n "${current_device}" ]; then
            debug_message "Configuring SHM for GPS with PPS device: ${current_device}"
            printf "refclock PPS %s poll 0 lock GPS0 refid PPS\n" "${current_device}" >"${CHRONY_CONF_GPS}"
            printf "refclock SHM 0 poll 0 refid GPS0 noselect\n" >>"${CHRONY_CONF_GPS}"
        else
            for current_device in $(cd /dev/ && printf "%s\n" ptp*); do
                if [ -c "/dev/${current_device}" ] && [ -f "/sys/class/ptp/${current_device}/fifo" ]; then
                    debug_message "Testing PHC device: /dev/${current_device}..."
                    cmd_output="$(cut -d ' ' -f 2 /sys/class/ptp/"${current_device}"/fifo)"
                    if [ "${cmd_output}" -gt 0 ]; then
                        log_message "PHC device found: /dev/${current_device}"
                        printf "refclock PHC /dev/%s:extpps poll 0 lock GPS0 refid PPS\n" "${current_device}" >"${CHRONY_CONF_GPS}"
                        printf "refclock SHM 0 poll 0 refid GPS0 noselect\n" >>"${CHRONY_CONF_GPS}"
                        break
                    fi
                    debug_message "No valid PPS data found on /dev/${current_device}"
                fi
            done
        fi
    fi

    if [ -n "${EMAIL}" ] && [ -n "${DOMAIN}" ]; then
        debug_message "##### 3. TLS support for chrony #####"
        chrony_enable_tls
    elif [ -n "${EMAIL}" ] || [ -n "${DOMAIN}" ]; then
        log_message "Warning: For TLS support, both DOMAIN and EMAIL must be provided. TLS will not be configured."
    fi

    log_message "Restarting Chrony service..."
    systemctl restart chrony.service
    log_message "Done! GPSD and Chrony have been installed and configured successfully."
    log_message "To verify GPS synchronization, use: chronyc tracking"
}

main "$@"
