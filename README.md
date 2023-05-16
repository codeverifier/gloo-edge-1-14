# Gloo Edge 1.14

This project is for setting up Gloo Edge 1.14.

Supported cloud providers include:
* AWS EKS

Includes configuration for setting up the following integration services:
* cert-manager
* Vault
* AWS Load Balancer Controller

## Prerequisites

1. Install tools

  | Command   | Version |      Installation      |
  |:----------|:---------------|:-------------|
  | `eksctl` | latest | Refer to https://eksctl.io/ |
  | Vault | latest | `brew tap hashicorp/tap && brew install hashicorp/tap/vault` |
  | `getopt` | latest | `brew install gnu-getopt` |

2. Create required env vars

    ```
    export CLUSTER_OWNER="kasunt"
    export PROJECT="gloo-ee-demo-1-14"

    export CLOUD_PROVIDER="eks"
    export EKS_CLUSTER_REGION=ap-southeast-2

    export DOMAIN_NAME=testing.development.internal

    export GLOO_EDGE_HELM_VERSION=1.14.1
    export GLOO_EDGE_VERSION=v${GLOO_EDGE_HELM_VERSION}

    export CERT_MANAGER_VERSION="v1.11.2"
    export VAULT_VERSION="0.24.1"
    ```

3. Provisioned cluster
    ```
    ./cluster-provision/scripts/provision-eks-cluster.sh create -n $PROJECT -o $CLUSTER_OWNER -a 3 -v 1.25 -r "${EKS_CLUSTER_REGION}"
    ```

## Install Gloo Edge with integration dependencies

```
./setup.sh -i
```

## Clean up

```
./cleanup.sh
```