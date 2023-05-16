#!/bin/bash

###################################################################
# Script Name   : cleanup.sh
# Description   : Clean up a Gloo Edge environment
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

cleanup() {
    helm del aws-load-balancer-controller -n kube-system
    helm del vault -n vault
    helm del cert-manager -n cert-manager
    helm del gloo-ee -n gloo-system
}

echo -n "Clean up Gloo Edge $GLOO_EDGE_VERSION"
echo ""

cleanup