# Openshift Cluster Autoscaling in Oracle Cloud using CAPI

Here is a runbook on how to achieve Cluster Autoscaling in an Openshift cluster in Oracle Cloud
To do so, we rely on Cluster API (CAPI) with OCI infrastructure provider

## Modified or custom images
For this PoC we use custom images. Here's some more information about those custom images

### cluster-capi-operator
We need CAPI to support OCI resources (OCICluster, OCIMachine, ....)

https://github.com/javipolo/cluster-capi-operator/tree/oci-support adds support for those resources
A ready to use container image is in `quay.io/jpolo/cluster-capi-operator:latest`

### cluster-api-provider-oci
cluster-api-provider-oci (or CAPOCI) has several changes:
- Add support to skip Api LoadBalancer management
- Some hacks to the kustomize manifests to deploy using credentials
- A script that imports Oracle Cloud configuration from `oci-cli`

https://github.com/javipolo/cluster-api-provider-oci/tree/capi-autoscaling
A ready to use container image is in `quay.io/jpolo/cluster-api-oci-controller-amd64:dev-skip-with-annotation`

### cluster-autoscaler-operator
cluster-autoscaler-operator honors the environment variables `CAPI_GROUP` and `CAPI_VERSION`, but we also need those variables to
be exported to the `cluster-autoscaler` deployment it creates

https://github.com/javipolo/cluster-autoscaler-operator/tree/exportCAPIvars

A ready to use container image is in `quay.io/jpolo/cluster-autoscaler-operator:latest`

### cluster-autoscaler
cluster-autoscaler current version in Openshift 4.18.10 does not detect our `MachineDeployment`, but the latest version in the
official git repository does. All that takes is building the main branch

https://github.com/openshift/kubernetes-autoscaler/tree/main

A ready to use container image is in `quay.io/jpolo/cluster-autoscaler:latest`

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

- Patch cluster-autoscaler-operator to
  - Use a custom container image
  - Set CAPI_GROUP to the generic CAPI version
  - Set a custom cluster-autoscaler container image to be used
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

- Update permissions so cluster-autoscaler can access the objects in `cluster.x-k8s.io` apiGroup
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

- Create OCICluster, Cluster, OCIMachineTemplate, MachineDeployment and Autoscaler resources
```
oc apply -f manifests/
```

- Wait for cluster to be reconciled properly. It should be in `Provisioned` state
```
oc get cluster -n openshift-machine-api -w
```


## Test autoscaling
- Run csr auto approval in other terminal
```
openshift_wait_and_sign_certificate(){
    until oc get csr | grep Pending; do
        echo -n .
        sleep 1
    done
    oc get csr -o json | jq '.items[] | select(.status.conditions==null) | .metadata.name' -r | xargs -n1 oc adm certificate approve
}

while true; do openshift_wait_and_sign_certificate ; done
```

- Create deployment for nginx, with resource requests of 5Gb
```
oc create deployment nginx --namespace default --image=docker.io/nginx:latest --replicas=0
oc set resources deployment -n default nginx --requests=memory=2Gi
oc scale deployment -n default nginx --replicas=20
```

- Wait for node to pop up
```
oc get md
oc get cluster
oc get node
```

- Now let's try to scale down:
```
oc scale deployment -n default nginx --replicas=15
```

- Wait for node to be removed

## Issues found and things to improve
- CAPI does not create automatically kubeconfig resource.
- Openshift's CAPI uses cluster.x-k8s.io as apiGroup, while openshift-cluster-autoscaler uses machine.openshift.io.
- CAPOCI requires cert-manager.
- CAPOCI installation in openshift requires fixing SCC issues. Added to our custom capoci repo.
- CAPOCI is unable to reconcile an existing apiserver. According to [documentation](https://oracle.github.io/cluster-api-provider-oci/gs/externally-managed-cluster-infrastructure.html#example-ocicluster-spec-with-external-infrastructure) an annotation should be enough, but when applying it, cluster never shows as Provisioned. We hacked it into CAPOCI to achieve this but we should probably do it in a better way.
- CAPOCI does not automatically set memory/cpu/resources needed annotations in MachineDeployment: `capacity.cluster-autoscaler.kubernetes.io/cpu: "6"`. See https://github.com/kubernetes-sigs/cluster-api/blob/main/docs/proposals/20210310-opt-in-autoscaling-from-zero.md
- New nodes dont pick up hostname automatically. Had to add a systemd unit to do so. We should investigate why
- Nodes need to be manually approved with `oc adm certificate approve`. Some automatic system should be created. [This is how Hypershift handles it](https://github.com/openshift/hypershift/pull/5349)
- cluster-autoscaler keeps complaining about pre-existing nodes not being handled by anything. It would be nice to tell the compoment to ignore those nodes
