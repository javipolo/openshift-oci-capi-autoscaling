#!/bin/bash
set -euo pipefail

export compartment=ocid1.compartment.oc1..aaaaaaaasno3ok3vmccrkahvyogfqdzyizp4vrpluxlgrjnhcins5hjoh6yq
cluster_name=$(oc get infrastructure cluster -ojsonpath='{.status.infrastructureName}')
oci_cluster_name=$(echo "$cluster_name" | rev | cut -d - -f 2- | rev)
nsg_name=cluster-compute-nsg
subnet_name=private
image_name=rhcos-vanilla-openstack
ssh_authorized_keys="$(head -n1 ~/.ssh/id_ed25519.pub)"

vcn=$(oci network vcn list --compartment-id "$compartment" --display-name "$oci_cluster_name" | jq -r '.data[0].id')
subnet=$(oci network subnet list --compartment-id "$compartment" --vcn-id "$vcn" --display-name "$subnet_name" | jq -r '.data[0].id')
nsg=$(oci network nsg list --compartment-id "$compartment" --vcn-id "$vcn" --display-name "$nsg_name" | jq -r '.data[0].id')
image=$(oci compute image list --compartment-id "$compartment" --display-name "$image_name" | jq -r '.data[0].id')

export ssh_authorized_keys
export cluster_name
export vcn
export subnet
export nsg
export image

cat << EOF
Autodiscovered values for manifests
===================================

cluster_name=$cluster_name
vcn=$vcn
subnet=$subnet
nsg=$nsg
image=$image
ssh_authorized_keys=$ssh_authorized_keys
EOF

mkdir -p manifests
for i in templates/*.yaml; do
    envsubst < $i > manifests/$(basename $i)
done
