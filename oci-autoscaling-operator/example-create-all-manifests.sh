#!/bin/bash
set -euo pipefail

if [ "$#" -lt 1 ]; then
    echo "Usage: $0 cluster-name"
    exit 1
fi

get_from_oci_config(){
    grep -E "^\s*${1}=" ~/.oci/config | cut -d = -f 2-
}

oci_cluster_name=$1
nsg_name=cluster-compute-nsg
subnet_name=private
image_name=rhcos-vanilla-openstack
export autoscaling_nodegroup_min=0
export autoscaling_nodegroup_max=5
export autoscaling_shape=VM.Standard.E4.Flex
export autoscaling_shapeconfig_cpu=6
export autoscaling_shapeconfig_memory=16

export compartment=ocid1.compartment.oc1..aaaaaaaasno3ok3vmccrkahvyogfqdzyizp4vrpluxlgrjnhcins5hjoh6yq
export vcn=$(oci network vcn list --compartment-id "$compartment" --display-name "$oci_cluster_name" | jq -r '.data[0].id')
export apiserver_lb=$(oci lb load-balancer list --compartment-id $compartment --display-name ${oci_cluster_name}-openshift_api_apps_lb | jq -r '.data[].id')
export control_plane_endpoint=$(oci lb load-balancer list --compartment-id $compartment --display-name ${oci_cluster_name}-openshift_api_apps_lb | jq -r '.data[]."ip-addresses"[] | select(."is-public" == true) | ."ip-address"')
export subnet=$(oci network subnet list --compartment-id "$compartment" --vcn-id "$vcn" --display-name "$subnet_name" | jq -r '.data[0].id')
export nsg=$(oci network nsg list --compartment-id "$compartment" --vcn-id "$vcn" --display-name "$nsg_name" | jq -r '.data[0].id')
export image=$(oci compute image list --compartment-id "$compartment" --display-name "$image_name" | jq -r '.data[0].id')

cat << EOF
Autodiscovered values for manifests
===================================

oci_cluster_name=$oci_cluster_name
vcn=$vcn
apiserver_lb=$apiserver_lb
control_plane_endpoint=$control_plane_endpoint
subnet=$subnet
nsg=$nsg
image=$image
EOF

echo Parsing oci-cli config for the remaining values
export tenancy=$(get_from_oci_config tenancy)
export user=$(get_from_oci_config user)
export fingerprint=$(get_from_oci_config fingerprint)
export region=$(get_from_oci_config region)

key_file=$(get_from_oci_config key_file)
export oci_passphrase_b64=$(get_from_oci_config passphrase | base64 -w0)
export oci_certificate_b64=$(cat $key_file | base64 -w0)

cat deploy.yaml > example-all-manifests.yaml
cat example-configmap.yaml example-oci-autoscaler-config.yaml example-secret.yaml | envsubst >> example-all-manifests.yaml
