#!/bin/bash
set -euo pipefail

if [ $# -lt 2 ]; then
    # Get cluster name from infrastructure
    cluster_name=$(oc get infrastructure cluster -ojsonpath='{.status.infrastructureName}')
else
    cluster_name="$2"
fi

if [ $# -lt 1 ]; then
    # Use default namespace
    namespace=capi-system
else
    namespace="$1"
fi

secret=${cluster_name}-bootstrap

tmpdir=$(mktemp -d)
trap _cleanup exit
_cleanup(){
    rm -fr $tmpdir
}

export MACHINECONFIG_CA=$(oc get secret -n openshift-machine-config-operator machine-config-server-tls -o jsonpath='{.data.tls\.crt}')
export API_INT_HOST=$(oc get infrastructure cluster -o jsonpath='{.status.apiServerInternalURI}' | cut -d / -f 3- | cut -d : -f 1)

mkdir -p $tmpdir/secret
echo ignition > $tmpdir/secret/format
envsubst < templates/bootstrap-ignition.json > $tmpdir/value

jq '.systemd += input.systemd' $tmpdir/value set-hostname-oci-ignition.json \
    | jq '.storage += input.storage' -  set-hostname-oci-ignition.json > $tmpdir/secret/value
oc create -n $namespace secret generic $secret --from-file=$tmpdir/secret --dry-run=client -o yaml | oc apply -f -

echo "Created ignition bootstrap for $cluster_name in secret $namespace/$secret"
