# OpenShift Cluster Autoscaling on Oracle Cloud Infrastructure with CAPI: A Complete Guide

OpenShift cluster autoscaling enables your Kubernetes clusters to dynamically adjust the number of worker nodes based on workload demands. This capability is essential for optimizing resource utilization and costs in cloud environments. In this comprehensive guide, we'll walk through implementing cluster autoscaling for OpenShift running on Oracle Cloud Infrastructure (OCI) using the Cluster API (CAPI) framework.

## Understanding the Architecture

Before diving into implementation, let's understand the key components:

- **Cluster API (CAPI)**: A Kubernetes project that provides declarative APIs and tooling to manage cluster lifecycle
- **CAPOCI**: The OCI infrastructure provider for Cluster API
- **cluster-autoscaler**: The component that monitors pod resource requests and scales nodes accordingly
- **cert-manager**: Provides certificate management for the CAPI components

The architecture works by having the cluster-autoscaler monitor pending pods and communicate with CAPI to scale MachineDeployments, which in turn provision or terminate OCI compute instances.

## Prerequisites

Before starting, ensure you have:

1. **Oracle Cloud CLI (oci-cli)** installed and configured with proper credentials
2. **OpenShift CLI (oc)** - The OpenShift command line tool
3. **clusterctl** - The Cluster API management tool
4. **Helm** - Package manager for Kubernetes (for installing cluster-autoscaler)
5. **An existing OpenShift cluster on OCI** with external platform integration enabled
6. **Administrative access** to the OpenShift cluster
7. **A custom RHCOS image** in your OCI tenancy (we'll cover this)
8. **Domain management** capabilities in OCI for your cluster's domain

## Method 1: Manual Component Installation

This method provides full control and understanding of each component. We'll install and configure everything step by step.

### Step 0: Create Dedicated OCI User for CAPOCI

Before starting the installation, create a dedicated OCI user for CAPOCI operations instead of using your personal account. This follows the principle of least privilege and improves security.

#### Create the CAPOCI User

1. **Navigate to Identity & Security → Users** in the OCI Console
2. **Create a new user**:
   - Name: `capoci-service-user`
   - Description: `Service user for Cluster API Provider OCI operations`
   - Email: Use a service email or your email for notifications

#### Generate API Key for the User

1. **Click on the newly created user**
2. **Go to API Keys → Add API Key**
3. **Generate API Key Pair**:
   - Download both the private key and copy the configuration snippet
   - Save the private key securely (e.g., `~/.oci/capoci_api_key.pem`)

The configuration snippet will look like:
```
[DEFAULT]
user=ocid1.user.oc1..aaaaaaaxxxxx
fingerprint=xx:xx:xx:xx:xx:xx:xx:xx:xx:xx:xx:xx:xx:xx:xx:xx
tenancy=ocid1.tenancy.oc1..aaaaaaaxxxxx
region=us-ashburn-1
key_file=<path to your private keyfile> # TODO
```

#### Create IAM Policies for CAPOCI User

Create the necessary IAM policies to grant the minimal required permissions:

```bash
# Create a group for CAPOCI users
oci iam group create --compartment-id <your-tenancy-ocid> --name capoci-users --description "Users for Cluster API Provider OCI"

# Add the user to the group
oci iam group add-user --group-id <capoci-group-ocid> --user-id <capoci-user-ocid>
```

**Create the following IAM policies** in your tenancy (adjust compartment names as needed):

1. **Core Compute Management Policy**:
```
Policy Name: capoci-compute-management
Description: Allows CAPOCI to manage compute instances
Compartment: root (or your specific compartment)
Policy Statements:
Allow group capoci-users to manage instances in compartment <your-compartment-name>
Allow group capoci-users to manage instance-configurations in compartment <your-compartment-name>
Allow group capoci-users to manage instance-pools in compartment <your-compartment-name>
Allow group capoci-users to read images in compartment <your-compartment-name>
Allow group capoci-users to manage volume-attachments in compartment <your-compartment-name>
Allow group capoci-users to manage volumes in compartment <your-compartment-name>
```

2. **Networking Management Policy**:
```
Policy Name: capoci-network-management
Description: Allows CAPOCI to manage networking resources
Compartment: root (or your specific compartment)
Policy Statements:
Allow group capoci-users to use virtual-network-family in compartment <your-compartment-name>
Allow group capoci-users to manage network-security-groups in compartment <your-compartment-name>
Allow group capoci-users to manage load-balancers in compartment <your-compartment-name>
```

3. **Additional Read Permissions**:
```
Policy Name: capoci-read-permissions
Description: Allows CAPOCI to read necessary resources
Compartment: root (or your specific compartment)
Policy Statements:
Allow group capoci-users to read compartments in tenancy
Allow group capoci-users to read availability-domains in compartment <your-compartment-name>
Allow group capoci-users to read fault-domains in compartment <your-compartment-name>
```

#### Alternative: Using OCI CLI Commands

You can also create these policies using the OCI CLI:

```bash
# Get your tenancy and compartment OCIDs
TENANCY_OCID=$(oci iam compartment list --all --compartment-id-in-subtree true --access-level ACCESSIBLE --include-root --raw-output --query "data[?name=='<root>'].id | [0]")
COMPARTMENT_OCID="your-compartment-ocid"  # Replace with your compartment OCID
COMPARTMENT_NAME="your-compartment-name"  # Replace with your compartment name

# Create the group
GROUP_OCID=$(oci iam group create --compartment-id $TENANCY_OCID --name capoci-users --description "Users for Cluster API Provider OCI" --query "data.id" --raw-output)

# Add user to group (replace with your CAPOCI user OCID)
CAPOCI_USER_OCID="your-capoci-user-ocid"
oci iam group add-user --group-id $GROUP_OCID --user-id $CAPOCI_USER_OCID

# Create compute management policy
oci iam policy create --compartment-id $TENANCY_OCID --name capoci-compute-management --description "Allows CAPOCI to manage compute instances" --statements '["Allow group capoci-users to manage instances in compartment '$COMPARTMENT_NAME'","Allow group capoci-users to manage instance-configurations in compartment '$COMPARTMENT_NAME'","Allow group capoci-users to manage instance-pools in compartment '$COMPARTMENT_NAME'","Allow group capoci-users to read images in compartment '$COMPARTMENT_NAME'","Allow group capoci-users to manage volume-attachments in compartment '$COMPARTMENT_NAME'","Allow group capoci-users to manage volumes in compartment '$COMPARTMENT_NAME'"]'

# Create network management policy
oci iam policy create --compartment-id $TENANCY_OCID --name capoci-network-management --description "Allows CAPOCI to manage networking resources" --statements '["Allow group capoci-users to use virtual-network-family in compartment '$COMPARTMENT_NAME'","Allow group capoci-users to manage network-security-groups in compartment '$COMPARTMENT_NAME'","Allow group capoci-users to manage load-balancers in compartment '$COMPARTMENT_NAME'"]'

# Create read permissions policy
oci iam policy create --compartment-id $TENANCY_OCID --name capoci-read-permissions --description "Allows CAPOCI to read necessary resources" --statements '["Allow group capoci-users to read compartments in tenancy","Allow group capoci-users to read availability-domains in compartment '$COMPARTMENT_NAME'","Allow group capoci-users to read fault-domains in compartment '$COMPARTMENT_NAME'"]'
```

#### Security Best Practices

1. **Principle of Least Privilege**: The policies above provide only the minimum permissions needed for CAPOCI operations
2. **Regular Key Rotation**: Rotate the API keys periodically
3. **Monitor Usage**: Use OCI audit logs to monitor the service user's activity
4. **Separate Compartments**: Consider using dedicated compartments for different environments (dev/staging/prod)

**Note**: You'll use the CAPOCI service user's credentials in the CAPOCI configuration instead of your personal credentials in the upcoming steps.

### Step 1: Provision Your Base OpenShift Cluster

1. **Create cluster in Red Hat's Assisted Installer**:
   - Navigate to [Red Hat's Assisted Installer Console](https://console.redhat.com/openshift/assisted-installer)
   - Use a domain name that you can manage in Oracle Cloud DNS
   - Enable "Integrate with external partner platforms" and select "Oracle Cloud Infrastructure"
   - Create a minimal ISO (no need for full customization at this stage)
   - Upload the ISO to an OCI Object Storage bucket
   - Create a pre-authenticated request for the ISO in the bucket

2. **Deploy OCI Infrastructure Stack**:
   - In OCI Console, go to Resource Manager → Stacks
   - Create a new stack using the zip file: [create-cluster-v0.1.0.zip](https://github.com/dfoster-oracle/oci-openshift/releases/)
   - Configure the stack parameters:
     - Set cluster name to match your Assisted Installer cluster name
     - Copy the pre-authenticated request URL into "Openshift image source URI"
     - Set "zone DNS" to the same domain used in Assisted Installer
     - Configure other parameters (network, compute shapes, etc.) as needed
   - Run "Apply" on the stack

3. **Configure Node Roles**:
   - Return to Assisted Installer UI
   - Add an `oci.yml` custom manifest
   - Copy the content from the OCI stack output `dynamic_custom_manifest`
   - Set node roles appropriately

4. **Complete Cluster Installation**:
   - Download the kubeconfig file
   - Wait for cluster installation to complete
   - Monitor with: `oc get clusterversion` and `oc get clusteroperators`

### Step 2: Create Custom RHCOS Image

You need a custom Red Hat CoreOS image in your OCI tenancy for the autoscaling nodes:

1. **Download RHCOS Image**:
   ```bash
   wget https://mirror.openshift.com/pub/openshift-v4/x86_64/dependencies/rhcos/4.18/latest/rhcos-4.18.1-x86_64-openstack.x86_64.qcow2.gz
   gunzip rhcos-4.18.1-x86_64-openstack.x86_64.qcow2.gz
   ```

2. **Import to OCI**:
   - Follow Oracle's documentation: [Create a Custom Linux Image](https://docs.public.oneportal.content.oci.oraclecloud.com/en-us/iaas/compute-cloud-at-customer/topics/images/importing-custom-linux-imges.htm)
   - Upload the qcow2 file to OCI and create a custom image
   - Note the image OCID for later use

### Step 3: Install cert-manager

cert-manager provides certificate management for CAPI components:

```bash
oc apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.9.1/cert-manager.yaml
```

Wait for cert-manager to be ready:
```bash
oc wait --for=condition=Available --timeout=300s deployment/cert-manager -n cert-manager
oc wait --for=condition=Available --timeout=300s deployment/cert-manager-cainjector -n cert-manager
oc wait --for=condition=Available --timeout=300s deployment/cert-manager-webhook -n cert-manager
```

### Step 4: Install Core Cluster API

Install the upstream CAPI core components with OpenShift-specific security context adjustments:

```bash
clusterctl generate provider --core cluster-api | grep -vE 'runAs(User|Group)' | oc apply -f -
```

The `grep -vE 'runAs(User|Group)'` removes security context constraints that conflict with OpenShift's default security policies.

Wait for CAPI to be ready:
```bash
oc wait --for=condition=Available --timeout=300s deployment/capi-controller-manager -n capi-system
```

### Step 5: Install cluster-autoscaler

Install the cluster-autoscaler using Helm with CAPI provider:

```bash
# Add the autoscaler Helm repository
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm repo update

# Create values file for cluster-autoscaler
cat > cluster-autoscaler-values.yaml << EOF
cloudProvider: clusterapi
fullnameOverride: oci-cluster-autoscaler
autoDiscovery:
  namespace: capi-system
rbac:
  create: true
  serviceAccount:
    create: true
    name: oci-cluster-autoscaler
EOF

# Install cluster-autoscaler
helm install oci-cluster-autoscaler autoscaler/cluster-autoscaler \
  --values cluster-autoscaler-values.yaml \
  --namespace capi-system
```

### Step 6: Configure cluster-autoscaler RBAC

The cluster-autoscaler needs additional permissions to work with CAPI resources:

```bash
cat > role-cluster-autoscaler.yaml << EOF
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: oci-cluster-autoscaler-extra
rules:
  - apiGroups:
    - infrastructure.cluster.x-k8s.io
    resources:
    - "*"
    verbs:
    - get
    - list
    - watch
    - update

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: oci-cluster-autoscaler-extra
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: oci-cluster-autoscaler-extra
subjects:
  - kind: ServiceAccount
    name: oci-cluster-autoscaler
    namespace: capi-system
EOF

oc apply -f role-cluster-autoscaler.yaml
```

### Step 7: Install CAPOCI (Cluster API Provider OCI)

Install CAPOCI using the official method with `clusterctl`:

**Configure OCI Credentials**:

First, set up your OCI credentials using the dedicated CAPOCI service user created in Step 0. You can either export them as environment variables or configure them in the clusterctl configuration file.

**Option 1: Environment Variables (Recommended)**
```bash
# Set OCI credentials for the dedicated CAPOCI service user
export OCI_TENANCY_ID="your-tenancy-ocid"
export OCI_USER_ID="your-capoci-service-user-ocid"  # Use the CAPOCI service user OCID
export OCI_REGION="your-region"
export OCI_FINGERPRINT="your-capoci-service-user-api-key-fingerprint"  # From the service user's API key
export OCI_PRIVATE_KEY_PATH="~/.oci/capoci_api_key.pem"  # Path to the service user's private key

# Alternatively, you can set the private key content directly
export OCI_PRIVATE_KEY="$(cat ~/.oci/capoci_api_key.pem)"
```

**Option 2: clusterctl Configuration File**
```bash
# Create the clusterctl config directory
mkdir -p ~/.config/cluster-api

# Create clusterctl configuration file
cat > ~/.config/cluster-api/clusterctl.yaml << EOF
providers:
  - name: "oci"
    url: "https://github.com/oracle/cluster-api-provider-oci/releases/latest/infrastructure-components.yaml"
    type: "InfrastructureProvider"
EOF
```

**Install CAPOCI using clusterctl**:

```bash
# Initialize CAPOCI using the official method
clusterctl init --infrastructure oci
```

Wait for CAPOCI to be ready:
```bash
oc wait --for=condition=Available --timeout=300s deployment/capoci-controller-manager -n capoci-system
```

**Note**: If you need specific customizations or patches (like skipping API LoadBalancer management for existing clusters), you may need to modify the deployed manifests after installation or use a custom provider URL pointing to a modified version of the provider manifests.

### Step 8: Create Bootstrap Ignition Configuration

Create the ignition configuration that new worker nodes will use to join the cluster:

```bash
#!/bin/bash
set -euo pipefail

# Get cluster information
cluster_name=$(oc get infrastructure cluster -ojsonpath='{.status.infrastructureName}')
namespace=capi-system
secret="${cluster_name}-bootstrap"

# Create temporary directory
tmpdir=$(mktemp -d)
trap "rm -rf $tmpdir" EXIT

# Get required cluster certificates and endpoints
export MACHINECONFIG_CA=$(oc get secret -n openshift-machine-config-operator machine-config-server-tls -o jsonpath='{.data.tls\.crt}')
export API_INT_HOST=$(oc get infrastructure cluster -o jsonpath='{.status.apiServerInternalURI}' | cut -d / -f 3- | cut -d : -f 1)

# Create the bootstrap ignition template
mkdir -p $tmpdir/secret
echo ignition > $tmpdir/secret/format

cat > $tmpdir/bootstrap-ignition.json << 'EOF'
{
  "ignition": {
    "config": {
      "merge": [
        {
          "source": "https://${API_INT_HOST}:22623/config/worker"
        }
      ]
    },
    "security": {
      "tls": {
        "certificateAuthorities": [
          {
            "source": "data:text/plain;charset=utf-8;base64,${MACHINECONFIG_CA}"
          }
        ]
      }
    },
    "version": "3.2.0"
  }
}
EOF

# Create hostname setting ignition for OCI
cat > $tmpdir/set-hostname-oci-ignition.json << 'EOF'
{
  "systemd": {
    "units": [
      {
        "enabled": true,
        "name": "set-hostname-oci.service",
        "contents": "[Unit]\nDescription=Set hostname from OCI metadata\nAfter=network-online.target\nWants=network-online.target\n[Service]\nType=oneshot\nExecStart=/usr/local/bin/set-hostname-oci.sh\n[Install]\nWantedBy=multi-user.target\n"
      }
    ]
  },
  "storage": {
    "files": [
      {
        "path": "/usr/local/bin/set-hostname-oci.sh",
        "mode": 493,
        "contents": {
          "source": "data:text/plain;charset=utf-8;base64,IyEvYmluL2Jhc2gKc2V0IC1ldW8gcGlwZWZhaWwKCiMgR2V0IGhvc3RuYW1lIGZyb20gT0NJIG1ldGFkYXRhCmhvc3RuYW1lPSQoY3VybCAtcyBodHRwOi8vMTY5LjI1NC4xNjkuMjU0L29wYy92Mi9pbnN0YW5jZS8gfCBqcSAtciAuZGlzcGxheU5hbWUpCgppZiBbIC1uICIkaG9zdG5hbWUiIF07IHRoZW4KICAgIGVjaG8gIlNldHRpbmcgaG9zdG5hbWUgdG8gJGhvc3RuYW1lIgogICAgaG9zdG5hbWVjdGwgc2V0LWhvc3RuYW1lICIkaG9zdG5hbWUiCmVsc2UKICAgIGVjaG8gIkZhaWxlZCB0byBnZXQgaG9zdG5hbWUgZnJvbSBPQ0kgbWV0YWRhdGEiCiAgICBleGl0IDEKZmkK"
        }
      }
    ]
  }
}
EOF

# Process the template and merge with hostname setting
envsubst < $tmpdir/bootstrap-ignition.json > $tmpdir/processed-ignition.json
jq '.systemd += input.systemd' $tmpdir/processed-ignition.json $tmpdir/set-hostname-oci-ignition.json \
    | jq '.storage += input.storage' - $tmpdir/set-hostname-oci-ignition.json > $tmpdir/secret/value

# Create the secret
oc create -n $namespace secret generic $secret --from-file=$tmpdir/secret --dry-run=client -o yaml | oc apply -f -

echo "Created bootstrap ignition secret: $namespace/$secret"
```

### Step 9: Create Kubeconfig for CAPI Cluster

CAPI needs a kubeconfig to manage the "child" cluster (which is actually the same cluster):

```bash
#!/bin/bash
set -euo pipefail

# Get cluster information
cluster_name=$(oc get infrastructure cluster -ojsonpath='{.status.infrastructureName}')
namespace=capi-system
secret="${cluster_name}-kubeconfig"

# Check if secret already exists
if oc get secret -n $namespace $secret >/dev/null 2>&1; then
    echo "Secret $secret already exists, skipping creation"
    exit 0
fi

# Create temporary directory
tmpdir=$(mktemp -d)
trap "rm -rf $tmpdir" EXIT

# Create service account and get token
oc create serviceaccount $cluster_name -n $namespace
oc extract -n kube-system configmap/kube-root-ca.crt --to=- > $tmpdir/cluster-ca.crt
oc adm policy add-cluster-role-to-user cluster-admin -z $cluster_name -n $namespace
oc create token $cluster_name -n $namespace --duration=8760h > $tmpdir/token

# Create kubeconfig
cat > $tmpdir/kubeconfig << EOF
apiVersion: v1
kind: Config
clusters:
- name: $cluster_name
  cluster:
    certificate-authority-data: $(base64 -w0 < $tmpdir/cluster-ca.crt)
    server: https://kubernetes.default.svc
contexts:
- name: $cluster_name
  context:
    cluster: $cluster_name
    namespace: $namespace
    user: $cluster_name
current-context: $cluster_name
users:
- name: $cluster_name
  user:
    token: $(cat $tmpdir/token)
EOF

# Create the secret with proper labels
oc create secret generic -n $namespace $secret --from-file=value=$tmpdir/kubeconfig --type=cluster.x-k8s.io/secret
oc label secret -n $namespace $secret cluster.x-k8s.io/cluster-name=$cluster_name clusterctl.cluster.x-k8s.io/move=""

echo "Created kubeconfig secret: $namespace/$secret"
```

### Step 10: Create CAPI Manifests

Now we'll create the CAPI resources that define our autoscaling infrastructure:

```bash
#!/bin/bash
set -euo pipefail

# Configuration - adjust these values for your environment
export compartment="ocid1.compartment.oc1..your-compartment-ocid"
export autoscaling_nodegroup_min=0
export autoscaling_nodegroup_max=5
export autoscaling_shape=VM.Standard.E4.Flex
export autoscaling_shapeconfig_cpu=6
export autoscaling_shapeconfig_memory=16

# Auto-discover cluster information
cluster_name=$(oc get infrastructure cluster -ojsonpath='{.status.infrastructureName}')
export oci_cluster_name=$(echo "$cluster_name" | rev | cut -d - -f 2- | rev)
export capi_namespace=capi-system
export cluster_name

# Auto-discover OCI resources
nsg_name=cluster-compute-nsg
subnet_name=private
image_name=rhcos-vanilla-openstack  # Your custom image name

vcn=$(oci network vcn list --compartment-id "$compartment" --display-name "$oci_cluster_name" | jq -r '.data[0].id')
apiserver_lb=$(oci lb load-balancer list --compartment-id $compartment --display-name ${oci_cluster_name}-openshift_api_apps_lb | jq -r '.data[].id')
control_plane_endpoint=$(oci lb load-balancer list --compartment-id $compartment --display-name ${oci_cluster_name}-openshift_api_apps_lb | jq -r '.data[]."ip-addresses"[] | select(."is-public" == true) | ."ip-address"')
subnet=$(oci network subnet list --compartment-id "$compartment" --vcn-id "$vcn" --display-name "$subnet_name" | jq -r '.data[0].id')
nsg=$(oci network nsg list --compartment-id "$compartment" --vcn-id "$vcn" --display-name "$nsg_name" | jq -r '.data[0].id')
image=$(oci compute image list --compartment-id "$compartment" --display-name "$image_name" | jq -r '.data[0].id')

export vcn apiserver_lb control_plane_endpoint subnet nsg image

echo "Auto-discovered values:"
echo "cluster_name=$cluster_name"
echo "vcn=$vcn"
echo "control_plane_endpoint=$control_plane_endpoint"
echo "subnet=$subnet"
echo "nsg=$nsg"
echo "image=$image"

# Create manifests directory
mkdir -p manifests

# 1. OCICluster - defines the OCI infrastructure
cat > manifests/01-ocicluster.yaml << EOF
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
kind: OCICluster
metadata:
  name: ${cluster_name}
  namespace: ${capi_namespace}
  labels:
    cluster.x-k8s.io/cluster-name: ${cluster_name}
  annotations:
    # Custom annotation to skip apiserver loadbalancer reconcile
    cluster.x-k8s.io/skip-apiserver-lb-management: "true"
spec:
  compartmentId: ${compartment}
  controlPlaneEndpoint:
    host: ${control_plane_endpoint}
    port: 6443
  networkSpec:
    apiServerLoadBalancer:
      loadBalancerId: ${apiserver_lb}
    skipNetworkManagement: true
    vcn:
      id: ${vcn}
      subnets:
      - id: ${subnet}
        name: private
        role: worker
      networkSecurityGroup:
        list:
        - id: ${nsg}
          name: cluster-compute-nsg
          role: worker
EOF

# 2. Cluster - links the infrastructure to CAPI
cat > manifests/02-cluster.yaml << EOF
---
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name: ${cluster_name}
  namespace: ${capi_namespace}
  labels:
    cluster.x-k8s.io/cluster-name: ${cluster_name}
spec:
  clusterNetwork:
    pods:
      cidrBlocks:
      - 10.128.0.0/14
    services:
      cidrBlocks:
      - 172.30.0.0/16
  controlPlaneRef:
    apiVersion: controlplane.cluster.x-k8s.io/v1beta1
    kind: KubeadmControlPlane
    name: ${cluster_name}-control-plane
  infrastructureRef:
    apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
    kind: OCICluster
    name: ${cluster_name}
EOF

# 3. OCIMachineTemplate - defines the machine template for autoscaling
cat > manifests/03-ocimachinetemplate.yaml << EOF
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
kind: OCIMachineTemplate
metadata:
  name: ${cluster_name}-autoscaling
  namespace: ${capi_namespace}
spec:
  template:
    spec:
      compartmentId: ${compartment}
      imageId: ${image}
      shape: ${autoscaling_shape}
      shapeConfig:
        ocpus: "${autoscaling_shapeconfig_cpu}"
        memoryInGBs: "${autoscaling_shapeconfig_memory}"
      subnetId: ${subnet}
      networkSecurityGroupIds:
      - ${nsg}
EOF

# 4. MachineDeployment - defines the autoscaling worker nodes
cat > manifests/04-machinedeployment.yaml << EOF
---
apiVersion: cluster.x-k8s.io/v1beta1
kind: MachineDeployment
metadata:
  name: ${oci_cluster_name}
  namespace: ${capi_namespace}
  annotations:
    capacity.cluster-autoscaler.kubernetes.io/cpu: "${autoscaling_shapeconfig_cpu}"
    capacity.cluster-autoscaler.kubernetes.io/memory: "${autoscaling_shapeconfig_memory}G"
    cluster.x-k8s.io/cluster-api-autoscaler-node-group-min-size: "${autoscaling_nodegroup_min}"
    cluster.x-k8s.io/cluster-api-autoscaler-node-group-max-size: "${autoscaling_nodegroup_max}"
spec:
  clusterName: ${cluster_name}
  selector:
    matchLabels:
  template:
    spec:
      clusterName: ${cluster_name}
      bootstrap:
        dataSecretName: ${cluster_name}-bootstrap
      infrastructureRef:
        name: ${cluster_name}-autoscaling
        namespace: ${capi_namespace}
        apiVersion: infrastructure.cluster.x-k8s.io/v1beta2
        kind: OCIMachineTemplate
EOF

echo "CAPI manifests created in manifests/ directory"
```

### Step 11: Apply CAPI Resources

Apply all the CAPI resources to enable autoscaling:

```bash
oc apply -f manifests/
```

Monitor the cluster status:
```bash
# Watch cluster status
oc get cluster -n capi-system -w

# Check machine deployment
oc get machinedeployment -n capi-system

# Monitor cluster-autoscaler logs
oc logs -f deployment/oci-cluster-autoscaler -n capi-system
```

## Method 2: Automated Installation with oci-autoscaling-operator

For a more automated approach, you can use the oci-autoscaling-operator that handles the entire installation process.

### Operator Overview

The operator is a bash-based controller that continuously reconciles the desired state by:

1. Installing cert-manager if not present
2. Installing CAPI core components if not present  
3. Installing CAPOCI if not present
4. Installing cluster-autoscaler if not present
5. Creating bootstrap ignition and kubeconfig secrets
6. Generating and applying CAPI manifests

### Using the Terraform Stack

For the automated method, use a different Terraform stack that includes the operator:

1. **Create cluster in Assisted Installer** (same as Method 1)
2. **Use the autoscaling-enabled stack**: [create-cluster-autoscaling-v0.1.0.zip](https://github.com/javipolo/oci-openshift/releases/)
3. **Configure stack parameters** (same as Method 1)
4. **Add the oci.yml manifest** from stack output

### Operator Deployment

The operator gets deployed automatically via the Terraform stack, but you can also deploy it manually:

```bash
cat > oci-autoscaling-operator-deploy.yaml << EOF
---
apiVersion: v1
kind: Namespace
metadata:
  name: capi-system

---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: oci-autoscaling-operator
  namespace: capi-system

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: oci-autoscaling-operator
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: oci-autoscaling-operator
  namespace: capi-system

---
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app.kubernetes.io/name: oci-autoscaling-operator
  name: oci-autoscaling-operator
  namespace: capi-system
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: oci-autoscaling-operator
  template:
    metadata:
      labels:
        app.kubernetes.io/name: oci-autoscaling-operator
    spec:
      containers:
      - command:
        - ./oci-autoscaling-operator.sh
        image: quay.io/jpolo/oci-autoscaling-operator-bash:latest
        name: oci-autoscaling-operator
      - command:
        - ./wait-and-sign-all-certificates.sh
        image: quay.io/jpolo/oci-autoscaling-operator-bash:latest
        name: oci-certificate-signer
      serviceAccount: oci-autoscaling-operator
      serviceAccountName: oci-autoscaling-operator
EOF

oc apply -f oci-autoscaling-operator-deploy.yaml
```

### Configuring the Operator

The operator requires configuration via ConfigMaps and Secrets:

```bash
# Example ConfigMap for operator configuration
cat > oci-autoscaling-operator-configmap.yaml << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: oci-autoscaling-operator
  namespace: capi-system
data:
  compartment: "ocid1.compartment.oc1..your-compartment-ocid"
  autoscaling_nodegroup_min: "0"
  autoscaling_nodegroup_max: "5"
  autoscaling_shape: "VM.Standard.E4.Flex"
  autoscaling_shapeconfig_cpu: "6"
  autoscaling_shapeconfig_memory: "16"
  image_name: "rhcos-vanilla-openstack"
EOF

# Example Secret for OCI credentials (using the dedicated CAPOCI service user)
cat > oci-autoscaling-operator-secret.yaml << EOF
apiVersion: v1
kind: Secret
metadata:
  name: oci-autoscaling-operator
  namespace: capi-system
type: Opaque
data:
  user: $(echo -n "ocid1.user.oc1..your-capoci-service-user-ocid" | base64)  # Use the CAPOCI service user OCID
  tenancy: $(echo -n "ocid1.tenancy.oc1..your-tenancy-ocid" | base64)
  region: $(echo -n "us-ashburn-1" | base64)
  fingerprint: $(echo -n "your:capoci:service:user:fingerprint" | base64)  # From the service user's API key
  key: $(base64 -w0 < ~/.oci/capoci_api_key.pem)  # Use the service user's private key
EOF

oc apply -f oci-autoscaling-operator-configmap.yaml
oc apply -f oci-autoscaling-operator-secret.yaml
```

## Testing Cluster Autoscaling

Once your autoscaling setup is complete, test it with a sample workload:

### Certificate Auto-Approval

First, set up automatic certificate approval for new nodes (run in a separate terminal):

```bash
openshift_wait_and_sign_certificate(){
    until oc get csr | grep Pending; do
        echo -n .
        sleep 1
    done
    oc get csr -o json | jq '.items[] | select(.status.conditions==null) | .metadata.name' -r | xargs -n1 oc adm certificate approve
}

while true; do openshift_wait_and_sign_certificate; done
```

### Scale Up Test

Create a deployment that will trigger node scaling:

```bash
# Create nginx deployment
oc create deployment nginx --namespace default --image=docker.io/nginx:latest --replicas=0

# Set resource requests to force node creation
oc set resources deployment -n default nginx --requests=memory=2Gi

# Scale up to trigger autoscaling
oc scale deployment -n default nginx --replicas=20
```

Monitor the scaling process:
```bash
# Watch machine deployments
oc get machinedeployment -n capi-system -w

# Watch cluster status
oc get cluster -n capi-system -w

# Watch nodes
oc get nodes -w

# Check cluster-autoscaler logs
oc logs -f deployment/oci-cluster-autoscaler -n capi-system
```

### Scale Down Test

Test scale-down functionality:

```bash
# Reduce replica count
oc scale deployment -n default nginx --replicas=5

# Watch for node removal (takes several minutes due to scale-down delay)
oc get nodes -w
```

## Monitoring and Troubleshooting

### Checking Component Health

Monitor the health of all components:

```bash
# Check cert-manager
oc get pods -n cert-manager

# Check CAPI
oc get pods -n capi-system

# Check CAPOCI
oc get pods -n capoci-system

# Check cluster-autoscaler status
oc get pods -n capi-system -l app=oci-cluster-autoscaler

# Check CAPI cluster status
oc get cluster -n capi-system
oc describe cluster -n capi-system
```

### Common Issues and Solutions

1. **Nodes Not Joining Cluster**: 
   - Check certificate approval process
   - Verify bootstrap ignition secret
   - Check network security group rules

2. **CAPOCI Authentication Issues**:
   - Verify OCI credentials in secret
   - Check IAM policies for the user
   - Ensure correct tenancy and compartment OCIDs

3. **cluster-autoscaler Not Scaling**:
   - Check MachineDeployment annotations
   - Verify resource requests on pods
   - Check cluster-autoscaler logs for errors

4. **Scale-down Not Working**:
   - Ensure nodes are not running system pods
   - Check node utilization levels
   - Verify scale-down delay settings

### Logs and Debugging

```bash
# cluster-autoscaler logs
oc logs deployment/oci-cluster-autoscaler -n capi-system

# CAPI controller logs
oc logs deployment/capi-controller-manager -n capi-system

# CAPOCI controller logs
oc logs deployment/capoci-controller-manager -n capoci-system

# Operator logs (if using automated method)
oc logs deployment/oci-autoscaling-operator -n capi-system
```

## Known Issues and Future Improvements

### Current Limitations

1. **Security Context Constraints**: CAPOCI requires modifications to work with OpenShift's security policies
2. **API Server Reconciliation**: The upstream CAPOCI cannot properly handle existing API servers, requiring custom patches
3. **Resource Annotations**: CAPOCI doesn't automatically set capacity annotations on MachineDeployments
4. **Hostname Setting**: New nodes require custom ignition to set hostname from OCI metadata
5. **Certificate Approval**: Manual or automated certificate approval is required for new nodes
6. **Pre-existing Nodes**: cluster-autoscaler complains about nodes not managed by CAPI

### Recommended Improvements

1. **Automated Certificate Management**: Implement automatic CSR approval for CAPI-managed nodes
2. **Better SCC Integration**: Work with upstream to properly support OpenShift security contexts
3. **Resource Discovery**: Automatic detection and annotation of node capacity
4. **Network Integration**: Better integration with OpenShift networking components
5. **Monitoring Integration**: Built-in metrics and monitoring for the autoscaling components

## Conclusion

Implementing cluster autoscaling for OpenShift on Oracle Cloud Infrastructure using CAPI provides a robust, cloud-native solution for dynamic resource management. While the setup involves multiple components and careful configuration, the result is a highly scalable infrastructure that can automatically adapt to workload demands.

The manual installation method provides full control and understanding of each component, making it ideal for production environments where you need to customize the configuration. The automated operator approach offers convenience for development and testing scenarios.

Key benefits of this solution include:

- **Cloud-native scaling**: Leverages Kubernetes-native APIs and patterns
- **Cost optimization**: Automatic scale-down reduces unused resources
- **Operational efficiency**: Reduces manual infrastructure management
- **Integration**: Works seamlessly with existing OpenShift workflows

As the Cluster API ecosystem continues to mature, we can expect improved integration, simplified setup, and enhanced features that will make cluster autoscaling even more accessible and reliable.

Remember to monitor your autoscaling behavior closely in production environments and adjust the min/max node counts and scaling policies based on your specific workload patterns and requirements. 