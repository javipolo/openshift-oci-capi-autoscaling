#!/bin/bash

source oci-autoscaling-operator-functions.sh

log_it "Starting automatic certificate signer"
while true; do
    until oc get csr | grep --color=auto Pending; do
        sleep 5;
    done;
    oc get csr -o json | jq '.items[] | select(.status.conditions==null) | .metadata.name' -r | xargs -n1 oc adm certificate approve
done
