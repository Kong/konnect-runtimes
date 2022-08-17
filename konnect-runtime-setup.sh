#!/usr/bin/env bash

KONNECT_RUNTIME_PORT=8000
KONNECT_RUNTIME_PORT_SECURE=8443
KONNECT_CERTIFICATE_KEY=
KONNECT_PUBLIC_CERTIFICATE=
KONNECT_RUNTIME_REPO=
KONNECT_RUNTIME_IMAGE=

KONNECT_CP_ENDPOINT=
KONNECT_TP_ENDPOINT=
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
        KONNECT_CERTIFICATE_KEY=$2
        shift
        ;;
    -crt)
        KONNECT_PUBLIC_CERTIFICATE=$2
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
    if [[ -z $KONNECT_CERTIFICATE_KEY ]]; then
        error "Konnect certificate key is missing"
    fi

    if [[ -z $KONNECT_PUBLIC_CERTIFICATE ]]; then
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

http_req() {
    ARGS=$@
    if [[ $KONNECT_VERBOSE_MODE -eq 1 ]]; then
        ARGS=" -vvv $ARGS"
    fi

    curl -L --silent --write-out 'HTTP_STATUS_CODE:%{http_code}' -H "Content-Type: application/json" $ARGS
}

http_req_plain() {
    ARGS=$@
    if [[ $KONNECT_VERBOSE_MODE -eq 1 ]]; then
        ARGS=" -v $ARGS"
    fi

    curl -L --silent --write-out 'HTTP_STATUS_CODE:%{http_code}' -H "Content-Length: 0" $ARGS
}

http_status() {
    echo "$@" | tr -d '\n' | sed -e 's/.*HTTP_STATUS_CODE://'
}

http_res_body() {
    echo "$@" | sed -e 's/HTTP_STATUS_CODE\:.*//g'
}

verify_certificates() {
    log_debug "=> entering certificate verification phase"

    LF=$'\\\x0A'
    echo "${KONNECT_CERTIFICATE_KEY//\\r\\n/}" | sed -e "s/-----BEGIN PRIVATE KEY-----/&${LF}/" -e "s/-----END PRIVATE KEY-----/${LF}&${LF}/" | fold -w 64 > cluster.key
    echo "${KONNECT_PUBLIC_CERTIFICATE//\\r\\n/}" | sed -e "s/-----BEGIN CERTIFICATE-----/&${LF}/" -e "s/-----END CERTIFICATE-----/${LF}&${LF}/" | fold -w 64 > cluster.crt

    KEY_HASH=$(openssl rsa -noout -modulus -in cluster.key | openssl md5)
    CERT_HASH=$(openssl x509 -noout -modulus -in cluster.crt | openssl md5)

    if [[ "$KEY_HASH" != "$CERT_HASH" ]]; then
        rm -f ./cluster.key
        rm -f ./cluster.crt
        error "certificates are not valid"
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
        -e "KONG_ANONYMOUS_REPORTS=off" \
        -e "KONG_VITALS_TTL_DAYS=723" \
        -e "KONG_CLUSTER_MTLS=pki" \
        -e "KONG_CLUSTER_CONTROL_PLANE=$CP_SERVER_NAME:443" \
        -e "KONG_CLUSTER_SERVER_NAME=$CP_SERVER_NAME" \
        -e "KONG_CLUSTER_TELEMETRY_ENDPOINT=$TP_SERVER_NAME:443" \
        -e "KONG_CLUSTER_TELEMETRY_SERVER_NAME=$TP_SERVER_NAME" \
        -e "KONG_CLUSTER_CERT=/config/cluster.crt" \
        -e "KONG_CLUSTER_CERT_KEY=/config/cluster.key" \
        -e "KONG_LUA_SSL_TRUSTED_CERTIFICATE=system,/config/cluster.crt" \
        --mount type=bind,source="$(pwd)",target=/config,readonly \
        -p "$KONNECT_RUNTIME_PORT":8000 \
        -p "$KONNECT_RUNTIME_PORT_SECURE":8443 \
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

    cleanup
}

main "$@"
