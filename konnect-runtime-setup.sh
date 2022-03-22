#!/usr/bin/env bash

KONNECT_RUNTIME_PORT=8000
KONNECT_RUNTIME_REPO=kong
KONNECT_RUNTIME_IMAGE=kong-gateway:2.8.0.0-alpine

CP_SERVER_NAME=
TP_SERVER_NAME=
KONNECT_HTTP_SESSION_NAME="konnect-session"

globals() {
    KONNECT_DEV=${KONNECT_DEV:-0}
    KONNECT_VERBOSE_MODE=${KONNECT_VERBOSE_MODE:-0}
}

error() {
    echo "Error: " "$@"
    cleanup
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

    # check if jq is installed
    if ! [ -x "$(command -v jq)" ]; then
        error "jq needs to be installed"
    fi
}

help(){
cat << EOF

Usage: konnect-runtime-setup [options ...]

Options:
    -cp             Control plane server name
    -tp             Telemetry server name
    -certificate    Control plane certificate.
    -key            Control plane private key.
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
    -cp)
        CP_SERVER_NAME=$2
        shift
        ;;
    -tp)
        TP_SERVER_NAME=$2
        shift
        ;;
    -certificate)
        CERTIFICATE=$2
        shift
        ;;
    -key)
        PRIVATE_KEY=$2
        shift
        ;;
    -pp)
        KONNECT_RUNTIME_PORT=$2
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

log_debug() {
    if [[ $KONNECT_VERBOSE_MODE -eq 1 ]]; then
        echo "$@"
    fi
}

list_dep_versions() {
    if [[ $KONNECT_VERBOSE_MODE -eq 1 ]]; then
        DOCKER_VER=$(docker --version)
        CURL_VER=$(curl --version)
        JQ_VER=$(jq --version)

        echo "===================="
        echo "Docker: $DOCKER_VER"
        echo "curl: $CURL_VER"
        echo "jq: $JQ_VER"
        echo "===================="
    fi
}

generate_certificates() {
    echo "${CERTIFICATE}" > cluster.crt
    echo "${PRIVATE_KEY}" > cluster.key
}

download_kongee_image() {
    log_debug "=> entering kong gateway download phase"
    
    echo "pulling kong docker image..."

    CMD="docker pull $KONNECT_RUNTIME_REPO/$KONNECT_RUNTIME_IMAGE"
    DOCKER_PULL=$(eval "$CMD")

    if [[ $? -gt 0 ]]; then
        error "failed to pull Kong EE docker image"
    fi
    echo "done"
    log_debug "=> kong gateway download phase completed"
}

run_kong() {
    log_debug "=> entering kong gateway container starting phase"

    echo -n "Your flight number: "
    docker run -d \
        -e "KONG_ROLE=data_plane" \
        -e "KONG_DATABASE=off" \
        -e "KONG_ANONYMOUS_REPORTS=off" \
        -e "KONG_VITALS_TTL_DAYS=723" \
        -e "KONG_CLUSTER_MTLS=pki" \
        -e "KONG_CLUSTER_CONTROL_PLANE=$CP_SERVER_NAME:443" \
        -e "KONG_CLUSTER_SERVER_NAME=$CP_SERVER_NAME" \
        -e "KONG_CLUSTER_TELEMETRY_ENDPOINT=$TP_SERVER_NAME:443" \
        -e "KONG_CLUSTER_TELEMETRY_SERVER_NAME=$TP_SERVER_NAME" \
        -e "KONG_CLUSTER_CERT=/config/cluster.crt" \
        -e "KONG_CLUSTER_CERT_KEY=/config/cluster.key" \
        -e "KONG_LUA_SSL_TRUSTED_CERTIFICATE=system" \
        -e "KONG_LUA_SSL_VERIFY_DEPTH=3" \
        --mount type=bind,source="$(pwd)",target=/config,readonly \
        -p "$KONNECT_RUNTIME_PORT":8000 \
        "$KONNECT_RUNTIME_REPO"/"$KONNECT_RUNTIME_IMAGE"

    if [[ $? -gt 0 ]]; then
        error "failed to start a runtime"
    fi

    log_debug "=> kong gateway container starting phase completed"
}

cleanup() {
    # remove cookie file
    rm -f ./$KONNECT_HTTP_SESSION_NAME
}

main() {
    # globals

    echo "*** Welcome to the rocketship ***"
    echo "Running checks..."
    # run_checks

    # parsing arguments
    # parse_args "$@"

    # list dependency versions if debug mode is enabled
    # list_dep_versions

    # validating required variables
    # check_variables

    # retrieve certificates, keys for runtime
    generate_certificates

    # download kong docker image
    download_kongee_image

    echo "Ready to launch"
    run_kong
    echo "Enjoy the flight!"

    cleanup
}

main "$@"