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
    namespace=capi-system
else
    namespace="$1"
fi

secret=${cluster_name}-kubeconfig

tmpdir=$(mktemp -d)
trap _cleanup exit
_cleanup(){
    rm -fr $tmpdir
}

oc create serviceaccount $cluster_name -n $namespace
oc extract -n kube-system configmap/kube-root-ca.crt --to=- > $tmpdir/cluster-ca.crt
oc adm policy add-cluster-role-to-user cluster-admin -z $cluster_name -n $namespace
oc create token $cluster_name -n $namespace --duration=8760h > $tmpdir/token

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

oc create secret generic -n $namespace $secret --from-file=value=$tmpdir/kubeconfig --type=cluster.x-k8s.io/secret
oc label secret -n $namespace $secret cluster.x-k8s.io/cluster-name=$cluster_name clusterctl.cluster.x-k8s.io/move=""

echo "Created kubeconfig for $cluster_name in secret $namespace/$secret"
