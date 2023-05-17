#!/bin/bash

###################################################################
# Script Name   : provision-integrations.sh
# Description   : Provision required integrations
# Author        : Kasun Talwatta
# Email         : kasun.talwatta@solo.io
# Version       : v0.1
###################################################################

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

error_exit() {
    echo "Error: $1"
    exit 1
}

error() {
    echo "Error: $1"
}

print_info() {
    echo ""
    echo "============================================================"
    echo "$1"
    echo "============================================================"
    echo ""
}

validate_env_var() {
    [[ -z ${!1+set} ]] && error_exit "Error: Define ${1} environment variable"

    [[ -z ${!1} ]] && error_exit "${2}"
}

validate_var() {
    [[ -z $1 ]] && error_exit $2
}

has_array_value () {
    local -r item="{$1:?}"
    local -rn items="{$2:?}"

    echo $2

    for value in "${items[@]}"; do
        echo $value
        if [[ "$value" == "$item" ]]; then
            return 0
        fi
    done

    return 1
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

create_aws_identity_provider_and_service_account() {
    local cluster_name=$1
    local cluster_region=$2
    local policy_name=$3
    local policy_file=$4
    local sa_name=$5
    local sa_namespace=$6

    validate_env_var cluster_name "Cluster name is not set"
    validate_env_var cluster_region "Cluster region is not set"
    validate_env_var policy_name "Policy name is not set"
    validate_env_var sa_name "Service account name is not set"
    validate_env_var sa_namespace "Namespace for service account is not set"

    eksctl utils associate-iam-oidc-provider \
        --region $cluster_region \
        --cluster ${cluster_name} \
        --approve

    aws iam create-policy \
        --policy-name "${CLUSTER_OWNER}_${policy_name}" \
        --policy-document file://$DIR/$policy_file

    # Create an IAM service account
    eksctl create iamserviceaccount \
        --name=${sa_name} \
        --namespace=${sa_namespace} \
        --cluster=${cluster_name} \
        --region=$cluster_region \
        --attach-policy-arn=$(aws iam list-policies --output json | jq --arg pn "${CLUSTER_OWNER}_${policy_name}" -r '.Policies[] | select(.PolicyName == $pn)'.Arn) \
        --override-existing-serviceaccounts \
        --approve
}

install_alb_controller() {
    local context=$1
    local cluster_name=$2
    local cluster_region=$3
    local cluster_provider=$4
    local sa_namespace="kube-system"

    print_info "Installing ALB Controller on ${context} context"

    validate_env_var context "Kubernetes context not set"
    validate_env_var cluster_name "Cluster name not set"
    validate_env_var cluster_region "Cluster region not set"
    validate_env_var cluster_provider "Cluster provider not set"

    if [[ "$cluster_provider" == "eks" ]]; then
        # Create an IAM OIDC identity provider and policy
        create_aws_identity_provider_and_service_account $cluster_name $cluster_region \
            "AWSLoadBalancerControllerIAMPolicy" "alb-controller/iam-policy.json" "aws-load-balancer-controller" $sa_namespace

        # Get the VPC ID
        export VPC_ID=$(aws ec2 describe-vpcs --region $cluster_region \
            --filters Name=tag:Name,Values=eksctl-${cluster_name}-cluster/VPC | jq -r '.Vpcs[]|.VpcId')
    elif [[ "$cluster_provider" == "eks-ipv6" ]]; then
        export ALB_ARN=$(aws iam get-role --role-name "$cluster_name-alb" --query 'Role.[Arn]' --output text)
        export VPC_ID=$(aws ec2 describe-vpcs --region $cluster_region \
            --filters Name=tag:Name,Values=${cluster_name} | jq -r '.Vpcs[]|.VpcId')
        envsubst < <(cat $DIR/alb-controller/cluster-role-binding.yaml) | kubectl --context $context apply -n $sa_namespace -f -
    else
        error_exit "$cluster_provider not supported"
    fi

    # Install ALB controller
    helm repo add eks https://aws.github.io/eks-charts
    helm repo update eks --fail-on-repo-update-fail

    export CLUSTER_NAME=$cluster_name
    envsubst < <(cat $DIR/alb-controller/helm-values.yaml) | helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
        --kube-context ${context} \
        -n ${sa_namespace} -f -

    kubectl --context ${context} \
        -n kube-system wait deploy/aws-load-balancer-controller --for condition=Available=True --timeout=90s
}

install_cert_manager() {
    local context=$1

    print_info "Installing Cert Manager on ${context} cluster"

    validate_env_var context "Kubernetes context not set"
    validate_env_var CERT_MANAGER_VERSION "Cert manager version is not set with \$CERT_MANAGER_VERSION"

    # Deploy Cert manager
    helm repo add jetstack https://charts.jetstack.io
    helm repo update jetstack --fail-on-repo-update-fail

    kubectl --context ${context} \
        apply -f https://github.com/cert-manager/cert-manager/releases/download/$CERT_MANAGER_VERSION/cert-manager.crds.yaml

    helm install cert-manager jetstack/cert-manager -n cert-manager \
        --kube-context ${context} \
        --create-namespace \
        --version ${CERT_MANAGER_VERSION} \
        -f $DIR/cert-manager/helm-values.yaml

    kubectl --context ${context} \
        -n cert-manager wait deploy/cert-manager --for condition=Available=True --timeout=90s
    kubectl --context ${context} \
        -n cert-manager wait deploy/cert-manager-cainjector --for condition=Available=True --timeout=90s
    kubectl --context ${context} \
        -n cert-manager wait deploy/cert-manager-webhook --for condition=Available=True --timeout=90s
}

install_vault() {
    local context=$1

    validate_env_var context "Kubernetes context is not set"
    validate_env_var VAULT_VERSION "Vault version is not specified as \$VAULT_VERSION environment variable"

    print_info "Installing Vault on ${context} cluster"

    # Deploy Vault
    helm repo add hashicorp https://helm.releases.hashicorp.com
    helm repo update hashicorp --fail-on-repo-update-fail

    helm install vault hashicorp/vault -n vault \
        --kube-context ${context} \
        --version ${VAULT_VERSION} \
        --create-namespace \
        -f $DIR/vault/helm-values.yaml

    # Wait for vault to be ready
    kubectl --context ${context} wait --for=condition=ready pod vault-0 -n vault

    # FIXME: Vault accessed locally so this is redundant
    #wait_for_lb_address $context "vault" "vault"

    #export VAULT_LB=$(kubectl --context ${context} get svc -n vault vault \
    #    -o jsonpath='{.status.loadBalancer.ingress[0].*}')
    #validate_env_var VAULT_LB "Unable to get the load balancer address for Vault"

    #echo export VAULT_LB=$(kubectl --context ${context} get svc -n vault vault \
    #    -o jsonpath='{.status.loadBalancer.ingress[0].*}') > $DIR/../._output/vault_env.sh
    #echo export VAULT_ADDR="http://${VAULT_LB}:8200" >> $DIR/../._output/vault_env.sh
}

install_grafana() {
    error_exit "Grafana not implemented"
}

install_keycloak() {
    error_exit "Keycloak not implemented"
}

install_argocd() {
    error_exit "ArgoCD not implemented"
}

install_gitea() {
    error_exit "Gitea not implemented"
}

help() {
    cat << EOF
usage: ./provision-integrations.sh
-p | --provider     (Required)      Cloud provider for the cluster (Accepted values: aks, eks, gke)
-c | --context      (Required)      Kubernetes context
-n | --name         (Required)      Cluster name (Used for setting up AWS identity)
-r | --region       (Required)      Cluster region
-s | --services     (Required)      Comma delimited set of services to deploy (Accepted values: alb, cert_manager, vault, grafana, keycloak, argocd, gitea)
-h | --help                         Usage
EOF
}

# Pre-validation
validate_env_var CLUSTER_OWNER "Cluster owner \$CLUSTER_OWNER not set"

supported_services=("alb" "cert_manager" "vault" "grafana" "keycloak" "argocd" "gitea")

SHORT=p:,c:,n:,r:,s:,h
LONG=provider:,context:,name:,region:,services:,help
OPTS=$(getopt -a -n "provision-integrations.sh" --options $SHORT --longoptions $LONG -- "$@")

VALID_ARGUMENTS=$#

if [ "$VALID_ARGUMENTS" -eq 0 ]; then
  help
fi

eval set -- "$OPTS"

while :
do
  case "$1" in
    -p | --provider )
      cloud_provider="$2"
      shift 2
      ;;
    -c | --context )
      context="$2"
      shift 2
      ;;
    -n | --name )
      cluster_name="$2"
      shift 2
      ;;
    -r | --region )
      cluster_region="$2"
      shift 2
      ;;
    -s | --services )
      services="$2"
      shift 2
      ;;
    -h | --help)
      help
      ;;
    --)
      shift;
      break
      ;;
    *)
      echo "Unexpected option: $1"
      help
      ;;
  esac
done

validate_var $cloud_provider "Cloud provider not specified"
validate_var $context "Kubernetes context not specified"
validate_var $cluster_name "Cluster name not specified"
validate_var $cluster_region "Cluster region not specified"
validate_var $services "Services list not specified"

if [[ $cloud_provider != "aks" && $cloud_provider != "eks" && $cloud_provider != "eks-ipv6" && $cloud_provider != "gke" ]]; then
    error_exit "Only accepted cloud providers are [aks, eks, eks-ipv6, gke]"
fi

for service in $(echo $services | tr "," "\n")
do
    if [[ ! " ${supported_services[*]} " =~ " ${service} " ]]; then
        error_exit "Service ${service} isnt accepted currently"
    fi

    if [[ "${service}" == "alb" ]]; then
        if [[ "${cloud_provider}" == "eks" || "${cloud_provider}" == "eks-ipv6" ]]; then
            install_alb_controller $context $cluster_name $cluster_region $cloud_provider
        fi
    elif [[ "${service}" == "cert_manager" ]]; then
        install_cert_manager $context $cloud_provider
    elif [[ "${service}" == "vault" ]]; then
        install_vault $context
    elif [[ "${service}" == "grafana" ]]; then
        install_grafana $context
    elif [[ "${service}" == "keycloak" ]]; then
        install_keycloak $context
    elif [[ "${service}" == "argocd" ]]; then
        install_argocd $context 
    elif [[ "${service}" == "gitea" ]]; then
        install_gitea $context
    else
        error_exit "Service ${service} isnt recognized"
    fi
done