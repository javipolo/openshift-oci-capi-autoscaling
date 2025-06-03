#!/bin/bash
set -euo pipefail

# This is a crude but functional shellscript that sets everything in place to implement Openshift node autoscaling in Oracle Cloud
# TODO
# Use `service.beta.openshift.io/serving-cert-secret-name` annotation for certificate
# generation to remove cert-manager dependency

# Configmap used to configure components deployment
default_configmap_name=oci-autoscaling-operator
# Secret used to configure components deployment (sensitive data such as private key)
default_secret_name=oci-autoscaling-operator
# Configmap used to configure cluster-autoscaler itself (max nodes, min nodes, etc etc)
default_autoscaler_config_configmap_name=oci-autoscaler-config
default_namespace=capi-system
default_capi_namespace=capi-system
default_cert_manager_version=v1.9.1

configmap_name=${CONFIGMAP_NAME:-$default_configmap_name}
secret_name=${SECRET_NAME:-$default_secret_name}
autoscaler_config=${AUTOSCALER_CONFIG_NAME:-$default_autoscaler_config_configmap_name}
namespace=${NAMESPACE:-$default_namespace}
capi_namespace=${CAPI_NAMESPACE:-$default_capi_namespace}
cert_manager_version=${CERT_MANAGER_VERSION:-$default_cert_manager_version}

config_dir=/tmp/config

capoci_git_dir=/tmp/capoci
capoci_repo="https://github.com/javipolo/cluster-api-provider-oci"
capoci_branch="capi-autoscaling"

# For readability, all functions are in this extra file
source oci-autoscaling-operator-functions.sh

reconcile(){
    log_it "Starting reconcile loop"

    get-configuration

    if ! cert-manager-healthy; then
        log_it "cert-manager is not healthy"
        # Provision
        cert-manager-provision
        # Wait for the service to be healthy
        # in case of timeout, end this reconcile loop
        do_wait cert-manager cert-manager-healthy || return 1
    fi

    if ! capi-healthy; then
        log_it "CAPI is not healthy"
        # Provision
        capi-provision
        # Wait for the service to be healthy
        # in case of timeout, end this reconcile loop
        do_wait CAPI capi-healthy || return 1
    fi

    if ! capoci-healthy; then
        log_it "CAPOCI is not healthy"
        # Provision
        capoci-provision
        # Wait for the service to be healthy
        # in case of timeout, end this reconcile loop
        do_wait CAPOCI capoci-healthy || return 1
    fi

    if ! autoscaler-healthy; then
        log_it "cluster-autoscaler is not healthy"
        # Provision
        autoscaler-provision
        # Wait for the service to be healthy
        # in case of timeout, end this reconcile loop
        do_wait cluster-autoscaler autoscaler-healthy || return 1
    fi

    # Generate kubeconfig
    ./create-kubeconfig.sh

    # Generate bootstrap ignition secret
    ./create-bootstrap-ignition.sh

    # Recreate manifests
    create-manifests
    # And apply them to the cluster
    oc apply -f /tmp/manifests/

    log_it "Ending reconcile loop"
}

oc login \
    --token="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
    --server=https://kubernetes.default.svc \
    --insecure-skip-tls-verify

if [ "$(oc get infrastructure cluster -ojsonpath='{.spec.platformSpec.external.platformName}')" != "oci" ]; then
    log_it "ERROR: Not running in OCI external platform, going to sleep"
    sleep 0
fi

while true; do
    reconcile
    sleep 60
done
