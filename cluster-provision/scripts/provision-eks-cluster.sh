#!/bin/sh

###################################################################
# Script Name   : provision-eks-cluster.sh
# Description   : For managing EKS clusters
# Author        : Kasun Talwatta
# Email         : kasun.talwatta@solo.io
# Version       : v0.2
# Changelog     :
#   v0.2 - Updated EKS version to 1.25
###################################################################

set -e
set -o pipefail

_filename="$(basename $BASH_SOURCE)"

DEFAULT_CLUSTER_VERSION="1.25"
DEFAULT_INSTANCE_TYPE="t3.medium"
DEFAULT_NODE_NUM="1"
DEFAULT_PURPOSE_TAG="pre-sales"
DEFAULT_REGION="ap-southeast-1"
DEFAULT_TEAM_TAG="fe-presale"

CLUSTER_NAME_SUFFIX=""
CLUSTER_VERSION=""
NODE_NUM=""
OWNER=""
PURPOSE=""
REGION=""
TEAM=""

# Display usage message function
usage() {
    echo "=================="
    echo "Usage:"
    echo "=================="
    echo "$_filename -h                                                                                                   Display this usage message"
    echo ""
    echo "$_filename create -o <arg> -n <arg> [-a <arg> -m <arg> -p <arg> -r <arg> -t <arg> -v <arg>] .......... Provisioning a EKS cluster"
    echo "\tRequired arguments:"
    echo "\t-n   Name of the cluster (Uses as the suffix for the name)"
    echo "\t-o   Name of the cluster owner (Used as the prefix for the cluster and for tagging)"
    echo "\tOptional arguments:"
    echo "\t-a - Number of nodes (Default 1 if not specified)"
    echo "\t-m   Instance type (Default \"t3.medium\" if not specified)"
    echo "\t-p   Purpose of the cluster (Default \"pre-sales\" if not specified)"
    echo "\t-r   Region (Default \"ap-southeast-1\" if not specified)"
    echo "\t-s   Supply a public key for SSH (SSH is ignored by default)"
    echo "\t-t   Name of the team owning the cluster (Default \"fe-presale\" if not specified)"
    echo "\t-v   Kubernetes version (Default cluster \"1.23\" if not specified)"
    echo ""
    echo "$_filename delete -o <arg> -n <arg> [-r <arg>] ................................................................ Deleting a EKS cluster"
    echo "\tRequired arguments:"
    echo "\t-n   Name of the cluster (Uses as the suffix for the name)"
    echo "\t-o   Name of the cluster owner (Used as the prefix for the cluster and for tagging)"
    echo "\tOptional arguments:"
    echo "\t-r   Region (Default \"ap-southeast-1\" if not specified)"
}

# Utility function to create a cluster
create_cluster() {
    echo "Creating cluster $1-$2 with $5 nodes of type $4"

    local ssh_allow=false
    if [ ! -z $9 ] && [ "${#9}" -gt 0 ]; then
        ssh_allow=true
    fi

    cat <<EOF | eksctl create cluster -f -
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: "${1}-${2}"
  region: "${7}"
  version: "${3}"
  tags:
    created-by: "${1}"
    purpose: "${6}"
    team: "${8}"

nodeGroups:
  # TODO: Only creating a single pool for now
  - name: default-pool
    instanceType: "${4}"
    desiredCapacity: ${5}
    volumeSize: 10
    ssh:
      allow: ${ssh_allow}
      publicKeyPath: "${9}"
    tags:
      cluster: "${1}-${2}"
      created-by: "${1}"
      purpose: "${6}"
      team: "${8}"
EOF

    sleep 5

    eksctl utils associate-iam-oidc-provider \
        --cluster "${1}-${2}" \
        --region "${7}" \
        --approve

    eksctl create iamserviceaccount \
        --name ebs-csi-controller-sa \
        --namespace kube-system \
        --cluster "${1}-${2}" \
        --region "${7}" \
        --role-name AmazonEKS_EBS_CSI_DriverRole \
        --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
        --role-only \
        --approve

    ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
    eksctl create addon \
        --name aws-ebs-csi-driver \
        --cluster "${1}-${2}" \
        --service-account-role-arn arn:aws:iam::$ACCOUNT_ID:role/AmazonEKS_EBS_CSI_DriverRole \
        --force
}

# Utility function to delete a cluster
delete_cluster() {
    echo "Deleting cluster $1-$2"

    eksctl delete addon \
        --name aws-ebs-csi-driver \
        --cluster "${1}-${2}"

    eksctl delete cluster -n "$1-$2" -r $3
}

[ $# -eq 0 ] && usage && exit 1

while getopts ":h" opt; do # Go through the options
    case $opt in
        h ) # Help
            usage
            exit 0 # Exit correctly
        ;;
        ? ) # Invalid option
            echo "[ERROR]: Invalid option: -${OPTARG}"
            usage
            exit 1
        ;;
    esac
done
shift $((OPTIND-1))
subcommand=$1; shift
case "$subcommand" in
    create )
        unset OPTIND
        [ $# -eq 0 ] && usage && exit 1
        while getopts ":a:m:n:o:p:r:s:t:v:" opt; do
            case $opt in
                a )
                    NODE_NUM=$OPTARG
                ;;
                m )
                    INSTANCE_TYPE=$OPTARG
                ;;
                n )
                    CLUSTER_NAME_SUFFIX=$OPTARG
                ;;
                o )
                    OWNER=$OPTARG
                ;;
                p )
                    PURPOSE_TAG=$OPTARG
                ;;
                r )
                    REGION=$OPTARG
                ;;
                s )
                    SSH_PUB_KEY=$OPTARG
                ;;
                t )
                    TEAM_TAG=$OPTARG
                ;;
                v )
                    CLUSTER_VERSION=$OPTARG
                ;;
                : ) # Catch no argument provided
                        echo "[ERROR]: option -${OPTARG} requires an argument"
                        usage
                        exit 1
                ;;
                ? ) # Invalid option
                        echo "[ERROR]: Invalid option: -${OPTARG}"
                        usage
                        exit 1
                ;;
            esac
        done

        if [ -z $OWNER ] || [ -z $CLUSTER_NAME_SUFFIX ]; then
            echo "[ERROR]: Both -o and -n are required"
            usage
            exit 1
        fi

        shift $((OPTIND-1))

        CLUSTER_VERSION=${CLUSTER_VERSION:-$DEFAULT_CLUSTER_VERSION}
        INSTANCE_TYPE=${INSTANCE_TYPE:-$DEFAULT_INSTANCE_TYPE}
        NODE_NUM=${NODE_NUM:-$DEFAULT_NODE_NUM}
        PURPOSE_TAG=${PURPOSE_TAG:-$DEFAULT_PURPOSE_TAG}
        REGION=${REGION:-$DEFAULT_REGION}
        TEAM_TAG=${TEAM_TAG:-$DEFAULT_TEAM_TAG}

        create_cluster $OWNER $CLUSTER_NAME_SUFFIX $CLUSTER_VERSION $INSTANCE_TYPE $NODE_NUM $PURPOSE_TAG $REGION $TEAM_TAG "$SSH_PUB_KEY"
    ;;
    delete )
        unset OPTIND
        [ $# -eq 0 ] && usage && exit 1
        while getopts ":n:o:r:" opt; do
            case $opt in
                n )
                    CLUSTER_NAME_SUFFIX=$OPTARG
                ;;
                o )
                    OWNER=$OPTARG
                ;;
                r )
                    REGION=$OPTARG
                ;;
                : ) # Catch no argument provided
                        echo "[ERROR]: option -${OPTARG} requires an argument"
                        usage
                        exit 1
                ;;
                ? ) # Invalid option
                        echo "[ERROR]: Invalid option: -${OPTARG}"
                        usage
                        exit 1
                ;;
            esac
        done

        if [ -z $OWNER ] || [ -z $CLUSTER_NAME_SUFFIX ]; then
            echo "[ERROR]: Both -o and -n are required"
            usage
            exit 1
        fi

        shift $((OPTIND-1))

        REGION=${REGION:-$DEFAULT_REGION}

        delete_cluster $OWNER $CLUSTER_NAME_SUFFIX $REGION
    ;;
    * ) # Invalid subcommand
        if [ ! -z $subcommand ]; then
            echo "Invalid subcommand: $subcommand"
        fi
        usage
        exit 1
    ;;
esac