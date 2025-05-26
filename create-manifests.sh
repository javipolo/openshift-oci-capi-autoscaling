#!/bin/bash
set -euo pipefail

if [ $# -lt 1 ]; then
    # Use default namespace
    namespace=capi-system
else
    namespace="$1"
fi

export compartment=ocid1.compartment.oc1..aaaaaaaasno3ok3vmccrkahvyogfqdzyizp4vrpluxlgrjnhcins5hjoh6yq
cluster_name=$(oc get infrastructure cluster -ojsonpath='{.status.infrastructureName}')
oci_cluster_name=$(echo "$cluster_name" | rev | cut -d - -f 2- | rev)
nsg_name=cluster-compute-nsg
subnet_name=private
image_name=rhcos-vanilla-openstack
ssh_authorized_keys="$(head -n1 ~/.ssh/id_ed25519.pub)"

vcn=$(oci network vcn list --compartment-id "$compartment" --display-name "$oci_cluster_name" | jq -r '.data[0].id')
apiserver_lb=$(oci lb load-balancer list --compartment-id $compartment --display-name ${oci_cluster_name}-openshift_api_apps_lb | jq -r '.data[].id')
control_plane_endpoint=$(oci lb load-balancer list --compartment-id $compartment --display-name ${oci_cluster_name}-openshift_api_apps_lb | jq -r '.data[]."ip-addresses"[] | select(."is-public" == true) | ."ip-address"')
subnet=$(oci network subnet list --compartment-id "$compartment" --vcn-id "$vcn" --display-name "$subnet_name" | jq -r '.data[0].id')
nsg=$(oci network nsg list --compartment-id "$compartment" --vcn-id "$vcn" --display-name "$nsg_name" | jq -r '.data[0].id')
image=$(oci compute image list --compartment-id "$compartment" --display-name "$image_name" | jq -r '.data[0].id')

export namespace
export ssh_authorized_keys
export cluster_name
export vcn
export apiserver_lb
export control_plane_endpoint
export subnet
export nsg
export image

cat << EOF
Autodiscovered values for manifests
===================================

cluster_name=$cluster_name
vcn=$vcn
apiserver_lb=$apiserver_lb
control_plane_endpoint=$control_plane_endpoint
subnet=$subnet
nsg=$nsg
image=$image
ssh_authorized_keys=$ssh_authorized_keys
EOF

mkdir -p manifests
for i in templates/*.yaml; do
    envsubst < $i > manifests/$(basename $i)
done
