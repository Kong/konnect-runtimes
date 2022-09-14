#!/usr/bin/env bash

KONNECT_RUNTIME_PORT=8000
KONNECT_RUNTIME_PORT_SECURE=8443
KONG_CLUSTER_CERT_KEY=
KONG_CLUSTER_CERT=
KONNECT_RUNTIME_REPO=
KONNECT_RUNTIME_IMAGE=

KONNECT_CP_ENDPOINT=
KONNECT_TP_ENDPOINT=

KONG_CLUSTER_KEY_FILENAME=
KONG_CLUSTER_CERT_FILENAME=

globals() {
    KONNECT_DEV=${KONNECT_DEV:-0}
    KONNECT_VERBOSE_MODE=${KONNECT_VERBOSE_MODE:-0}
}

error() {
    echo "Error: " "$@"
    exit 1
} 

# run dependency checks
run_checks() {
    # check if curl is installed
    if ! [ -x "$(command -v curl)" ]; then
        error "curl needs to be installed"
    fi

    # check if docker is installed
    if ! [ -x "$(command -v docker)" ]; then
        error "docker needs to be installed"
    fi
}

help(){
cat << EOF

Usage: konnect-runtime-setup [options ...]

Options:
    -key            Konnect private key
    -crt            Konnect public key certificate
    -r              Konnect runtime repository url
    -ri             Konnect runtime image name
    -cp             Konnect control plane outlet url
    -te             Konnect telemetry endpoint url
    -pp             runtime port number
    -v              verbose mode
    -h, --help      display help text

EOF
}

# parse command line args
parse_args() {
  while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
    -key)
        KONG_CLUSTER_CERT_KEY=$2
        shift
        ;;
    -crt)
        KONG_CLUSTER_CERT=$2
        shift
        ;;
    -r)
        KONNECT_RUNTIME_REPO=$2
        shift
        ;;
    -ri)
        KONNECT_RUNTIME_IMAGE=$2
        shift
        ;;
    -cp)
        KONNECT_CP_ENDPOINT=$2
        shift
        ;;
    -te)
        KONNECT_TP_ENDPOINT=$2
        shift
        ;;
    -pp)
        KONNECT_RUNTIME_PORT=$2
        shift
        ;;
    -ps)
        KONNECT_RUNTIME_PORT_SECURE=$2
        shift
        ;;
    -v)
        KONNECT_VERBOSE_MODE=1
        ;;
    -h|--help)
        help
        exit 0
        ;;
    esac
    shift
  done
}

# check important variables
check_variables() {
    if [[ -z $KONG_CLUSTER_CERT_KEY ]]; then
        error "Konnect certificate key is missing"
    fi

    if [[ -z $KONG_CLUSTER_CERT ]]; then
        error "Konnect public certificate is missing"
    fi

    if [[ -z $KONNECT_RUNTIME_REPO ]]; then
        error "Konnect runtime repository url is missing"
    fi

    if [[ -z $KONNECT_RUNTIME_IMAGE ]]; then
        error "Konnect runtime image name is missing"
    fi

    if [[ -z $KONNECT_CP_ENDPOINT ]]; then
        error "Konnect control plane outlet url is missing"
    fi

    if [[ -z $KONNECT_TP_ENDPOINT ]]; then
        error "Konnect telemetry outlet url is missing"
    fi

    # check if it is in DEV mode and all required parameters are given
    if [[ $KONNECT_DEV -eq 1 ]]; then
        if [[ -z $KONNECT_DEV_USERNAME ]]; then
            error "username for dev mode is missing, please add it via 'KONNECT_DEV_USERNAME' environment variable."
        fi

        if [[ -z $KONNECT_DEV_PASSWORD ]]; then
            error "password for dev mode is missing, please add it via 'KONNECT_DEV_PASSWORD' environment variable."
        fi
    fi
}

log_debug() {
    if [[ $KONNECT_VERBOSE_MODE -eq 1 ]]; then
        echo "$@"
    fi
}

list_dep_versions() {
    if [[ $KONNECT_VERBOSE_MODE -eq 1 ]]; then
        DOCKER_VER=$(docker --version)
        CURL_VER=$(curl --version)

        echo "===================="
        echo "Docker: $DOCKER_VER"
        echo "curl: $CURL_VER"
        echo "===================="
    fi
}

verify_certificates() {
    log_debug "=> entering certificate verification phase"

    SFX=$(echo "$KONNECT_CP_ENDPOINT" | openssl md5)
    KONG_CLUSTER_KEY_FILENAME="cluster_${SFX}.key"
    KONG_CLUSTER_CERT_FILENAME="cluster_${SFX}.crt"

    printf "%b" "$KONG_CLUSTER_CERT_KEY" > "$KONG_CLUSTER_KEY_FILENAME"
    printf "%b" "$KONG_CLUSTER_CERT" > "$KONG_CLUSTER_CERT_FILENAME"

    KEY_HASH=$(openssl rsa -noout -modulus -in "$KONG_CLUSTER_KEY_FILENAME" | openssl md5)
    CERT_HASH=$(openssl x509 -noout -modulus -in "$KONG_CLUSTER_CERT_FILENAME" | openssl md5)

    if [[ "$KEY_HASH" != "$CERT_HASH" ]]; then
        rm -f "$KONG_CLUSTER_KEY_FILENAME"
        rm -f "$KONG_CLUSTER_CERT_FILENAME"

        error "-key or -crt values are not valid"
    fi

    log_debug "=> certificate generation phase completed"
}

download_kongee_image() {
    log_debug "=> entering kong gateway download phase"
    
    echo "pulling kong docker image..."

    CMD="docker pull $KONNECT_RUNTIME_REPO/$KONNECT_RUNTIME_IMAGE"
    if [[ -n $KONNECT_DOCKER_USER && -n $KONNECT_DOCKER_PASSWORD ]]; then
        CMD="docker login -u $KONNECT_DOCKER_USER -p $KONNECT_DOCKER_PASSWORD $KONNECT_RUNTIME_REPO &> /dev/null && $CMD" 
    fi

    if [[ $? -gt 0 ]]; then
        error "failed to pull Kong EE docker image"
    fi
    echo "done"
    log_debug "=> kong gateway download phase completed"
}

run_kong() {
    log_debug "=> entering kong gateway container starting phase"

    CP_SERVER_NAME=$(echo "$KONNECT_CP_ENDPOINT" | awk -F/ '{print $3}')
    TP_SERVER_NAME=$(echo "$KONNECT_TP_ENDPOINT" | awk -F/ '{print $3}')

    echo -n "Your flight number: "
    docker run -d \
        -e "KONG_ROLE=data_plane" \
        -e "KONG_DATABASE=off" \
        -e "KONG_KONNECT_MODE=on" \
        -e "KONG_VITALS=off" \
        -e "KONG_NGINX_WORKER_PROCESSES=1" \
        -e "KONG_CLUSTER_MTLS=pki" \
        -e "KONG_CLUSTER_CONTROL_PLANE=$CP_SERVER_NAME:443" \
        -e "KONG_CLUSTER_SERVER_NAME=$CP_SERVER_NAME" \
        -e "KONG_CLUSTER_TELEMETRY_ENDPOINT=$TP_SERVER_NAME:443" \
        -e "KONG_CLUSTER_TELEMETRY_SERVER_NAME=$TP_SERVER_NAME" \
        -e "KONG_CLUSTER_CERT=/config/$KONG_CLUSTER_CERT_FILENAME" \
        -e "KONG_CLUSTER_CERT_KEY=/config/$KONG_CLUSTER_KEY_FILENAME" \
        -e "KONG_LUA_SSL_TRUSTED_CERTIFICATE=system,/config/$KONG_CLUSTER_CERT_FILENAME" \
        --mount type=bind,source="$(pwd)",target=/config,readonly \
        -p "$KONNECT_RUNTIME_PORT":8000 \
        -p "$KONNECT_RUNTIME_PORT_SECURE":8443 \
        "$KONNECT_RUNTIME_REPO"/"$KONNECT_RUNTIME_IMAGE"

    if [[ $? -gt 0 ]]; then
        error "failed to start a runtime"
    fi

    log_debug "=> kong gateway container starting phase completed"
}

main() {
    globals

    echo "*** Welcome to the rocketship ***"
    echo "Running checks..."
    run_checks

    # parsing arguments
    parse_args "$@"

    # list dependency versions if debug mode is enabled
    list_dep_versions

    # validating required variables
    check_variables

    # verify validity of the passed in key and certificate
    verify_certificates

    # download kong docker image
    download_kongee_image

    echo "Ready to launch"
    run_kong
    echo "Enjoy the flight!"
}

main "$@"
