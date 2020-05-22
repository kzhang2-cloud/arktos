#!/usr/bin/env bash

# Copyright 2020 Authors of Arktos.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

KUBE_ROOT=$(dirname "${BASH_SOURCE[0]}")/..

source "${KUBE_ROOT}/hack/lib/common-var-init.sh"

# sanity check for OpenStack provider
if [ "${CLOUD_PROVIDER}" == "openstack" ]; then
    if [ "${CLOUD_CONFIG}" == "" ]; then
        echo "Missing CLOUD_CONFIG env for OpenStack provider!"
        exit 1
    fi
    if [ ! -f "${CLOUD_CONFIG}" ]; then
        echo "Cloud config ${CLOUD_CONFIG} doesn't exist"
        exit 1
    fi
fi

# set feature gates if enable Pod priority and preemption
if [ "${ENABLE_POD_PRIORITY_PREEMPTION}" == true ]; then
    FEATURE_GATES="${FEATURE_GATES},PodPriority=true"
fi

# warn if users are running with swap allowed
if [ "${FAIL_SWAP_ON}" == "false" ]; then
    echo "WARNING : The kubelet is configured to not fail even if swap is enabled; production deployments should disable swap."
fi

if [ "$(id -u)" != "0" ]; then
    echo "WARNING : This script MAY be run as root for docker socket / iptables functionality; if failures occur, retry as root." 2>&1
fi

# Stop right away if the build fails
set -e

# Do dudiligence to ensure containerd service and socket in a working state
# Containerd service should be part of docker.io installation or apt-get install containerd for Ubuntu OS
if ! sudo systemctl is-active --quiet containerd; then
  echo "Containerd is required for Arktos"
  exit 1
fi

if [[ ! -e "${CONTAINERD_SOCK_PATH}" ]]; then
  echo "Containerd socket file check failed. Please check containerd socket file path"
  exit 1
fi

# install cni plugin based on env var CNIPLUGIN (bridge, alktron)
source ${KUBE_ROOT}/hack/arktos-cni.rc

source "${KUBE_ROOT}/hack/lib/init.sh"
source "${KUBE_ROOT}/hack/lib/common.sh"

kube::util::ensure-gnu-sed

function usage {
            echo "This script starts a local kube cluster. "
            echo "Example 0: hack/local-up-cluster.sh -h  (this 'help' usage description)"
            echo "Example 1: hack/local-up-cluster.sh -o _output/dockerized/bin/linux/amd64/ (run from docker output)"
            echo "Example 2: hack/local-up-cluster.sh -O (auto-guess the bin path for your platform)"
            echo "Example 3: hack/local-up-cluster.sh (build a local copy of the source)"
}

# This function guesses where the existing cached binary build is for the `-O`
# flag
function guess_built_binary_path {
  local hyperkube_path
  hyperkube_path=$(kube::util::find-binary "hyperkube")
  if [[ -z "${hyperkube_path}" ]]; then
    return
  fi
  echo -n "$(dirname "${hyperkube_path}")"
}

### Allow user to supply the source directory.
GO_OUT=${GO_OUT:-}
while getopts "ho:O" OPTION
do
    case ${OPTION} in
        o)
            echo "skipping build"
            GO_OUT="${OPTARG}"
            echo "using source ${GO_OUT}"
            ;;
        O)
            GO_OUT=$(guess_built_binary_path)
            if [ "${GO_OUT}" == "" ]; then
                echo "Could not guess the correct output directory to use."
                exit 1
            fi
            ;;
        h)
            usage
            exit
            ;;
        ?)
            usage
            exit
            ;;
    esac
done

if [ "x${GO_OUT}" == "x" ]; then
    make -C "${KUBE_ROOT}" WHAT="cmd/kubectl cmd/hyperkube cmd/kube-apiserver cmd/kube-controller-manager cmd/workload-controller-manager cmd/cloud-controller-manager cmd/kubelet cmd/kube-proxy cmd/kube-scheduler"
else
    echo "skipped the build."
fi

# Shut down anyway if there's an error.
set +e


# # name of the cgroup driver, i.e. cgroupfs or systemd
# if [[ ${CONTAINER_RUNTIME} == "docker" ]]; then
#   # default cgroup driver to match what is reported by docker to simplify local development
#   if [[ -z ${CGROUP_DRIVER} ]]; then
#     # match driver with docker runtime reported value (they must match)
#     CGROUP_DRIVER=$(docker info | grep "Cgroup Driver:" |  sed -e 's/^[[:space:]]*//'|cut -f3- -d' ')
#     echo "Kubelet cgroup driver defaulted to use: ${CGROUP_DRIVER}"
#   fi
#   if [[ -f /var/log/docker.log && ! -f "${LOG_DIR}/docker.log" ]]; then
#     ln -s /var/log/docker.log "${LOG_DIR}/docker.log"
#   fi
# fi



# Ensure CERT_DIR is created for auto-generated crt/key and kubeconfig
mkdir -p "${CERT_DIR}" &>/dev/null || sudo mkdir -p "${CERT_DIR}"
CONTROLPLANE_SUDO=$(test -w "${CERT_DIR}" || echo "sudo -E")

function test_apiserver_off {
    # For the common local scenario, fail fast if server is already running.
    # this can happen if you run local-up-cluster.sh twice and kill etcd in between.
    if [[ "${API_PORT}" -gt "0" ]]; then
        if ! curl --silent -g "${API_HOST}:${API_PORT}" ; then
            echo "API SERVER insecure port is free, proceeding..."
        else
            echo "ERROR starting API SERVER, exiting. Some process on ${API_HOST} is serving already on ${API_PORT}"
            exit 1
        fi
    fi

    if ! curl --silent -k -g "${API_HOST}:${API_SECURE_PORT}" ; then
        echo "API SERVER secure port is free, proceeding..."
    else
        echo "ERROR starting API SERVER, exiting. Some process on ${API_HOST} is serving already on ${API_SECURE_PORT}"
        exit 1
    fi
}

function detect_binary {
    # Detect the OS name/arch so that we can find our binary
    case "$(uname -s)" in
      Darwin)
        host_os=darwin
        ;;
      Linux)
        host_os=linux
        ;;
      *)
        echo "Unsupported host OS.  Must be Linux or Mac OS X." >&2
        exit 1
        ;;
    esac

    case "$(uname -m)" in
      x86_64*)
        host_arch=amd64
        ;;
      i?86_64*)
        host_arch=amd64
        ;;
      amd64*)
        host_arch=amd64
        ;;
      aarch64*)
        host_arch=arm64
        ;;
      arm64*)
        host_arch=arm64
        ;;
      arm*)
        host_arch=arm
        ;;
      i?86*)
        host_arch=x86
        ;;
      s390x*)
        host_arch=s390x
        ;;
      ppc64le*)
        host_arch=ppc64le
        ;;
      *)
        echo "Unsupported host arch. Must be x86_64, 386, arm, arm64, s390x or ppc64le." >&2
        exit 1
        ;;
    esac

   GO_OUT="${KUBE_ROOT}/_output/local/bin/${host_os}/${host_arch}"
}

cleanup()
{
  echo "Cleaning up..."
  # delete running images
  # if [[ "${ENABLE_CLUSTER_DNS}" == true ]]; then
  # Still need to figure why this commands throw an error: Error from server: client: etcd cluster is unavailable or misconfigured
  #     ${KUBECTL} --namespace=kube-system delete service kube-dns
  # And this one hang forever:
  #     ${KUBECTL} --namespace=kube-system delete rc kube-dns-v10
  # fi

  # Check if the API server is still running

  echo "Killing the following apiserver running processes"
  for APISERVER_PID_ITEM in "${APISERVER_PID_ARRAY[@]}" 
  do
      [[ -n "${APISERVER_PID_ITEM-}" ]] && mapfile -t APISERVER_PIDS < <(pgrep -P "${APISERVER_PID_ITEM}" ; ps -o pid= -p "${APISERVER_PID_ITEM}")
      [[ -n "${APISERVER_PIDS-}" ]] && sudo kill "${APISERVER_PIDS[@]}" 2>/dev/null
      echo "${APISERVER_PID_ITEM} has been killed"
  done
  #[[ -n "${APISERVER_PID-}" ]] && mapfile -t APISERVER_PIDS < <(pgrep -P "${APISERVER_PID}" ; ps -o pid= -p "${APISERVER_PID}")
  #[[ -n "${APISERVER_PIDS-}" ]] && sudo kill "${APISERVER_PIDS[@]}" 2>/dev/null

  # Check if the controller-manager is still running
  [[ -n "${CTLRMGR_PID-}" ]] && mapfile -t CTLRMGR_PIDS < <(pgrep -P "${CTLRMGR_PID}" ; ps -o pid= -p "${CTLRMGR_PID}")
  [[ -n "${CTLRMGR_PIDS-}" ]] && sudo kill "${CTLRMGR_PIDS[@]}" 2>/dev/null

  # Check if the workload-controller-manager is still running
  [[ -n "${WORKLOAD_CTLRMGR_PID-}" ]] && mapfile -t WORKLOAD_CTLRMGR_PIDS < <(pgrep -P "${WORKLOAD_CTLRMGR_PID}" ; ps -o pid= -p "${WORKLOAD_CTLRMGR_PID}")
  [[ -n "${WORKLOAD_CTLRMGR_PIDS-}" ]] && sudo kill "${WORKLOAD_CTLRMGR_PIDS[@]}" 2>/dev/null


  # Check if the kubelet is still running
  [[ -n "${KUBELET_PID-}" ]] && mapfile -t KUBELET_PIDS < <(pgrep -P "${KUBELET_PID}" ; ps -o pid= -p "${KUBELET_PID}")
  [[ -n "${KUBELET_PIDS-}" ]] && sudo kill "${KUBELET_PIDS[@]}" 2>/dev/null

  # Check if the proxy is still running
  [[ -n "${PROXY_PID-}" ]] && mapfile -t PROXY_PIDS < <(pgrep -P "${PROXY_PID}" ; ps -o pid= -p "${PROXY_PID}")
  [[ -n "${PROXY_PIDS-}" ]] && sudo kill "${PROXY_PIDS[@]}" 2>/dev/null

  # Check if the scheduler is still running
  [[ -n "${SCHEDULER_PID-}" ]] && mapfile -t SCHEDULER_PIDS < <(pgrep -P "${SCHEDULER_PID}" ; ps -o pid= -p "${SCHEDULER_PID}")
  [[ -n "${SCHEDULER_PIDS-}" ]] && sudo kill "${SCHEDULER_PIDS[@]}" 2>/dev/null

  # Check if the etcd is still running
  [[ -n "${ETCD_PID-}" ]] && kube::etcd::stop
  if [[ "${PRESERVE_ETCD}" == "false" ]]; then
    [[ -n "${ETCD_DIR-}" ]] && kube::etcd::clean_etcd_dir
  fi

  # Delete virtlet metadata and log directory
  if [[ -e "${VIRTLET_METADATA_DIR}" ]]; then
        echo "Cleanup runtime metadata folder"
        sudo rm -f -r "${VIRTLET_METADATA_DIR}"
  fi

  if [[ -e "${VIRTLET_LOG_DIR}" ]]; then
       echo "Cleanup runtime log folder"
       sudo rm -f -r "${VIRTLET_LOG_DIR}"
  fi

  exit 0
}
# Check if all processes are still running. Prints a warning once each time
# a process dies unexpectedly.
function healthcheck {
  if [[ -n "${APISERVER_PID-}" ]] && ! sudo kill -0 "${APISERVER_PID}" 2>/dev/null; then
    warning_log "API server terminated unexpectedly, see ${APISERVER_LOG}"
    APISERVER_PID=
  fi

  if [[ -n "${CTLRMGR_PID-}" ]] && ! sudo kill -0 "${CTLRMGR_PID}" 2>/dev/null; then
    warning_log "kube-controller-manager terminated unexpectedly, see ${CTLRMGR_LOG}"
    CTLRMGR_PID=
  fi

  if [[ -n "${WORKLOAD_CTLRMGR_PID-}" ]] && ! sudo kill -0 "${WORKLOAD_CTLRMGR_PID}" 2>/dev/null; then
    warning_log "workload-controller-manager terminated unexpectedly, see ${WORKLOAD_CONTROLLER_LOG}"
    WORKLOAD_CTLRMGR_PID=
  fi

  if [[ -n "${KUBELET_PID-}" ]] && ! sudo kill -0 "${KUBELET_PID}" 2>/dev/null; then
    warning_log "kubelet terminated unexpectedly, see ${KUBELET_LOG}"
    KUBELET_PID=
  fi

  if [[ -n "${PROXY_PID-}" ]] && ! sudo kill -0 "${PROXY_PID}" 2>/dev/null; then
    warning_log "kube-proxy terminated unexpectedly, see ${PROXY_LOG}"
    PROXY_PID=
  fi

  if [[ -n "${SCHEDULER_PID-}" ]] && ! sudo kill -0 "${SCHEDULER_PID}" 2>/dev/null; then
    warning_log "scheduler terminated unexpectedly, see ${SCHEDULER_LOG}"
    SCHEDULER_PID=
  fi

  if [[ -n "${ETCD_PID-}" ]] && ! sudo kill -0 "${ETCD_PID}" 2>/dev/null; then
    warning_log "etcd terminated unexpectedly"
    ETCD_PID=
  fi
}

function print_color {
  message=$1
  prefix=${2:+$2: } # add colon only if defined
  color=${3:-1}     # default is red
  echo -n "$(tput bold)$(tput setaf "${color}")"
  echo "${prefix}${message}"
  echo -n "$(tput sgr0)"
}

function warning_log {
  print_color "$1" "W$(date "+%m%d %H:%M:%S")]" 1
}

function start_etcd {
    echo "Starting etcd"
    export ETCD_LOGFILE=${LOG_DIR}/etcd.log
    kube::etcd::start
}

function set_service_accounts {
    SERVICE_ACCOUNT_LOOKUP=${SERVICE_ACCOUNT_LOOKUP:-true}
    SERVICE_ACCOUNT_KEY=${SERVICE_ACCOUNT_KEY:-/tmp/kube-serviceaccount.key}
    # Generate ServiceAccount key if needed
    if [[ ! -f "${SERVICE_ACCOUNT_KEY}" ]]; then
      mkdir -p "$(dirname "${SERVICE_ACCOUNT_KEY}")"
      openssl genrsa -out "${SERVICE_ACCOUNT_KEY}" 2048 2>/dev/null
    fi
}

function start_cloud_controller_manager {
    if [ -z "${CLOUD_CONFIG}" ]; then
      echo "CLOUD_CONFIG cannot be empty!"
      exit 1
    fi
    if [ ! -f "${CLOUD_CONFIG}" ]; then
      echo "Cloud config ${CLOUD_CONFIG} doesn't exist"
      exit 1
    fi

    node_cidr_args=()
    if [[ "${NET_PLUGIN}" == "kubenet" ]]; then
      node_cidr_args=("--allocate-node-cidrs=true" "--cluster-cidr=10.1.0.0/16")
    fi

    CLOUD_CTLRMGR_LOG=${LOG_DIR}/cloud-controller-manager.log
    ${CONTROLPLANE_SUDO} "${EXTERNAL_CLOUD_PROVIDER_BINARY:-"${GO_OUT}/hyperkube" cloud-controller-manager}" \
      --v="${LOG_LEVEL}" \
      --vmodule="${LOG_SPEC}" \
      "${node_cidr_args[@]:-}" \
      --feature-gates="${FEATURE_GATES}" \
      --cloud-provider="${CLOUD_PROVIDER}" \
      --cloud-config="${CLOUD_CONFIG}" \
      --kubeconfig "${CERT_DIR}"/controller.kubeconfig \
      --use-service-account-credentials \
      --leader-elect=false \
      --master="https://${API_HOST}:${API_SECURE_PORT}" >"${CLOUD_CTLRMGR_LOG}" 2>&1 &
    export CLOUD_CTLRMGR_PID=$!
}

# function start_kubeproxy {
#     PROXY_LOG=${LOG_DIR}/kube-proxy.log

#     cat <<EOF > /tmp/kube-proxy.yaml
# apiVersion: kubeproxy.config.k8s.io/v1alpha1
# kind: KubeProxyConfiguration
# clientConnection:
#   kubeconfig: ${CERT_DIR}/kube-proxy.kubeconfig
# hostnameOverride: ${HOSTNAME_OVERRIDE}
# mode: ${KUBE_PROXY_MODE}
# EOF
#     if [[ -n ${FEATURE_GATES} ]]; then
#       echo "featureGates:"
#       # Convert from foo=true,bar=false to
#       #   foo: true
#       #   bar: false
#       for gate in $(echo "${FEATURE_GATES}" | tr ',' ' '); do
#         echo "${gate}" | ${SED} -e 's/\(.*\)=\(.*\)/  \1: \2/'
#       done
#     fi >>/tmp/kube-proxy.yaml

#     if [[ "${REUSE_CERTS}" != true ]]; then
#         kube::common::generate_kubeproxy_certs
#     fi

#     # shellcheck disable=SC2024
#     sudo "${GO_OUT}/hyperkube" kube-proxy \
#       --v="${LOG_LEVEL}" \
#       --config=/tmp/kube-proxy.yaml \
#       --master="https://${API_HOST}:${API_SECURE_PORT}" >"${PROXY_LOG}" 2>&1 &
#     PROXY_PID=$!
# }

# function start_kubedns {
#     if [[ "${ENABLE_CLUSTER_DNS}" = true ]]; then
#         cp "${KUBE_ROOT}/cluster/addons/dns/kube-dns/kube-dns.yaml.in" kube-dns.yaml
#         ${SED} -i -e "s/{{ pillar\['dns_domain'\] }}/${DNS_DOMAIN}/g" kube-dns.yaml
#         ${SED} -i -e "s/{{ pillar\['dns_server'\] }}/${DNS_SERVER_IP}/g" kube-dns.yaml
#         ${SED} -i -e "s/{{ pillar\['dns_memory_limit'\] }}/${DNS_MEMORY_LIMIT}/g" kube-dns.yaml
#         # TODO update to dns role once we have one.
#         # use kubectl to create kubedns addon
#         ${KUBECTL} --kubeconfig="${CERT_DIR}/admin.kubeconfig" --namespace=kube-system create -f kube-dns.yaml
#         echo "Kube-dns addon successfully deployed."
#         rm kube-dns.yaml
#     fi
# }

# function start_nodelocaldns {
#   cp "${KUBE_ROOT}/cluster/addons/dns/nodelocaldns/nodelocaldns.yaml" nodelocaldns.yaml
#   sed -i -e "s/__PILLAR__DNS__DOMAIN__/${DNS_DOMAIN}/g" nodelocaldns.yaml
#   sed -i -e "s/__PILLAR__DNS__SERVER__/${DNS_SERVER_IP}/g" nodelocaldns.yaml
#   sed -i -e "s/__PILLAR__LOCAL__DNS__/${LOCAL_DNS_IP}/g" nodelocaldns.yaml
#   # use kubectl to create nodelocaldns addon
#   ${KUBECTL} --kubeconfig="${CERT_DIR}/admin.kubeconfig" --namespace=kube-system create -f nodelocaldns.yaml
#   echo "NodeLocalDNS addon successfully deployed."
#   rm nodelocaldns.yaml
# }

function start_kubedashboard {
    if [[ "${ENABLE_CLUSTER_DASHBOARD}" = true ]]; then
        echo "Creating kubernetes-dashboard"
        # use kubectl to create the dashboard
        ${KUBECTL} --kubeconfig="${CERT_DIR}/admin.kubeconfig" apply -f "${KUBE_ROOT}/cluster/addons/dashboard/dashboard-secret.yaml"
        ${KUBECTL} --kubeconfig="${CERT_DIR}/admin.kubeconfig" apply -f "${KUBE_ROOT}/cluster/addons/dashboard/dashboard-configmap.yaml"
        ${KUBECTL} --kubeconfig="${CERT_DIR}/admin.kubeconfig" apply -f "${KUBE_ROOT}/cluster/addons/dashboard/dashboard-rbac.yaml"
        ${KUBECTL} --kubeconfig="${CERT_DIR}/admin.kubeconfig" apply -f "${KUBE_ROOT}/cluster/addons/dashboard/dashboard-controller.yaml"
        ${KUBECTL} --kubeconfig="${CERT_DIR}/admin.kubeconfig" apply -f "${KUBE_ROOT}/cluster/addons/dashboard/dashboard-service.yaml"
        echo "kubernetes-dashboard deployment and service successfully deployed."
    fi
}

function create_psp_policy {
    echo "Create podsecuritypolicy policies for RBAC."
    ${KUBECTL} --kubeconfig="${CERT_DIR}/admin.kubeconfig" create -f "${KUBE_ROOT}/examples/podsecuritypolicy/rbac/policies.yaml"
    ${KUBECTL} --kubeconfig="${CERT_DIR}/admin.kubeconfig" create -f "${KUBE_ROOT}/examples/podsecuritypolicy/rbac/roles.yaml"
    ${KUBECTL} --kubeconfig="${CERT_DIR}/admin.kubeconfig" create -f "${KUBE_ROOT}/examples/podsecuritypolicy/rbac/bindings.yaml"
}

function create_storage_class {
    if [ -z "${CLOUD_PROVIDER}" ]; then
        CLASS_FILE=${KUBE_ROOT}/cluster/addons/storage-class/local/default.yaml
    else
        CLASS_FILE=${KUBE_ROOT}/cluster/addons/storage-class/${CLOUD_PROVIDER}/default.yaml
    fi

    if [ -e "${CLASS_FILE}" ]; then
        echo "Create default storage class for ${CLOUD_PROVIDER}"
        ${KUBECTL} --kubeconfig="${CERT_DIR}/admin.kubeconfig" create -f "${CLASS_FILE}"
    else
        echo "No storage class available for ${CLOUD_PROVIDER}."
    fi
}

function print_success {
if [[ "${START_MODE}" != "kubeletonly" ]]; then
  if [[ "${ENABLE_DAEMON}" = false ]]; then
    echo "Local Kubernetes cluster is running. Press Ctrl-C to shut it down."
  else
    echo "Local Kubernetes cluster is running."
  fi
  cat <<EOF

Logs:
  ${APISERVER_LOG:-}
  ${CTLRMGR_LOG:-}
  ${WORKLOAD_CONTROLLER_LOG:-}
  ${CLOUD_CTLRMGR_LOG:-}
  ${PROXY_LOG:-}
  ${SCHEDULER_LOG:-}
EOF
fi

if [[ "${START_MODE}" == "all" ]]; then
  echo "  ${KUBELET_LOG}"
elif [[ "${START_MODE}" == "nokubelet" ]]; then
  echo
  echo "No kubelet was started because you set START_MODE=nokubelet"
  echo "Run this script again with START_MODE=kubeletonly to run a kubelet"
fi

if [[ "${START_MODE}" != "kubeletonly" ]]; then
  echo
  if [[ "${ENABLE_DAEMON}" = false ]]; then
    echo "To start using your cluster, you can open up another terminal/tab and run:"
  else
    echo "To start using your cluster, run:"
  fi
  cat <<EOF

  export KUBECONFIG=${CERT_DIR}/admin.kubeconfig
Or
  export KUBECONFIG=${CERT_DIR}/adminN(N=0,1,...).kubeconfig

  cluster/kubectl.sh

Alternatively, you can write to the default kubeconfig:

  export KUBERNETES_PROVIDER=local

  cluster/kubectl.sh config set-cluster local --server=https://${API_HOST}:${API_SECURE_PORT} --certificate-authority=${ROOT_CA_FILE}
  cluster/kubectl.sh config set-credentials myself ${AUTH_ARGS}
  cluster/kubectl.sh config set-context local --cluster=local --user=myself
  cluster/kubectl.sh config use-context local
  cluster/kubectl.sh
EOF
else
  cat <<EOF
The kubelet was started.

Logs:
  ${KUBELET_LOG}
EOF
fi
}

# install etcd if necessary
if ! [[ $(which etcd) ]]; then
  if ! [ -f "${KUBE_ROOT}/third_party/etcd/etcd" ]; then
     echo "cannot find etcd locally. will install one."
     ${KUBE_ROOT}/hack/install-etcd.sh
  fi

  export PATH=$PATH:${KUBE_ROOT}/third_party/etcd
fi

# If we are running in the CI, we need a few more things before we can start
# if [[ "${KUBETEST_IN_DOCKER:-}" == "true" ]]; then
#   echo "Preparing to test ..."
#   "${KUBE_ROOT}"/hack/install-etcd.sh
#   export PATH="${KUBE_ROOT}/third_party/etcd:${PATH}"
#   KUBE_FASTBUILD=true make ginkgo cross

#   apt-get update && apt-get install -y sudo
#   apt-get remove -y systemd

#   # configure shared mounts to prevent failure in DIND scenarios
#   mount --make-rshared /

#   # kubekins has a special directory for docker root
#   DOCKER_ROOT="/docker-graph"
# fi

# validate that etcd is: not running, in path, and has minimum required version.
if [[ "${START_MODE}" != "kubeletonly" ]]; then
  kube::etcd::validate
fi

if [ "${CONTAINER_RUNTIME}" == "docker" ] && ! kube::util::ensure_docker_daemon_connectivity; then
  exit 1
fi

if [[ "${START_MODE}" != "kubeletonly" ]]; then
  test_apiserver_off
fi

# kube::util::test_openssl_installed
# kube::util::ensure-cfssl

### IF the user didn't supply an output/ for the build... Then we detect.
if [ "${GO_OUT}" == "" ]; then
  detect_binary
fi
echo "Detected host and ready to start services.  Doing some housekeeping first..."
echo "Using GO_OUT ${GO_OUT}"
export KUBELET_CIDFILE=/tmp/kubelet.cid
if [[ "${ENABLE_DAEMON}" = false ]]; then
  trap cleanup EXIT
fi

echo "Starting services now!"
if [[ "${START_MODE}" != "kubeletonly" ]]; then
  start_etcd
  set_service_accounts
  echo "Starting ${APISERVER_NUMBER} kube-apiserver instances. If you want to make changes to the kube-apiserver nubmer, please run export APISERVER_SERVER=n(n=1,2,...). "
  APISERVER_PID_ARRAY=()
  previous=
  for ((i = $((APISERVER_NUMBER - 1)) ; i >= 0 ; i--)); do
    kube::common::start_apiserver $i
  done
  #remove workload controller manager cluster role and rolebinding applying per this already be added to bootstrappolicy
  
  # If there are other resources ready to sync thru workload-controller-mananger, please add them to the following clusterrole file
  #cluster/kubectl.sh create -f hack/runtime/workload-controller-manager-clusterrole.yaml

  #cluster/kubectl.sh create -f hack/runtime/workload-controller-manager-clusterrolebinding.yaml

  kube::common::start_controller_manager
  kube::common::start_workload_controller_manager
  if [[ "${EXTERNAL_CLOUD_PROVIDER:-}" == "true" ]]; then
    start_cloud_controller_manager
  fi
  if [[ "${START_MODE}" != "nokubeproxy" ]]; then
    start_kubeproxy
  fi
  kube::common::start_kubescheduler
  # start_kubedns
  # if [[ "${ENABLE_NODELOCAL_DNS:-}" == "true" ]]; then
  #   start_nodelocaldns
  # fi
  start_kubedashboard
fi

if [[ "${START_MODE}" != "nokubelet" ]]; then
  ## TODO remove this check if/when kubelet is supported on darwin
  # Detect the OS name/arch and display appropriate error.
    case "$(uname -s)" in
      Darwin)
        print_color "kubelet is not currently supported in darwin, kubelet aborted."
        KUBELET_LOG=""
        ;;
      Linux)
        kube::common::start_kubelet
        ;;
      *)
        print_color "Unsupported host OS.  Must be Linux or Mac OS X, kubelet aborted."
        ;;
    esac
fi

if [[ -n "${PSP_ADMISSION}" && "${AUTHORIZATION_MODE}" = *RBAC* ]]; then
  create_psp_policy
fi

if [[ "${DEFAULT_STORAGE_CLASS}" = "true" ]]; then
  create_storage_class
fi

# echo "*******************************************"
# echo "Setup Arktos components ..."
# echo ""

# while ! cluster/kubectl.sh get nodes --no-headers | grep -i -w Ready; do sleep 3; echo "Waiting for node ready at api server"; done

# cluster/kubectl.sh label node ${HOSTNAME_OVERRIDE} extraRuntime=virtlet

# cluster/kubectl.sh create configmap -n kube-system virtlet-image-translations --from-file ${VIRTLET_DEPLOYMENT_FILES_DIR}/images.yaml

# cluster/kubectl.sh create -f ${VIRTLET_DEPLOYMENT_FILES_DIR}/vmruntime.yaml

# cluster/kubectl.sh get ds --namespace kube-system

# echo ""
# echo "Arktos Setup done."
# echo "*******************************************"
# echo "Setup Kata Containers components ..."
# "${KUBE_ROOT}"/hack/install-kata.sh
# echo "Kata Setup done."
# echo "*******************************************"

print_success

if [[ "${ENABLE_DAEMON}" = false ]]; then
  while true; do sleep 1; healthcheck; done
fi

# if [[ "${KUBETEST_IN_DOCKER:-}" == "true" ]]; then
#   cluster/kubectl.sh config set-cluster local --server=https://${API_HOST_IP}:6443 --certificate-authority=/var/run/kubernetes/server-ca.crt
#   cluster/kubectl.sh config set-credentials myself --client-key=/var/run/kubernetes/client-admin.key --client-certificate=/var/run/kubernetes/client-admin.crt
#   cluster/kubectl.sh config set-context local --cluster=local --user=myself
#   cluster/kubectl.sh config use-context local
# fi