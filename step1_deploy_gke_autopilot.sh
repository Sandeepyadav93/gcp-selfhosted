#!/bin/bash
set -euo pipefail

retry() {
    local max_attempts=5
    local delay=30
    local attempt=1
    local output
    while true; do
        output=$(mktemp)
        if "$@" 2> >(tee "$output" >&2); then
            rm -f "$output"
            return 0
        fi
        if grep -qiE '502|503|429|rate limit|temporarily unavailable|connection reset|could not fetch resource' "$output"; then
            rm -f "$output"
            if (( attempt >= max_attempts )); then
                echo "FAILED after ${max_attempts} attempts: $*"
                return 1
            fi
            echo "Transient error on attempt ${attempt}/${max_attempts}. Retrying in ${delay}s..."
            sleep "$delay"
            (( attempt++ ))
            (( delay *= 2 ))
        else
            rm -f "$output"
            return 1
        fi
    done
}

# Source environment variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/.env" ]; then
    source "${SCRIPT_DIR}/.env"
    echo "✓ Sourced environment variables from .env"
else
    echo "WARNING: .env file not found at ${SCRIPT_DIR}/.env"
fi

# GCP Configuration
export CP_PROJECT_ID="${CP_PROJECT_ID:-your-gcp-project-id}"
export GCP_REGION="${GCP_REGION:-us-central1}"
export CLUSTER_NAME="${CLUSTER_NAME:-autopilot-mc}"
export VPC_NAME="${CLUSTER_NAME}-vpc"
export GKE_SUBNET_NAME="${CLUSTER_NAME}-subnet"
export PSC_SUBNET_NAME="${CLUSTER_NAME}-psc"
export RELEASE_CHANNEL="${GKE_RELEASE_CHANNEL:-stable}"
export PSC_COUNT="${PSC_COUNT:-8}"

# IP Ranges
export PRIMARY_RANGE="10.0.0.0/20"
export POD_RANGE="10.4.0.0/14"
export SERVICE_RANGE="10.8.0.0/20"

echo "Creating VPC network: ${VPC_NAME}"
retry gcloud compute networks create "${VPC_NAME}" \
    --project="${CP_PROJECT_ID}" \
    --subnet-mode=custom

echo "Creating GKE subnet: ${GKE_SUBNET_NAME}"
retry gcloud compute networks subnets create "${GKE_SUBNET_NAME}" \
    --project="${CP_PROJECT_ID}" \
    --region="${GCP_REGION}" \
    --network="${VPC_NAME}" \
    --range="${PRIMARY_RANGE}" \
    --secondary-range="gke-pods=${POD_RANGE},gke-services=${SERVICE_RANGE}" \
    --enable-private-ip-google-access

echo "Creating Cloud Router: ${CLUSTER_NAME}-router"
retry gcloud compute routers create "${CLUSTER_NAME}-router" \
    --project="${CP_PROJECT_ID}" \
    --region="${GCP_REGION}" \
    --network="${VPC_NAME}"

echo "Creating Cloud NAT: ${CLUSTER_NAME}-nat"
retry gcloud compute routers nats create "${CLUSTER_NAME}-nat" \
    --project="${CP_PROJECT_ID}" \
    --region="${GCP_REGION}" \
    --router="${CLUSTER_NAME}-router" \
    --nat-all-subnet-ip-ranges \
    --auto-allocate-nat-external-ips

echo "Creating GKE Autopilot cluster: ${CLUSTER_NAME}"
retry gcloud container clusters create-auto "${CLUSTER_NAME}" \
    --project="${CP_PROJECT_ID}" \
    --region="${GCP_REGION}" \
    --network="${VPC_NAME}" \
    --subnetwork="${GKE_SUBNET_NAME}" \
    --cluster-secondary-range-name="gke-pods" \
    --services-secondary-range-name="gke-services" \
    --release-channel="${RELEASE_CHANNEL}" \
    --labels="billing-tag=${CLUSTER_NAME}" \
    --monitoring=SYSTEM,API_SERVER,CONTROLLER_MANAGER,SCHEDULER,HPA,STATEFULSET,DEPLOYMENT,DAEMONSET,POD,STORAGE,CADVISOR,KUBELET \
    --enable-private-nodes \
    --enable-kubernetes-unstable-apis=admissionregistration.k8s.io/v1beta1/mutatingadmissionpolicies,admissionregistration.k8s.io/v1beta1/mutatingadmissionpolicybindings

# Prepare the GKE cluster to be used as Management Cluster (MC)
echo "Creating ${PSC_COUNT} PSC subnets for hosted control plane"
for i in $(seq 1 ${PSC_COUNT}); do
    PSC_SUBNET_NUM=$(printf "%03d" $i)
    PSC_SUBNET="${CLUSTER_NAME}-psc-${PSC_SUBNET_NUM}"
    PSC_RANGE="10.3.${i}.0/24"

    echo "Creating PSC subnet: ${PSC_SUBNET} with range ${PSC_RANGE}"
    retry gcloud compute networks subnets create "${PSC_SUBNET}" \
        --project="${CP_PROJECT_ID}" \
        --region="${GCP_REGION}" \
        --network="${VPC_NAME}" \
        --range="${PSC_RANGE}" \
        --purpose=PRIVATE_SERVICE_CONNECT
done

echo "PSC subnets creation complete! Created ${PSC_COUNT} PSC subnets."

# Apply MutatingAdmissionPolicy for Autopilot HA support
# GKE Autopilot enforces 500m CPU minimum for pods with anti-affinity.
# HA mode adds anti-affinity to etcd/control-plane pods which default below that.
# This policy auto-bumps CPU requests to meet the minimum.
echo "Applying MutatingAdmissionPolicy for Autopilot HA CPU fix..."
oc apply -f mutating-admission-policy-autopilot-cpu.yaml

echo "GKE cluster deployment complete! Cluster ${CLUSTER_NAME} is ready."
echo "Next step: Run step2_install_prerequisites.sh to install required CRDs and cert-manager."
