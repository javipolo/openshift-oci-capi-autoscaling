#!/bin/bash
set -euo pipefail

if [ $# -lt 1 ]; then
    # Use default namespace
    capi_namespace=capi-system
else
    capi_namespace="$1"
fi

export compartment=ocid1.compartment.oc1..aaaaaaaasno3ok3vmccrkahvyogfqdzyizp4vrpluxlgrjnhcins5hjoh6yq
cluster_name=$(oc get infrastructure cluster -ojsonpath='{.status.infrastructureName}')
export oci_cluster_name=$(echo "$cluster_name" | rev | cut -d - -f 2- | rev)
nsg_name=cluster-compute-nsg
subnet_name=private
image_name=rhcos-vanilla-openstack
export autoscaling_nodegroup_min=0
export autoscaling_nodegroup_max=5
export autoscaling_shape=VM.Standard.E4.Flex
export autoscaling_shapeconfig_cpu=6
export autoscaling_shapeconfig_memory=16

vcn=$(oci network vcn list --compartment-id "$compartment" --display-name "$oci_cluster_name" | jq -r '.data[0].id')
apiserver_lb=$(oci lb load-balancer list --compartment-id $compartment --display-name ${oci_cluster_name}-openshift_api_apps_lb | jq -r '.data[].id')
control_plane_endpoint=$(oci lb load-balancer list --compartment-id $compartment --display-name ${oci_cluster_name}-openshift_api_apps_lb | jq -r '.data[]."ip-addresses"[] | select(."is-public" == true) | ."ip-address"')
subnet=$(oci network subnet list --compartment-id "$compartment" --vcn-id "$vcn" --display-name "$subnet_name" | jq -r '.data[0].id')
nsg=$(oci network nsg list --compartment-id "$compartment" --vcn-id "$vcn" --display-name "$nsg_name" | jq -r '.data[0].id')
image=$(oci compute image list --compartment-id "$compartment" --display-name "$image_name" | jq -r '.data[0].id')

export capi_namespace
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
EOF

mkdir -p manifests
for i in templates/*.yaml; do
    envsubst < $i > manifests/$(basename $i)
done
