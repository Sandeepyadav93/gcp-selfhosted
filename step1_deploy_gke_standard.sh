#!/bin/bash
set -euo pipefail

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
export CLUSTER_NAME="${CLUSTER_NAME:-standard-mc}"
export VPC_NAME="${CLUSTER_NAME}-vpc"
export GKE_SUBNET_NAME="${CLUSTER_NAME}-subnet"
export PSC_SUBNET_NAME="${CLUSTER_NAME}-psc"
export RELEASE_CHANNEL="${GKE_RELEASE_CHANNEL:-stable}"
export PSC_COUNT="${PSC_COUNT:-5}"

# GKE Standard specific settings
export NUM_WORKER_PER_ZONE=${NUM_WORKER_PER_ZONE:-1}
export WORKER_TYPE=${WORKER_TYPE:-n2-standard-4}
export MAX_PODS_PER_WORKER=${MAX_PODS_PER_WORKER:-110}

# Prometheus dedicated node pool settings
export PROM_WORKER_TYPE=${PROM_WORKER_TYPE:-e2-standard-4}
export PROM_NUM_NODES=${PROM_NUM_NODES:-1}

# IP Ranges
export PRIMARY_RANGE="10.0.0.0/20"
export POD_RANGE="10.4.0.0/14"
export SERVICE_RANGE="10.8.0.0/20"

echo "🚀 Starting setup for GKE Standard Cluster: ${CLUSTER_NAME}"
echo "Project: ${CP_PROJECT_ID}"
echo "Region: ${GCP_REGION}"

# --- 1. Create VPC network ---
echo "Creating VPC network: ${VPC_NAME}"
gcloud compute networks create "${VPC_NAME}" \
    --project="${CP_PROJECT_ID}" \
    --subnet-mode=custom

# --- 2. Create GKE subnet ---
echo "Creating GKE subnet: ${GKE_SUBNET_NAME}"
gcloud compute networks subnets create "${GKE_SUBNET_NAME}" \
    --project="${CP_PROJECT_ID}" \
    --region="${GCP_REGION}" \
    --network="${VPC_NAME}" \
    --range="${PRIMARY_RANGE}" \
    --secondary-range="gke-pods=${POD_RANGE},gke-services=${SERVICE_RANGE}" \
    --enable-private-ip-google-access

# --- 3. Create Cloud Router ---
echo "Creating Cloud Router: ${CLUSTER_NAME}-router"
gcloud compute routers create "${CLUSTER_NAME}-router" \
    --project="${CP_PROJECT_ID}" \
    --region="${GCP_REGION}" \
    --network="${VPC_NAME}"

# --- 4. Create Cloud NAT ---
echo "Creating Cloud NAT: ${CLUSTER_NAME}-nat"
gcloud compute routers nats create "${CLUSTER_NAME}-nat" \
    --project="${CP_PROJECT_ID}" \
    --region="${GCP_REGION}" \
    --router="${CLUSTER_NAME}-router" \
    --nat-all-subnet-ip-ranges \
    --auto-allocate-nat-external-ips

# --- 5. Create GKE Standard Regional Cluster ---
echo "Creating GKE Standard Cluster... (This may take 10-15 minutes)"
gcloud container clusters create "${CLUSTER_NAME}" \
    --project="${CP_PROJECT_ID}" \
    --region="${GCP_REGION}" \
    --num-nodes="${NUM_WORKER_PER_ZONE}" \
    --machine-type="${WORKER_TYPE}" \
    --enable-ip-alias \
    --enable-dataplane-v2 \
    --max-pods-per-node="${MAX_PODS_PER_WORKER}" \
    --default-max-pods-per-node="${MAX_PODS_PER_WORKER}" \
    --network="${VPC_NAME}" \
    --subnetwork="${GKE_SUBNET_NAME}" \
    --cluster-secondary-range-name="gke-pods" \
    --services-secondary-range-name="gke-services" \
    --release-channel="${RELEASE_CHANNEL}" \
    --labels="billing-tag=${CLUSTER_NAME}" \
    --monitoring=SYSTEM,API_SERVER,CONTROLLER_MANAGER,SCHEDULER,HPA,STATEFULSET,DEPLOYMENT,DAEMONSET,POD,STORAGE,CADVISOR,KUBELET \
    --enable-private-nodes \
    --no-enable-master-authorized-networks \
    --scopes=cloud-platform

# --- 6. Create PSC subnets for hosted control plane ---
echo "Creating ${PSC_COUNT} PSC subnets for hosted control plane"
for i in $(seq 1 ${PSC_COUNT}); do
    PSC_SUBNET_NUM=$(printf "%03d" $i)
    PSC_SUBNET="${CLUSTER_NAME}-psc-${PSC_SUBNET_NUM}"
    PSC_RANGE="10.3.${i}.0/24"

    echo "Creating PSC subnet: ${PSC_SUBNET} with range ${PSC_RANGE}"
    gcloud compute networks subnets create "${PSC_SUBNET}" \
        --project="${CP_PROJECT_ID}" \
        --region="${GCP_REGION}" \
        --network="${VPC_NAME}" \
        --range="${PSC_RANGE}" \
        --purpose=PRIVATE_SERVICE_CONNECT
done

echo "✅ PSC subnets creation complete! Created ${PSC_COUNT} PSC subnets."

# --- 7. Create dedicated node pool for Prometheus ---
echo "Creating dedicated Prometheus node pool: ${CLUSTER_NAME}-prometheus-pool"
gcloud container node-pools create "${CLUSTER_NAME}-prometheus-pool" \
    --project="${CP_PROJECT_ID}" \
    --cluster="${CLUSTER_NAME}" \
    --region="${GCP_REGION}" \
    --num-nodes="${PROM_NUM_NODES}" \
    --machine-type="${PROM_WORKER_TYPE}" \
    --max-pods-per-node="${MAX_PODS_PER_WORKER}" \
    --node-taints=dedicated=prometheus:NoSchedule \
    --node-labels=dedicated=prometheus \
    --scopes=cloud-platform

echo "✅ Dedicated Prometheus node pool created."
echo "✅ Deployment Successful!"
echo "GKE Standard cluster ${CLUSTER_NAME} is ready."
echo ""
echo "Next step: Run step2_install_prerequisites.sh to install required CRDs and cert-manager."
