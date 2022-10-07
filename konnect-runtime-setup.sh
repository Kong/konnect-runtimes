#!/usr/bin/env bash

KONNECT_RUNTIME_PORT=8000
KONNECT_API_URL=
KONNECT_USERNAME=
KONNECT_PASSWORD=
KONNECT_RUNTIME_REPO=
KONNECT_RUNTIME_IMAGE=

KONNECT_CP_ID=
KONNECT_CP_ENDPOINT=
KONNECT_CP_SERVER_NAME=
KONNECT_TP_ENDPOINT=
KONNECT_TP_SERVER_NAME=
KONNECT_HTTP_SESSION_NAME="konnect-session"
KONNECT_DP_CERTIFICATE_DIRECTORY="kong_dataplane_certificates"

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
    -api            Konnect API
    -u              Konnect username
    -p              Konnect user password
    -r              Konnect runtime repository url
    -ri             Konnect runtime image name
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
    -api)
        KONNECT_API_URL=$2
        shift
        ;;
    -u)
        KONNECT_USERNAME=$2
        shift
        ;;
    -p)
        KONNECT_PASSWORD=$2
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

# check important variables
check_variables() {
    if [[ -z $KONNECT_API_URL ]]; then
        error "Konnect API URL is missing"
    fi
    
    if [[ -z $KONNECT_USERNAME ]]; then
        error "Konnect username is missing"
    fi

    if  [[ -z $KONNECT_PASSWORD ]]; then
        error "Konnect password is missing"
    fi

    if [[ -z $KONNECT_RUNTIME_REPO ]]; then
        error "Konnect runtime repository url is missing"
    fi

    if [[ -z $KONNECT_RUNTIME_IMAGE ]]; then
        error "Konnect runtime image name is missing"
    fi
    
    # temporary fix for multiplatform support
    if [[ $KONNECT_RUNTIME_IMAGE -eq "kong-gateway:3.0.0.0" ]]; then
        KONNECT_RUNTIME_IMAGE="kong-gateway:3.0.0.0-apline"
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
        JQ_VER=$(jq --version)

        echo "===================="
        echo "Docker: $DOCKER_VER"
        echo "curl: $CURL_VER"
        echo "jq: $JQ_VER"
        echo "===================="
    fi
}

http_req() {
    ARGS=$@
    if [[ $KONNECT_VERBOSE_MODE -eq 1 ]]; then
        ARGS=" -v $ARGS"
    fi

    curl -L --silent --write-out 'HTTP_STATUS_CODE:%{http_code}' -H "Content-Type: application/json" $ARGS
}

http_status() {
    echo "$@" | tr -d '\n' | sed -e 's/.*HTTP_STATUS_CODE://'
}

http_res_body() {
    echo "$@" | sed -e 's/HTTP_STATUS_CODE\:.*//g'
}

# login to the Konnect and acquire the session
login() {
    log_debug "=> entering login phase"

    ARGS="--cookie-jar ./$KONNECT_HTTP_SESSION_NAME -X POST -d {\"username\":\"$KONNECT_USERNAME\",\"password\":\"$KONNECT_PASSWORD\"} --url $KONNECT_API_URL/api/auth"
    if [[ $KONNECT_DEV -eq 1 ]]; then
        ARGS="-u $KONNECT_DEV_USERNAME:$KONNECT_DEV_PASSWORD $ARGS"
    fi

    RES=$(http_req "$ARGS")
    STATUS=$(http_status "$RES")

    if ! [[ $STATUS -eq 200 ]]; then
        log_debug "==> response retrieved: $RES"
        error "login to Konnect failed... (Status code: $STATUS)"
    fi
    log_debug "=> login phase completed"
}

get_control_plane() {
    log_debug "=> entering control plane metadata retrieval phase"

    ARGS="--cookie ./$KONNECT_HTTP_SESSION_NAME -X GET --url $KONNECT_API_URL/api/control_planes"
    if [[ $KONNECT_DEV -eq 1 ]]; then
        ARGS="-u $KONNECT_DEV_USERNAME:$KONNECT_DEV_PASSWORD $ARGS"
    fi

    RES=$(http_req "$ARGS")
    RESPONSE_BODY=$(http_res_body "$RES")
    STATUS=$(http_status "$RES")

    if [[ $STATUS -eq 200 ]]; then
        CONTROL_PLANE=$(echo "$RESPONSE_BODY" | jq .data[0])
        KONNECT_CP_ID=$(echo "$CONTROL_PLANE" | jq -r .id)
        KONNECT_CP_ENDPOINT="$(echo "$CONTROL_PLANE" | jq -r .config.control_plane_server_name):443"
        KONNECT_CP_SERVER_NAME="$(echo "$CONTROL_PLANE" | jq -r .config.control_plane_server_name)"
        KONNECT_TP_ENDPOINT="$(echo "$CONTROL_PLANE" | jq -r .config.telemetry_server_name):443"
        KONNECT_TP_SERVER_NAME="$(echo "$CONTROL_PLANE" | jq -r .config.telemetry_server_name)"
    else 
        log_debug "==> response retrieved: $RES"
        error "failed to fetch control plane (Status code: $STATUS)"
    fi
    log_debug "=> control plane metadata retrieval phase completed"
}

generate_certificates() {
    log_debug "=> entering certificate generation phase"
    mkdir -p $KONNECT_DP_CERTIFICATE_DIRECTORY
    ARGS="--cookie ./$KONNECT_HTTP_SESSION_NAME -X POST --url $KONNECT_API_URL/api/control_planes/$KONNECT_CP_ID/data_planes/certificates"

    if [[ $KONNECT_DEV -eq 1 ]]; then
        ARGS="-u $KONNECT_DEV_USERNAME:$KONNECT_DEV_PASSWORD $ARGS"
    fi

    RES=$(http_req "$ARGS")
    RESPONSE_BODY=$(http_res_body "$RES")
    STATUS=$(http_status "$RES")

    if [[ $STATUS -eq 201 ]]; then
        echo "$RESPONSE_BODY" | jq -r '.key' > $KONNECT_DP_CERTIFICATE_DIRECTORY/cluster.key
        echo "$RESPONSE_BODY" | jq -r '(.cert + "\n" + .ca_cert)' > $KONNECT_DP_CERTIFICATE_DIRECTORY/cluster.crt
        echo "$RESPONSE_BODY" | jq -r '.root_ca_cert' > $KONNECT_DP_CERTIFICATE_DIRECTORY/ca_cert.crt
    else 
        log_debug "==> response retrieved: $RES"
        error "failed to generate certificates (Status code: $STATUS)"
    fi
    chmod -R 755 $KONNECT_DP_CERTIFICATE_DIRECTORY
    log_debug "=> certificate generation phase completed"
}

download_kongee_image() {
    log_debug "=> entering kong gateway download phase"
    
    echo "pulling kong docker image..."

    CMD="docker pull $KONNECT_RUNTIME_REPO/$KONNECT_RUNTIME_IMAGE"
    if [[ -n $KONNECT_DOCKER_USER && -n $KONNECT_DOCKER_PASSWORD ]]; then
        CMD="docker login -u $KONNECT_DOCKER_USER -p $KONNECT_DOCKER_PASSWORD $KONNECT_RUNTIME_REPO &> /dev/null && $CMD" 
    fi
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
        -e "KONG_CLUSTER_CONTROL_PLANE=$KONNECT_CP_ENDPOINT" \
        -e "KONG_CLUSTER_SERVER_NAME=$KONNECT_CP_SERVER_NAME" \
        -e "KONG_CLUSTER_TELEMETRY_ENDPOINT=$KONNECT_TP_ENDPOINT" \
        -e "KONG_CLUSTER_TELEMETRY_SERVER_NAME=$KONNECT_TP_SERVER_NAME" \
        -e "KONG_CLUSTER_CERT=/config/cluster.crt" \
        -e "KONG_CLUSTER_CERT_KEY=/config/cluster.key" \
        -e "KONG_LUA_SSL_TRUSTED_CERTIFICATE=system,/config/ca_cert.crt" \
        -e "KONG_LUA_SSL_VERIFY_DEPTH=3" \
        --mount type=bind,source="$(pwd)/$KONNECT_DP_CERTIFICATE_DIRECTORY",target=/config,readonly \
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

    # login and acquire the session
    login

    # get control plane data
    get_control_plane

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
