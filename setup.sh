#!/bin/bash

###################################################################
# Script Name   : setup.sh
# Description   : Provision a Gloo Edge environment
# Author        : Kasun Talwatta
# Email         : kasun.talwatta@solo.io
# Version       : v0.1
###################################################################

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

error_exit() {
    echo "Error: $1"
    exit 1
}

print_info() {
    echo "============================================================"
    echo "$1"
    echo "============================================================"
    echo ""
}

debug() {
    echo ""
    echo "$1"
    echo ""
}

validate_env_var() {
    [[ -z ${!1+set} ]] && error_exit "Error: Define ${1} environment variable"

    [[ -z ${!1} ]] && error_exit "${2}"
}

wait_for_lb_address() {
    local context=$1
    local service=$2
    local ns=$3
    ip=""
    while [ -z $ip ]; do
        echo "Waiting for $service external IP ..."
        ip=$(kubectl --context ${context} -n $ns get service/$service --output=jsonpath='{.status.loadBalancer}' | grep "ingress")
        [ -z "$ip" ] && sleep 5
    done
    echo "Found $service external IP: ${ip}"
}

pre_req_checks() {
    if [[ -z "${PROJECT}" ]]; then
        error_exit "Project name not set. Please set environment variables, \$PROJECT."
    fi

    if [[ -z "${CLOUD_PROVIDER}" ]]; then
        error_exit "Cloud provider not set. Please set environment variables, \$CLOUD_PROVIDER."
    fi

    if [[ -z "${GLOO_EDGE_VERSION}" || -z "${GLOO_EDGE_HELM_VERSION}" ]]; then
        error_exit "Gloo Edge version is not set. Please set environment variable, \$GLOO_EDGE_VERSION and \$GLOO_EDGE_HELM_VERSION."
    fi

    if [[ -z "${GLOO_EDGE_LICENSE_KEY}" || -z "${GLOO_EDGE_GRAPHQL_LICENSE_KEY}" ]]; then
        error_exit "Gloo Edge license key not set. Please set environment variables, \$GLOO_EDGE_LICENSE_KEY or \$GLOO_EDGE_GRAPHQL_LICENSE_KEY."
    fi
}

cloud_specific_pre_req_checks() {
    local cloud_provider=$1
    if [[ $cloud_provider == "eks" || $cloud_provider == "eks-ipv6" ]]; then
        validate_env_var EKS_CLUSTER_REGION "EKS cluster region \$EKS_CLUSTER_REGION not set"
        export CLUSTER_REGION=$EKS_CLUSTER_REGION
    fi
    
    if [[ $cloud_provider == "gke" ]]; then
        validate_env_var GKE_CLUSTER_REGION "GKE cluster region \$GKE_CLUSTER_REGION not set"
        export CLUSTER_REGION=$GKE_CLUSTER_REGION
    fi
}

get_current_context() {
    export CURRENT_CONTEXT=$(kubectl config current-context)
}

install_gloo_edge() {
    local context=$1
    local custom_helm_file=$2

    local helm_file=$DIR/gloo-edge-helm-values.yaml

    print_info "Installing Gloo Edge on cluster"

    if [[ ! -z $custom_helm_file ]]; then
        if [[ -f $custom_helm_file ]]; then
            helm_file=$custom_helm_file
        else
            error_exit "Override file doesnt exist for installing Gloo Edge"
        fi
    fi

    helm repo add gloo-ee https://storage.googleapis.com/gloo-ee-helm
    helm repo update gloo-ee --fail-on-repo-update-fail

    helm pull gloo-ee/gloo-ee \
        --version=${GLOO_EDGE_HELM_VERSION} \
        --untar \
        --untardir $DIR/._output

    kubectl apply -f $DIR/._output/gloo-ee/charts/gloo/crds
    rm -rf $DIR/._output/gloo-ee

    helm upgrade --install gloo-ee gloo-ee/gloo-ee \
        --kube-context=${context} \
        --namespace gloo-system \
        --create-namespace \
        --version=${GLOO_EDGE_HELM_VERSION} \
        --set-string license_key=${GLOO_EDGE_LICENSE_KEY} \
        -f $helm_file
    
    kubectl --context ${context} \
        -n gloo-system wait deploy/gloo --for condition=Available=True --timeout=90s
    kubectl --context ${context} \
        -n gloo-system wait deploy/gateway-proxy --for condition=Available=True --timeout=90s
}

# Create a temp dir (for any internally generated files)
mkdir -p $DIR/._output

# Run prechecks to begin with
pre_req_checks

# Get the current context
get_current_context

cloud_specific_pre_req_checks $CLOUD_PROVIDER

should_deploy_integrations=false
custom_helm_file=""

SHORT=f:,i,h
LONG=file,integrations,help
OPTS=$(getopt -a -n "setup.sh" --options $SHORT --longoptions $LONG -- "$@")

eval set -- "$OPTS"

while :; do
    case "$1" in
    -f | --file)
        custom_helm_file="$2"
        shift 2
        ;;
    -i | --integrations)
        shift 1
        should_deploy_integrations=true
        ;;
    -h | --help)
        help
        ;;
    --)
        shift
        break
        ;;
    *)
        echo "Unexpected option: $1"
        help
        ;;
    esac
done

echo -n "Deploying Gloo Edge $GLOO_EDGE_VERSION"
echo ""

if [[ "$should_deploy_integrations" == true ]]; then
    $DIR/integrations/provision-integrations.sh -n "${CLUSTER_OWNER}-${PROJECT}" -r $CLUSTER_REGION -p $CLOUD_PROVIDER -c $CURRENT_CONTEXT -s "cert_manager, vault, alb"
fi

install_gloo_edge $CURRENT_CONTEXT $custom_helm_file