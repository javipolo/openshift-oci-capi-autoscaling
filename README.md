# Openshift Cluster Autoscaling in Oracle Cloud using CAPI

Here is a runbook on how to achieve Cluster Autoscaling in an Openshift cluster in Oracle Cloud
To do so, we rely on Cluster API (CAPI) with OCI infrastructure provider

## Prerequisites

- oci-cli installed and configured

## Provision cluster

- Create cluster in [assisted installer](https://console.redhat.com/openshift/assisted-installer)
    - Use a domain name that you can manage in Oracle Cloud
    - Enable `Integrate with external partner platforms` - `Oracle Cloud Infrastructure`
    - Create minimal ISO
    - Upload ISO to OCI bucket
    - Create pre-authenticated request for ISO in bucket
- Create OCI stack:
    - My-configuration
    - Using zip file: [create-cluster-v0.1.0.zip](https://github.com/dfoster-oracle/oci-openshift/releases/)
    - Set the cluster name to the same name than in assisted-installer
    - Copy pre-authenticated request into `Openshift image source URI`
    - Set the `zone DNS` to the same domain than you set in assisted-installer
    - Configure the rest of parameters as desired
    - Run apply on the created stack
- Go back to assisted service UI and set the node roles
    - Add an `oci.yml` custom manifest
        - Copy it from the OCI stack output `dynamic_custom_manifest`
- Download kubeconfig and set it as default
- Wait until cluster is fully settled. You can monitor the status with `oc get clusterversion` and `oc get clusteroperators`

## Create a new OCI custom image
  Using [rhcos-openstack](https://mirror.openshift.com/pub/openshift-v4/x86_64/dependencies/rhcos/4.18/latest/rhcos-4.18.1-x86_64-openstack.x86_64.qcow2.gz)

## Provision CAPI

- Set `TechPreviewNoUpgrade` featureSet to enable CAPI
```
oc patch featuregate cluster --type merge -p '{"spec":{"featureSet":"TechPreviewNoUpgrade"}}'
```

- Wait until CAPI operator is present in `openshift-cluster-api` namespace
```
oc get po -n openshift-cluster-api -w
```

## Disable openshift cluster version
We will need to tweak some operators, so we need to stop Cluster Version Operator to prevent it from rolling back our changes
```
oc -n openshift-cluster-version scale deploy/cluster-version-operator --replicas 0
```

## Use custom version of cluster-capi-operator
We need CAPI to support OCI resources (OCICluster, OCIMachine, ....) so we have a [modified version of Cluster CAPI Operator](https://github.com/javipolo/cluster-capi-operator/tree/oci-support) that adds support for those resources
The container image with those changes is in `quay.io/jpolo/cluster-capi-operator:latest`

- Use our custom cluster-capi-operator
```
oc patch deployment cluster-capi-operator \
  -n openshift-cluster-api \
  --type='strategic' \
  -p='{ "spec": {
          "template": {
            "spec": {
              "containers": [
                {
                  "name": "cluster-capi-operator",
                  "image": "quay.io/jpolo/cluster-capi-operator:latest"
                },
                {
                  "name": "machine-api-migration",
                  "image": "quay.io/jpolo/cluster-capi-operator:latest"
                }
              ] } } } }'
```

- Update serviceaccount permissions for cluster-autoscaler-operator
```
oc apply -f role-cluster-autoscaler-operator.yaml
```

- Patch cluster-autoscaler-operator to
  - Set a custom image that exports CAPI_GROUP and CAPI_VERSION env vars to cluster-autoscaler
  - Set CAPI_GROUP to the generic CAPI version
  - Set a custom cluster-autoscaler image to be used (it's just a build of current main branch of https://github.com/openshift/kubernetes-autoscaler)
```
 oc patch deployment cluster-autoscaler-operator \
   -n openshift-machine-api \
  --type='strategic' \
  -p='{ "spec": {
          "template": {
            "spec": {
              "containers": [
                {
                  "name": "cluster-autoscaler-operator",
                  "image": "quay.io/jpolo/cluster-autoscaler-operator:latest",
                  "env": [
                    {
                      "name": "CAPI_GROUP",
                      "value": "cluster.x-k8s.io"
                    },
                    {
                      "name": "CLUSTER_AUTOSCALER_IMAGE",
                      "value": "quay.io/jpolo/cluster-autoscaler:latest"
                    }
                  ] } ] } } } }'
```

- Update serviceaccount permissions for cluster-autoscaler
```
oc apply -f role-cluster-autoscaler.yaml
```

## Provision CAPOCI

- Install cert-manager
```
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.9.1/cert-manager.yaml
```

- Clone CAPOCI repo
```
git clone https://github.com/javipolo/cluster-api-provider-oci -b capi-autoscaling
```

- Configure Oracle Cloud credentials. For testing purposes we can use the script `scripts/import-oci-cli-config.sh` that will import oci-cli
  configuration
```
make -C cluster-api-provider-oci import-oci-cli-config
```

- If needed, adjust the container image to be used, in `cluster-api-provider-oci/config/default/manager_image_patch.yaml`

- Install CAPOCI
```
make -C cluster-api-provider-oci deploy
```

## Create CAPI cluster
- Create bootstrap ignition in a secret
```
./create-bootstrap-ignition.sh
```

- Create a kubeconfig for the cluster
```
./create-kubeconfig.sh
```

- Tweak `create-manifests.sh` to reflect your environment. Especially the `image_name` or `image` variables
- Generate CAPI manifests
```
./create-manifests.sh
```

- Create OCICluster and Cluster
```
oc apply -f manifests/01-ocicluster-initial.yaml -f manifests/02-cluster.yaml
```

- Wait for cluster to be reconciled properly. It should appear in `Provisioned` state
```
oc get cluster -n openshift-machine-api -w
```

- Update OCICluster to reflect that network management is done outside the OCICluster resource
```
oc apply -f manifests/03-ocicluster-final.yaml
```

- Create OCIMachineTemplate and MachineDeployment
```
oc apply -f manifests/04-ocimachinetemplate.yaml -f manifests/05-machinedeployment.yaml
```

- Create ClusterAutoscaler
```
oc apply -f manifests/06-clusterautoscaler.yaml
```

## Test autoscaling
- Create deployment for nginx, with resource requests of 2Gb
```
oc create deployment nginx --namespace default --image=docker.io/nginx:latest --replicas=0
oc set resources deployment -n default nginx --requests=memory=2Gi
oc scale deployment -n default nginx --replicas=11
```

- Run csr auto approval in other terminal
```
openshift_wait_and_sign_certificate(){
    until oc get csr | grep Pending; do
        echo -n .
        sleep 1
    done
    oc get csr -o json | jq '.items[] | select(.status.conditions==null) | .metadata.name' -r | xargs -n1 oc adm certificate approve
}

openshift_wait_and_sign_certificate ; openshift_wait_and_sign_certificate
```

- Wait for node to pop up
```
oc get md -w
oc get cluster
oc get node
```

## ISSUES
- Deploying capoci requires cert-manager
- Manual CAPOCI installation requires fixing SCC issues
- CAPOCI is unable to reconcile a cluster with existing infrastructure. We need to create it first with `skipNetworkManagement:
  false` and then update it setting it to true
- openshift CAPI CRDs use cluster.x-k8s.io as kind domain, while openshift-cluster-autoscaler uses machine.openshift.io
- New nodes dont pick up hostname automatically. Had to add a systemd unit to do so
- Need to set up some automatic node approval system
- CAPOCI does not set automatically memory/cpu/resources needed annotations in MachineDeployment: `capacity.cluster-autoscaler.kubernetes.io/cpu: "6"`
- CAPI does not create automatically kubeconfig resource
