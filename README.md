# Openshift Cluster Autoscaling in Oracle Cloud using CAPI

Here is a runbook on how to achieve Cluster Autoscaling in an Openshift cluster in Oracle Cloud
To do so, we rely on Cluster API (CAPI) with OCI infrastructure provider

There are two ways of installing this:
- Provision a cluster, and then deploy the different components
- Use the oci-autoscaling-operator to set everything up

## Modified or custom images

### cluster-api-provider-oci
cluster-api-provider-oci (or CAPOCI) has several changes:
- Add support to skip Api LoadBalancer management
- Some hacks to the kustomize manifests to deploy using credentials
- A script that imports Oracle Cloud configuration from `oci-cli`

https://github.com/javipolo/cluster-api-provider-oci/tree/capi-autoscaling
A ready to use container image is in `quay.io/jpolo/cluster-api-oci-controller-amd64:dev-skip-with-annotation`

## Method 1. Installing components manually
### Prerequisites

- [oci-cli](https://github.com/oracle/oci-cli) installed and configured
- [clusterctl](https://cluster-api.sigs.k8s.io/user/quick-start#install-clusterctl)

### Provision cluster

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

### Create a new OCI custom image
  [Create a Custom Linux Image](https://docs.public.oneportal.content.oci.oraclecloud.com/en-us/iaas/compute-cloud-at-customer/topics/images/importing-custom-linux-imges.htm) using [rhcos-openstack qcow2 file](https://mirror.openshift.com/pub/openshift-v4/x86_64/dependencies/rhcos/4.18/latest/rhcos-4.18.1-x86_64-openstack.x86_64.qcow2.gz)

### Install cert-manager
cert-manager is needed for both CAPI and CAPOCI, so we need to install it first

- Install cert-manager
```
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.9.1/cert-manager.yaml
```

### Install upstream CAPI

```
clusterctl generate provider --core cluster-api | grep -vE 'runAs(User|Group)' | oc apply -f -
```

### Install upstream cluster-autoscaler

```
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm repo update
helm install oci-cluster-autoscaler autoscaler/cluster-autoscaler --values cluster-autoscaler-values.yaml --namespace capi-system
```

and update permissions so cluster-autoscaler can access the objects in `cluster.x-k8s.io` apiGroup
```
oc apply -f role-cluster-autoscaler.yaml
```

### Provision CAPOCI

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

### Create CAPI cluster

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

## Method 2. Everything automated with oci-autoscaling-operator

### Provision cluster

We create a cluster in the same way as before, just using a different terraform stack that:
- Creates a new IAM user to be used by CAPOCI
- Includes manifests to deploy oci-autoscaling-operator

#### Steps
- Create cluster in [assisted installer](https://console.redhat.com/openshift/assisted-installer)
    - Use a domain name that you can manage in Oracle Cloud
    - Enable `Integrate with external partner platforms` - `Oracle Cloud Infrastructure`
    - Create minimal ISO
    - Upload ISO to OCI bucket
    - Create pre-authenticated request for ISO in bucket
- Create OCI stack:
    - My-configuration
    - Using zip file: [create-cluster-autoscaling-v0.1.0.zip](https://github.com/javipolo/oci-openshift/releases/)
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
- CAPOCI installation in openshift requires fixing SCC issues. Added to our custom capoci repo.
- CAPOCI is unable to reconcile an existing apiserver. According to [documentation](https://oracle.github.io/cluster-api-provider-oci/gs/externally-managed-cluster-infrastructure.html#example-ocicluster-spec-with-external-infrastructure) an annotation should be enough, but when applying it, cluster never shows as Provisioned. We hacked it into CAPOCI to achieve this but we should probably do it in a better way.
- CAPOCI does not automatically set memory/cpu/resources needed annotations in MachineDeployment: `capacity.cluster-autoscaler.kubernetes.io/cpu: "6"`. See https://github.com/kubernetes-sigs/cluster-api/blob/main/docs/proposals/20210310-opt-in-autoscaling-from-zero.md
- New nodes dont pick up hostname automatically. Had to add a systemd unit to do so. We should investigate why
- Nodes need to be manually approved with `oc adm certificate approve`. Some automatic system should be created. [This is how Hypershift handles it](https://github.com/openshift/hypershift/pull/5349)
- cluster-autoscaler keeps complaining about pre-existing nodes not being handled by anything. It would be nice to tell the compoment to ignore those nodes.
