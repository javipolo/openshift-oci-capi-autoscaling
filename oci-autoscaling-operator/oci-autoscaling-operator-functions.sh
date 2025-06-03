log_it(){
    echo "$(date '+%F %T') $*"
}

# Wait for a service to be up
# do_wait name-of-service function-that-checks-health
do_wait(){
    local name function max_wait_cycles wait_seconds count
    name=$1
    function=$2

    # Wait 5 min max for a service to be up
    max_wait_cycles=60
    wait_seconds=5

    count=1
    until $function; do
        if [[ $count -gt $max_wait_cycles ]]; then
            log_it "Tired of waiting for $name. Exiting"
            return 1
        fi
        sleep $wait_seconds
    done
}

single-deployment-healthy(){
    local namespace deployment
    namespace=$1
    deployment=$2
    oc get deploy -n $namespace $deployment -ojson \
        | jq -r 'select(.status.conditions[]? | select(.type == "Available" and .status == "True")) | .metadata.name' \
        | grep -q .
}

deployments-healthy(){
    local namespace deployments deployment
    namespace=$1
    shift
    deployments="$*"
    for deployment in $deployments; do
        single-deployment-healthy $namespace $deployment || return 1
    done
    return 0
}

get-configuration(){
    # Extract the data of configmaps and secrets to files
    log_it "Getting configuration out of configmap/secret"
    mkdir -p $config_dir
    oc extract --confirm --namespace $namespace configmap/$configmap_name --to=$config_dir
    oc extract --confirm --namespace $namespace configmap/$autoscaler_config --to=$config_dir
    oc extract --confirm --namespace $namespace secret/$secret_name --to=$config_dir

    export capi_namespace
    export cluster_name=$(oc get infrastructure cluster -ojsonpath='{.status.infrastructureName}')
    export compartment=$(cat $config_dir/ociCompartmentId)
    export oci_cluster_name=$(echo "$cluster_name" | rev | cut -d - -f 2- | rev)
    export vcn=$(cat $config_dir/ociVcnId)
    export apiserver_lb=$(cat $config_dir/ociApiserverLb)
    export control_plane_endpoint=$(cat $config_dir/controlPlaneEndpoint)
    export subnet=$(cat $config_dir/ociSubnetId)
    export nsg=$(cat $config_dir/ociNSGId)
    export image=$(cat $config_dir/ociImageId)

    export autoscaling_shape=$(cat $config_dir/ociAutoscalingShape)
    export autoscaling_shapeconfig_cpu=$(cat $config_dir/ociAutoscalingShapeConfigCPUs)
    export autoscaling_shapeconfig_memory=$(cat $config_dir/ociAutoscalingShapeConfigMemory)
    export autoscaling_nodegroup_min=$(cat $config_dir/ociAutoscalingNodegroupMin)
    export autoscaling_nodegroup_max=$(cat $config_dir/ociAutoscalingNodegroupMax)
}

create-manifests(){
    mkdir -p /tmp/manifests
    for i in templates/*.yaml; do
        envsubst < $i > /tmp/manifests/$(basename $i)
    done
}



# cert-manager
cert-manager-healthy(){
    deployments-healthy cert-manager "cert-manager cert-manager-cainjector cert-manager-webhook"
}

cert-manager-provision(){
    log_it "Running cert-manager provision"
    kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/$cert_manager_version/cert-manager.yaml
}

# Cluster API (CAPI)
capi-healthy(){
    deployments-healthy ${capi_namespace} capi-controller-manager
}

capi-provision(){
    log_it "Running CAPI provision"
    clusterctl generate provider --core cluster-api | grep -vE 'runAs(User|Group)' | oc apply -f -
}

# CAPI Oracle Cloud infrastructure provider (CAPOCI)
capoci-healthy(){
    deployments-healthy cluster-api-provider-oci-system capoci-controller-manager
}

capoci-provision-config(){
    mkdir -p $capoci_git_dir/config/default/private
    cat << EOF > $capoci_git_dir/config/default/private/oci.env
tenancy=$(cat $config_dir/capociTenancyId)
user=$(cat $config_dir/capociUserId)
fingerprint=$(cat $config_dir/capociFingerprint)
region=$(cat $config_dir/capociRegion)
useInstancePrincipal=$(cat $config_dir/capociUseInstancePrincipal)
passphrase=$(cat $config_dir/capociPassphrase)
EOF

cat $config_dir/capociCertificate > $capoci_git_dir/config/default/private/key
chmod 400 $capoci_git_dir/config/default/private/*
}

capoci-provision(){
    if [ ! -d $capoci_git_dir ]; then
        git clone --depth 1 --branch $capoci_branch $capoci_repo $capoci_git_dir
    fi
    capoci-provision-config

    make -C $capoci_git_dir deploy
}

# cluster-autoscaler
autoscaler-healthy(){
    deployments-healthy ${capi_namespace} oci-cluster-autoscaler
}

autoscaler-provision(){
    helm repo add autoscaler https://kubernetes.github.io/autoscaler
    helm repo update
    helm upgrade --install  oci-cluster-autoscaler autoscaler/cluster-autoscaler --values cluster-autoscaler-values.yaml --namespace ${capi_namespace}
    oc apply -f role-cluster-autoscaler.yaml
}
