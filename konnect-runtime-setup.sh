#!/usr/bin/env bash

KONNECT_RUNTIME_PORT=8000
KONNECT_API_URL=
KONNECT_USERNAME=
KONNECT_PASSWORD=
KONNECT_CONTROL_PLANE=
KONNECT_RUNTIME_REPO=
KONNECT_RUNTIME_IMAGE=

KONNECT_CLUSTER_CRT=
KONNECT_CLUSTER_KEY=
KONNECT_CA_CRT=

KONNECT_CP_ID=
KONNECT_CP_NAME=
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
    -c              Konnect control plane Id
    -r              Konnect runtime repository url
    -ri             Konnect runtime image name
    -pp             runtime port number
    -cr             Konnect cluster crt
    -ck             Konnect cluster key
    -ca             Konnect CA crt
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
    -c)
        KONNECT_CONTROL_PLANE=$2
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
    -cr)
        KONNECT_CLUSTER_CRT=$2
        shift
        ;;
    -ck)
        KONNECT_CLUSTER_KEY=$2
        shift
        ;;
    -ca)
        KONNECT_CA_CRT=$2
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

    if [[ -z $KONNECT_RUNTIME_REPO ]]; then
        error "Konnect runtime repository url is missing"
    fi

    if [[ -z $KONNECT_RUNTIME_IMAGE ]]; then
        error "Konnect runtime image name is missing"
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

# login to the Konnect and acquire the session
login() {
    unset KONNECT_PASSWORD
    echo "Email: $KONNECT_USERNAME"
    echo -n "Konnect Password:"
    read -s KONNECT_PASSWORD
    echo

    log_debug "=> entering login phase"

    ARGS="--cookie-jar ./$KONNECT_HTTP_SESSION_NAME -X POST -d {\"username\":\"$KONNECT_USERNAME\",\"password\":\"$KONNECT_PASSWORD\"} --url $KONNECT_API_URL/kauth/api/v1/authenticate"
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

    ARGS="--cookie ./$KONNECT_HTTP_SESSION_NAME -X GET --url $KONNECT_API_URL/api/runtime_groups/$KONNECT_CONTROL_PLANE"
    if [[ $KONNECT_DEV -eq 1 ]]; then
        ARGS="-u $KONNECT_DEV_USERNAME:$KONNECT_DEV_PASSWORD $ARGS"
    fi

    log_debug "$ARGS"

    RES=$(http_req_plain "$ARGS")
    RESPONSE_BODY=$(http_res_body "$RES")
    STATUS=$(http_status "$RES")

    log_debug "$RESPONSE_BODY"

    if [[ $STATUS -eq 200 ]]; then
        CONTROL_PLANE=$(echo "$RESPONSE_BODY" | jq .)
        KONNECT_CP_ID=$(echo "$CONTROL_PLANE" | jq -r .id)
        KONNECT_CP_NAME=$(echo "$CONTROL_PLANE" | jq -r .name)
        KONNECT_CP_ENDPOINT="$(echo "$CONTROL_PLANE" | jq -r .config.cp_outlet)"
        KONNECT_TP_ENDPOINT="$(echo "$CONTROL_PLANE" | jq -r .config.telemetry_endpoint)"
    else
        log_debug "==> response retrieved: $RES"
        error "failed to fetch control plane (Status code: $STATUS)"
    fi
    log_debug "=> control plane metadata retrieval phase completed"
}

setup_gcp(){
    CP_SERVER_NAME=$(echo "$KONNECT_CP_ENDPOINT" | awk -F/ '{print $3}')
    TP_SERVER_NAME=$(echo "$KONNECT_TP_ENDPOINT" | awk -F/ '{print $3}')

    GCP_PROJECT_ID="$(gcloud projects list --filter="$(gcloud config get-value project)" --format="value(PROJECT_NUMBER)")"

    # setup secrets in google secrets manager
    gcloud secrets describe "konnect_cluster_crt" || gcloud secrets create "konnect_cluster_crt" --replication-policy="automatic" --project="$GOOGLE_CLOUD_PROJECT"
    gcloud secrets describe "konnect_cluster_key" || gcloud secrets create "konnect_cluster_key" --replication-policy="automatic" --project="$GOOGLE_CLOUD_PROJECT"
    #gcloud secrets describe "konnect_ca_cert_crt" || gcloud secrets create "konnect_ca_cert_crt" --replication-policy="automatic" --project="$GOOGLE_CLOUD_PROJECT"
    echo "$KONNECT_CLUSTER_CRT" | base64 -d | gcloud secrets versions add "konnect_cluster_crt" --project="$GOOGLE_CLOUD_PROJECT" --data-file=-
    echo "$KONNECT_CLUSTER_KEY" | base64 -d | gcloud secrets versions add "konnect_cluster_key" --project="$GOOGLE_CLOUD_PROJECT" --data-file=-
    #echo "$KONNECT_CA_CRT" | base64 -d | gcloud secrets versions add "konnect_ca_cert_crt" --project="$GOOGLE_CLOUD_PROJECT" --data-file=-

    # add gcp service account and policy binding
    gcloud iam service-accounts create konnect-dps \
      --description="for konnect data planes to access necessary secrets" \
      --display-name="konnect-dps"
    gcloud projects add-iam-policy-binding $GOOGLE_CLOUD_PROJECT \
      --member="serviceAccount:konnect-dps@$GOOGLE_CLOUD_PROJECT.iam.gserviceaccount.com" \
      --role="roles/secretmanager.secretAccessor" \
      --condition="expression=resource.name.startsWith(\"projects/$GCP_PROJECT_ID/secrets/konnect\"),title='konnect-dp secret access'"

    # create a gce instance running kong
    gcloud compute instances create-with-container konnect-dp-1 \
      --project=$GOOGLE_CLOUD_PROJECT \
      --service-account="konnect-dps@$GOOGLE_CLOUD_PROJECT.iam.gserviceaccount.com" \
      --zone=us-east1-b \
      --machine-type=e2-micro \
      --network-interface=network-tier=PREMIUM,subnet=default \
      --maintenance-policy=MIGRATE \
      --scopes=https://www.googleapis.com/auth/devstorage.read_only,https://www.googleapis.com/auth/logging.write,https://www.googleapis.com/auth/monitoring.write,https://www.googleapis.com/auth/servicecontrol,https://www.googleapis.com/auth/service.management.readonly,https://www.googleapis.com/auth/trace.append,https://www.googleapis.com/auth/cloud-platform \
      --image-project=cos-cloud \
      --image-family=cos-93-lts \
      --boot-disk-size=10GB \
      --boot-disk-type=pd-balanced \
      --boot-disk-device-name=konnect-dp-1 \
      --container-image="$KONNECT_RUNTIME_REPO"/"$KONNECT_RUNTIME_IMAGE" \
      --container-restart-policy=always \
      --container-mount-host-path=host-path=/etc/kong/konnect/config,mode=ro,mount-path=/config \
      --container-env=^,@^KONG_ROLE=data_plane,@KONG_DATABASE=off,@KONG_ANONYMOUS_REPORTS=off,@KONG_VITALS_TTL_DAYS=723,@KONG_CLUSTER_MTLS=pki,@KONG_CLUSTER_CONTROL_PLANE=$CP_SERVER_NAME:443,@KONG_CLUSTER_SERVER_NAME=$CP_SERVER_NAME,@KONG_CLUSTER_TELEMETRY_ENDPOINT=$TP_SERVER_NAME:443,@KONG_CLUSTER_TELEMETRY_SERVER_NAME=$TP_SERVER_NAME,@KONG_CLUSTER_CERT=/config/cluster.crt,@KONG_CLUSTER_CERT_KEY=/config/cluster.key,@KONG_LUA_SSL_TRUSTED_CERTIFICATE=system,/config/cluster.crt \
      --no-shielded-secure-boot \
      --shielded-vtpm \
      --shielded-integrity-monitoring \
      --labels=container-vm=cos-stable-93-16623-102-12 \
      --metadata=startup-script='#! /bin/bash
      mkdir -p /etc/kong/konnect/config
      export GCP_PROJECT_ID="$(curl "http://metadata.google.internal/computeMetadata/v1/project/project-id" -H "X-Google-Metadata-Request: True")"
      export GCP_ACCESS_TOKEN="$(curl "http://metadata/computeMetadata/v1/instance/service-accounts/default/token" -H "X-Google-Metadata-Request: True" | jq -r .access_token)"
      curl "https://secretmanager.googleapis.com/v1/projects/$GCP_PROJECT_ID/secrets/konnect_cluster_crt/versions/latest:access" \
        --request "GET" \
        --header "authorization: Bearer $GCP_ACCESS_TOKEN" \
        --header "content-type: application/json" | jq .payload.data -r | base64 -d > /etc/kong/konnect/config/cluster.crt
      curl "https://secretmanager.googleapis.com/v1/projects/$GCP_PROJECT_ID/secrets/konnect_cluster_key/versions/latest:access" \
        --request "GET" \
        --header "authorization: Bearer $GCP_ACCESS_TOKEN" \
        --header "content-type: application/json" | jq .payload.data -r | base64 -d > /etc/kong/konnect/config/cluster.key
      curl "https://secretmanager.googleapis.com/v1/projects/$GCP_PROJECT_ID/secrets/konnect_ca_cert_crt/versions/latest:access" \
        --request "GET" \
        --header "authorization: Bearer $GCP_ACCESS_TOKEN" \
        --header "content-type: application/json" | jq .payload.data -r | base64 -d > /etc/kong/konnect/config/ca_cert.crt
      '

    log_debug "=> kong gateway infrastructure created"
}

cleanup() {
    # remove cookie file
    rm -f ./$KONNECT_HTTP_SESSION_NAME
    rm -f ./payload.json
    rm -f ./openssl.cnf
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

    echo "Ready to launch"
    # set up gcp infrastructure
    setup_gcp
    echo "Enjoy the flight!"

    cleanup
}

main "$@"
