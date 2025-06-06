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
    printf "[INFO] %s\n" "${1}"
}

debug_message() {
    if [ -z "${DEBUG}" ] || [ "${DEBUG}" = "0" ] || [ "${DEBUG}" = "false" ]; then
        return 0
    fi
    printf "[DEBUG] %s\n" "${1}"
}

error_message() {
    printf "[ERROR] %s\n" "${1}" >&2
    exit 1
}

install_pkg() {
    if ! command -v apt-get >/dev/null 2>&1; then
        error_message "This script requires 'apt-get'."
    fi
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
  -h, --help                        Show this help message and exit.

Environment Variables:
  DOMAIN:                           Domain name for TLS support (e.g., "ntp.example.com").
  EMAIL:                            Email address for TLS support (e.g., "info@example.com").
  CLOUDFLARE_TOKEN:                 Cloudflare API token for DNS challenge.
  DEBUG:                            Set to "1" or "true" to enable debug messages.

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

    log_message "Searching for GPS device..."
    for pattern in /dev/ttyUSB* /dev/ttyACM* /dev/ttyAMA* /dev/ttyS*; do
        for potential_device in ${pattern}; do
            if [ ! -e "${potential_device}" ]; then
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
    if [ -f "${CERTBOT_CHRONY_HOOK}" ]; then
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

    debug_message "DOMAIN=${DOMAIN}"
    debug_message "EMAIL=${EMAIL}"
    debug_message "CLOUDFLARE_TOKEN=${CLOUDFLARE_TOKEN:+SET}" # Only indicate if set, not the value itself for security
    debug_message "DEBUG=${DEBUG}"

    debug_message "##### 1. install and configure gpsd #####"
    install_pkg gpsd
    log_message "Checking if gpsd is active and has a device using gpsctl..."
    if ! systemctl is-active --quiet gpsd.socket; then
        error_message "gpsd service is not active. Please start it with 'systemctl start gpsd.socket' or check its status."
    fi
    debug_message "gpsd service is active."
    local gps_device_from_gpsctl=""
    local gpsctl_output=""
    if gpsctl_output=$(timeout 10s gpsctl 2>&1) && [ -n "${gpsctl_output}" ]; then
        gps_device_from_gpsctl=$(echo "${gpsctl_output}" | grep -o -m 1 -E '/dev/[a-zA-Z0-9/]+(USB|ACM|AMA|S)[0-9]+')
    else
        debug_message "gpsctl command failed, or produced no output, or gpsd is not connected to a device."
    fi
    debug_message "gpsctl output: ${gpsctl_output}"
    if [ -n "${gps_device_from_gpsctl}" ]; then
        log_message "gpsd seems to be managing ${gps_device_from_gpsctl} (according to gpsctl)"
    else
        log_message "gpsd not managing any device (according to gpsctl)."
        log_message "Attempting to find a GPS device automatically. This may take some time..."
        find_and_update_gpsd_device
    fi

    debug_message "##### 2. install and configure chrony #####"
    install_pkg chrony
    if [ -f "${CHRONY_CONF_SERVER}" ]; then
        debug_message "Existing ${CHRONY_CONF_SERVER} file..."
    else
        log_message "Creating ${CHRONY_CONF_SERVER} file..."
        touch "${CHRONY_CONF_SERVER}"
        chmod 644 "${CHRONY_CONF_SERVER}"
        printf "allow\n" >"${CHRONY_CONF_SERVER}"
    fi
    if [ -f "${CHRONY_CONF_GPS}" ]; then
        debug_message "Existing ${CHRONY_CONF_GPS} file..."
    else
        log_message "Creating ${CHRONY_CONF_GPS} file..."
        touch "${CHRONY_CONF_GPS}"
        chmod 644 "${CHRONY_CONF_GPS}"
        printf "refclock SHM 0 refid GPS0 poll 0 filter 3 prefer trust\nhwtimestamp *\n" >"${CHRONY_CONF_GPS}"
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
