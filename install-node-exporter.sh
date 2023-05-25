#!/bin/bash

# install node_exporter https://github.com/prometheus/node_exporter

NODE_EXPORTER_PORT="" # empty for random free port
NODE_EXPORTER_ADDRESS="0.0.0.0"

SIMPLE_AUTH_USER_NAME="" # empty for random generated
SIMPLE_AUTH_PASSWORD=""  # if empty will prompt for password

# certificate settings
CERT_SUFFIX=host_name_1
CERT_DAYS=36500 # If not changed then 100 years, you been warned.
ORG_NAME="" # epty for random generated

NODE_EXPORTER_USER="node_exporter"

BIN_DIRECTORY="/usr/local/bin"
APP_DIR="/etc/node-exporter"
SERVICE_CONFIG_PATH="/etc/systemd/system/node_exporter.service"

function user_input() {

        echo && if [ "$EUID" -ne 0 ]; then
                echo " This script should be run as root !" && echo
                exit
        fi

        # help
        if [ "${1}" == '--help' ]; then
                echo && echo "script.sh <username> <password> <host_name> <listening_address> <port> <org> <cert_days_valid>" && echo
                exit
        fi

        echo

        # accept user name
        if [ -n "${1}" ]; then
                SIMPLE_AUTH_USER_NAME="${1}"
                echo " USER_NAME:         $SIMPLE_AUTH_USER_NAME"
        fi

        # accept password
        if [ -n "${2}" ]; then
                SIMPLE_AUTH_PASSWORD="${2}"
                echo " AUTH_PASSWORD:     $SIMPLE_AUTH_PASSWORD"
        fi

        # certificate name suffix
        if [ -n "${3}" ]; then
                CERT_SUFFIX="${3}"
                echo " IDENTITY:          $CERT_SUFFIX"
        fi

        # listening address
        if [ -n "${4}" ]; then
                NODE_EXPORTER_ADDRESS="${4}"
                echo " LISTENING ADDRESS: $NODE_EXPORTER_ADDRESS"
        fi

        # port
        if [ -n "${5}" ]; then
                NODE_EXPORTER_PORT="${5}"
                echo " PORT:              $NODE_EXPORTER_PORT"
        fi

        # org name
        if [ -n "${6}" ]; then
                ORG_NAME="${6}"
                echo " ORGANISATION NAME: $ORG_NAME"
        else
                if [ -z "$ORG_NAME" ]; then
                        ORG_NAME=$(openssl rand -hex 6 | tr -d ':\n')
                        echo " ORGANISATION NAME: $ORG_NAME"
                fi
        fi

        # certificate valid in days
        if [ -n "${7}" ]; then
                CERT_DAYS="${7}"
                echo " CERT VALID DAYS:   $CERT_DAYS"
        fi

        echo
}

function create_user_for_simple_auth() {

        if [[ -z "$SIMPLE_AUTH_USER_NAME" ]]; then prometheus_user_name=$(openssl rand -hex 8 | tr -d ':\n'); else prometheus_user_name="${SIMPLE_AUTH_USER_NAME}"; fi

}

function check_if_already_installed() {

        echo " Checking for leftovers ..." && echo

        if [[ -f "$BIN_DIRECTORY/node_exporter" ]]; then

                INSTALLED_VERSION=$("${BIN_DIRECTORY}"/node_exporter --version | head -n1)

                echo " Node Exporter binary already exist at path: $BIN_DIRECTORY" && echo
                echo " Installed version: $INSTALLED_VERSION" && echo

                exit

        fi

        if [[ -f "${SERVICE_CONFIG_PATH}" ]]; then

                echo " Service config already exist !" && echo
                cat "${SERVICE_CONFIG_PATH}" && echo

                exit

        fi

        if [[ -d "${APP_DIR}" ]]; then

                echo " Config folder exist: ${APP_DIR}" && echo
                ls -lah "${APP_DIR}" && echo

                exit

        fi

}

function system_setup() {
        apt-get update && apt-get -qq install --no-upgrade jq
}

function install_node_exporter_latest() {

        VERSION_CHECK='^v[0-9][0-9.]*$'
        NODE_EXPORTER_VERSION=$(curl -sL https://api.github.com/repos/prometheus/node_exporter/releases/latest | jq -r ".tag_name" || {
                echo ' Failed to obtain latest version from GitHub'
                exit 1
        })

        # Check GitHub response, it should be valid latest version
        if ! [[ "$NODE_EXPORTER_VERSION" =~ $VERSION_CHECK ]]; then
                echo && echo "  Failed to obtain latest binary version from GitHub" && echo
                exit 1
        fi

        NODE_EXPORTER_VERSION=$(echo "${NODE_EXPORTER_VERSION}" | tr -d v)

        echo " Installing Node Exporter version: $NODE_EXPORTER_VERSION" && echo

        wget https://github.com/prometheus/node_exporter/releases/download/v"${NODE_EXPORTER_VERSION}"/node_exporter-"${NODE_EXPORTER_VERSION}".linux-amd64.tar.gz -q --show-progress

        if ! [[ -f "$FILE" ]]; then
                echo " Failed to download node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz" && echo
                exit 1
        fi

        tar -xf node_exporter-"${NODE_EXPORTER_VERSION}".linux-amd64.tar.gz
        cp node_exporter-"${NODE_EXPORTER_VERSION}".linux-amd64/node_exporter "${BIN_DIRECTORY}"/
        chown ${NODE_EXPORTER_USER}:${NODE_EXPORTER_USER} "${BIN_DIRECTORY}"/node_exporter
        rm -rf node_exporter-"${NODE_EXPORTER_VERSION}".linux-amd64*

        INSTALLED_VERSION=$("${BIN_DIRECTORY}"/node_exporter --version | head -n1)

        echo && echo " Installed: $INSTALLED_VERSION" && echo
}

function create_no_shell_user() {

        if ! id -u ${NODE_EXPORTER_USER} >/dev/null 2>&1; then
                echo && echo " Creating no shell user ${NODE_EXPORTER_USER} ..." && echo
                useradd --no-create-home --shell /bin/false ${NODE_EXPORTER_USER}
        else
                echo && echo " User $NODE_EXPORTER_USER already exist, skipping creation" && echo

                return
        fi

        validate_user=$(awk -F':' '{ print $1}' /etc/passwd | grep ${NODE_EXPORTER_USER})

        if ! [[ "$validate_user" =~ ${NODE_EXPORTER_USER} ]]; then
                echo " Failed to create user ${NODE_EXPORTER_USER} :-("
                echo && exit 1
        fi

        echo " Successfully create no shell user ${NODE_EXPORTER_USER}" && echo

}

function generate_self_signed_certificate() {

        mkdir -p "${APP_DIR}" # support configurations and certificates are here

        # https://www.ibm.com/docs/en/ibm-mq/7.5?topic=certificates-distinguished-names
        openssl req -new -newkey rsa:2048 \
                -days "$CERT_DAYS" \
                -nodes \
                -x509 \
                -keyout "${APP_DIR}"/node_exporter_"${CERT_SUFFIX}".key \
                -out "${APP_DIR}"/node_exporter_"${CERT_SUFFIX}".crt \
                -subj "/C=US/ST=Ohio/L=Columbus/O=${ORG_NAME}/CN=${ORG_NAME}"

}

function create_config() {

        REQUIRED_PKG="apache2-utils"

        PKG_OK=$(dpkg -s "$REQUIRED_PKG" | grep -c "install ok installed")

        if ! [ "$PKG_OK" == 1 ]; then

                echo " $REQUIRED_PKG not found. Installing $REQUIRED_PKG ..." && echo
                apt-get -qq --yes install --no-upgrade ${REQUIRED_PKG} 2>/dev/null

        fi

        PKG_OK=$(dpkg -s "$REQUIRED_PKG" | grep -c "install ok installed")

        if ! [ "$PKG_OK" == 1 ]; then
                echo && echo " Failed to install $REQUIRED_PKG :-(" && echo
                exit 1
        else
                echo && echo " $REQUIRED_PKG installed."
        fi

        if [[ -z "$SIMPLE_AUTH_PASSWORD" ]]; then
                echo && echo " Create password for simple authentication:" && echo
                generated_password=$(htpasswd -nBC 10 "" | tr -d ':\n')
        else
                generated_password=$(htpasswd -bnBC 10 "${prometheus_user_name}" "${SIMPLE_AUTH_PASSWORD}" | awk -F ':' '{print $2}' | tr -d ':\n')
        fi

        echo

        cat >"${APP_DIR}"/config.yml <<EOF
tls_server_config:
  cert_file: node_exporter_${CERT_SUFFIX}.crt
  key_file: node_exporter_${CERT_SUFFIX}.key
basic_auth_users:
  "$prometheus_user_name": "$generated_password"
EOF

        chown -R ${NODE_EXPORTER_USER}:${NODE_EXPORTER_USER} "${APP_DIR}"

        ls -lah "${APP_DIR}" && echo

}

function create_systemd_service_config() {

        if [[ -z "$NODE_EXPORTER_PORT" ]]; then

                # Pick up random free port https://superuser.com/a/1293762 by Stefanobaghino
                NODE_EXPORTER_PORT=$(comm -23 <(seq 50000 65000) <(ss -tan | awk '{print $4}' | cut -d':' -f2 | grep "[0-9]\{1,5\}" | sort | uniq) | shuf | head -n1)

        fi

        cat >/etc/systemd/system/node_exporter.service <<EOF
[Unit]
Description=Node Exporter
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=500
StartLimitBurst=5

[Service]
User=${NODE_EXPORTER_USER}
Group=${NODE_EXPORTER_USER}
Type=simple
Restart=on-failure
RestartSec=6s

ExecStart=${BIN_DIRECTORY}/node_exporter --log.level=warn --web.listen-address=${NODE_EXPORTER_ADDRESS}:${NODE_EXPORTER_PORT} --collector.systemd  --web.config.file=${APP_DIR}/config.yml

[Install]
WantedBy=multi-user.target
EOF

        # execute
        systemctl daemon-reload
        systemctl enable node_exporter
        systemctl restart node_exporter

}

function check_success() {

        echo

        echo " ====================================="
        echo "  Checking Node Exporter Installation"
        echo " =====================================" && echo

        read -r -s -p " Enter Prometheus password:" prometheus_login_password && echo

        echo && echo " Prometheus user_name: $prometheus_user_name port: ${NODE_EXPORTER_PORT}" && echo && echo " If you forgot username check here: ${APP_DIR}/config.yml" && echo

        parsed_node_exporter_build_info=$(curl -s -k -u "$prometheus_user_name":"$prometheus_login_password" https://"${NODE_EXPORTER_ADDRESS}":"${NODE_EXPORTER_PORT}"/metrics | grep node_exporter_build_info | tail -n1)

        check_parse_response=$(grep -c node_exporter_build_info <<<"${parsed_node_exporter_build_info}")

        if [[ "${check_parse_response}" == 1 ]]; then

                echo " Node Exporter respond with:" && echo

                echo " ${parsed_node_exporter_build_info}" && echo && return

        fi

        echo " Nothing works as expected, job failed :-(" && echo

        exit 1

}

user_input "${1}" "${2}" "${3}" "${4}" "${5}" "${6}" "${7}"

check_if_already_installed

echo " System setup ..." && echo

system_setup &>/dev/null

create_no_shell_user

install_node_exporter_latest

generate_self_signed_certificate

create_user_for_simple_auth

create_config

create_systemd_service_config

if [ -n "${BASH_VERSION}" ]; then
        check_success # automatically check node_exporter installation
else
        # shell problem, need some work around and more testing
        echo ' Please check installation: curl -s -k -u <user_name>:<password> https://<host>:<port>/metrics' && echo
fi

echo " Success !" && echo # otherwise not
