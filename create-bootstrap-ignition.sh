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
    namespace=openshift-machine-api
else
    namespace="$1"
fi

secret=${cluster_name}-bootstrap

tmpdir=$(mktemp -d)
trap _cleanup exit
_cleanup(){
    rm -fr $tmpdir
}

oc extract -n openshift-cluster-api secret/worker-user-data --to=$tmpdir

mkdir -p $tmpdir/secret
mv $tmpdir/format $tmpdir/secret
jq '.systemd += input.systemd' $tmpdir/value set-hostname-oci-ignition.json \
    | jq '.storage += input.storage' -  set-hostname-oci-ignition.json > $tmpdir/secret/value
oc create -n $namespace secret generic $secret --from-file=$tmpdir/secret

echo "Created ignition bootstrap for $cluster_name in secret $namespace/$secret"
