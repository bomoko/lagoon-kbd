#!/bin/bash

#KIND_VER=v1.13.12
#KIND_VER=v1.14.10
#KIND_VER=v1.15.7
#KIND_VER=v1.16.4
KIND_VER=v1.17.5
# or get the latest tagged version of a specific k8s version of kind
#KIND_VER=$(curl -s https://hub.docker.com/v2/repositories/kindest/node/tags | jq -r '.results | .[].name' | grep 'v1.17' | sort -Vr | head -1)
KIND_NAME=kbd-operator-test
OPERATOR_IMAGE=amazeeio/lagoon-builddeploy:test-tag


BUILD_OPERATOR=true
OPERATOR_NAMESPACE=lagoon-builddeploy
if [ ! -z "$BUILD_OPERATOR" ]; then
    OPERATOR_NAMESPACE=lagoon-kbd-system
fi
CHECK_TIMEOUT=10

NS=drupal-example-install
LBUILD=lagoon-build-7m5zypx

check_operator_log () {
    echo "=========== OPERATOR LOG ============"
    kubectl logs $(kubectl get pods  -n ${OPERATOR_NAMESPACE} --no-headers | awk '{print $1}') -c manager -n ${OPERATOR_NAMESPACE}
    if $(kubectl logs $(kubectl get pods  -n ${OPERATOR_NAMESPACE} --no-headers | awk '{print $1}') -c manager -n ${OPERATOR_NAMESPACE} | grep -q "Build ${LBUILD} Failed")
    then
        # build failed, exit 1
        tear_down
        exit 1
    fi
}

tear_down () {
    echo "============= TEAR DOWN ============="
    kind delete cluster --name ${KIND_NAME}
    docker-compose down
}

start_up () {
    echo "================ BEGIN ================"
    echo "==> Bring up local provider"
    docker-compose up -d
    CHECK_COUNTER=1
    echo "==> Ensure mariadb database provider is running"
    mariadb_start_check
}

mariadb_start_check () {
    until $(docker-compose exec -T mysql mysql --host=local-dbaas-mariadb-provider --port=3306 -uroot -e 'show databases;' | grep -q "information_schema")
    do
    if [ $CHECK_COUNTER -lt $CHECK_TIMEOUT ]; then
        let CHECK_COUNTER=CHECK_COUNTER+1
        echo "Database provider not running yet"
        sleep 5
    else
        echo "Timeout of $CHECK_TIMEOUT for database provider startup reached"
        exit 1
    fi
    done
}

start_kind () {
    echo "==> Start kind ${KIND_VER}" 

    TEMP_DIR=$(mktemp -d /tmp/cluster-api.XXXX)
    ## configure KinD to talk to our insecure registry
    cat << EOF > ${TEMP_DIR}/kind-config.json
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
containerdConfigPatches:
# configure a local insecure registry
- |-
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors."172.17.0.1:5000"]
    endpoint = ["http://172.17.0.1:5000"]
EOF
    ## create the cluster now
    kind create cluster --image kindest/node:${KIND_VER} --name ${KIND_NAME} --config ${TEMP_DIR}/kind-config.json

    kubectl cluster-info --context kind-${KIND_NAME}

    echo "==> Switch kube context to kind" 
    kubectl config use-context kind-${KIND_NAME}

    ## add the bulk storageclass for builds to use
    cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: bulk
provisioner: rancher.io/local-path
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
EOF
}

build_deploy_operator () {
    echo "==> Build and deploy operator"
    make test
    make docker-build IMG=${OPERATOR_IMAGE}
    kind load docker-image ${OPERATOR_IMAGE} --name ${KIND_NAME}
    make deploy IMG=${OPERATOR_IMAGE}

    CHECK_COUNTER=1
    echo "==> Ensure operator is running"
    until $(kubectl get pods  -n ${OPERATOR_NAMESPACE} --no-headers | grep -q "Running")
    do
    if [ $CHECK_COUNTER -lt $CHECK_TIMEOUT ]; then
        let CHECK_COUNTER=CHECK_COUNTER+1
        echo "Operator not running yet"
        sleep 5
    else
        echo "Timeout of $CHECK_TIMEOUT for operator startup reached"
        check_operator_log
        tear_down
        echo "================ END ================"
        exit 1
    fi
    done
    echo "==> Operator is running"
}


check_lagoon_build () {

    CHECK_COUNTER=1
    echo "==> Check build progress"
    until $(kubectl get pods  -n ${NS} --no-headers | grep -iq "Running")
    do
    if [ $CHECK_COUNTER -lt $CHECK_TIMEOUT ]; then
        # if $(kubectl -n ${NS} get lagoonbuilds/${LBUILD} -o yaml | grep -q "lagoon.sh/buildStatus: Failed"); then
        #     echo "=========== BUILD LOG ============"
        #     kubectl -n ${NS} get lagoonbuilds/${LBUILD} -o yaml
        #     kubectl logs $(kubectl get pods  -n ${NS} --no-headers | awk '{print $1}') -c lagoon-build -n ${NS}
        #     exit 1
        # fi
        let CHECK_COUNTER=CHECK_COUNTER+1
        echo "Build not running yet"
        sleep 30
    else
        echo "Timeout of $CHECK_TIMEOUT for operator startup reached"
        echo "=========== BUILD LOG ============"
        kubectl -n ${NS} get lagoonbuilds/${LBUILD} -o yaml
        # kubectl -n ${NS} logs lagoon-build-7m5zypx -f
        # kubectl logs $(kubectl get pods  -n ${NS} --no-headers | awk '{print $1}') -c lagoon-build -n ${NS}
        check_operator_log
        tear_down
        echo "================ END ================"
        exit 1
    fi
    done
    echo "==> Build running"
    kubectl -n ${NS} logs lagoon-build-7m5zypx -f
    # kubectl -n ${NS} get lagoonbuilds/${LBUILD} -o yaml
}

start_up
start_kind

echo "==> Configure example environment"
echo "====> Install build deploy operator"
if [ ! -z "$BUILD_OPERATOR" ]; then
    build_deploy_operator
else
    kubectl create namespace lagoon-builddeploy
    helm repo add lagoon-builddeploy https://raw.githubusercontent.com/amazeeio/lagoon-kbd/main/charts
    helm upgrade --install -n lagoon-builddeploy lagoon-builddeploy lagoon-builddeploy/lagoon-builddeploy \
        --set vars.lagoonTargetName=ci-local-operator-k8s \
        --set vars.rabbitPassword=guest \
        --set vars.rabbitUsername=guest \
        --set vars.rabbitHostname=172.17.0.1:5672
fi

echo "====> Install lagoon-remote docker-host"
kubectl create namespace lagoon
helm repo add lagoon-remote https://raw.githubusercontent.com/amazeeio/lagoon/master/charts
## configure the docker-host to talk to our insecure registry
helm upgrade --install -n lagoon lagoon-remote lagoon-remote/lagoon-remote --set dockerHost.registry=172.17.0.1:5000
kubectl -n lagoon rollout status deployment docker-host -w

echo "====> Install dbaas-operator"
kubectl create namespace dbaas-operator
helm repo add dbaas-operator https://raw.githubusercontent.com/amazeeio/dbaas-operator/master/charts
helm upgrade --install -n dbaas-operator dbaas-operator dbaas-operator/dbaas-operator
helm upgrade --install -n dbaas-operator mariadbprovider dbaas-operator/mariadbprovider -f test-resources/helm-values-mariadbprovider.yml

sleep 20

echo "==> Trigger a lagoon build"
kubectl -n default apply -f test-resources/example-project1.yaml
sleep 10
check_lagoon_build

check_operator_log
tear_down
echo "================ END ================"