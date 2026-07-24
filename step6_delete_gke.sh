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

# GCP Configuration - must match step1_deploy_gke.sh
export CP_PROJECT_ID="${CP_PROJECT_ID:-your-gcp-project-id}"
export GCP_REGION="${GCP_REGION:-us-central1}"
export CLUSTER_NAME="${CLUSTER_NAME:-autopilot-mc}"
export VPC_NAME="${CLUSTER_NAME}-vpc"
export GKE_SUBNET_NAME="${CLUSTER_NAME}-subnet"
export PSC_SUBNET_NAME="${CLUSTER_NAME}-psc"
export PSC_COUNT="${PSC_COUNT:-5}"

echo "Deleting GKE infrastructure with the following configuration:"
echo "  GCP Project: ${CP_PROJECT_ID}"
echo "  Region: ${GCP_REGION}"
echo "  Cluster Name: ${CLUSTER_NAME}"
echo "  VPC: ${VPC_NAME}"
echo ""

# Safety check: Ensure no HyperShift hosted clusters exist
echo "=========================================="
echo "Safety Check: Verifying no HCP clusters exist"
echo "=========================================="
echo ""

# Check for HostedClusters in the clusters namespace
# If the CRD doesn't exist, there are no hosted clusters to worry about
HC_COUNT=$(kubectl get hostedclusters -n clusters --no-headers 2>/dev/null | wc -l || true)

if [ "${HC_COUNT}" -gt 0 ]; then
    echo "ERROR: Found ${HC_COUNT} HyperShift hosted cluster(s) still running!"
    echo ""
    echo "Existing hosted clusters:"
    kubectl get hostedclusters -n clusters
    echo ""
    echo "You must delete all HCP clusters before deleting the management cluster."
    echo ""
    echo "To delete HCP clusters, run:"
    echo "  ./step5_delete_hc_cluster.sh"
    echo ""
    echo "Or manually delete them:"
    echo "  kubectl get hostedclusters -n clusters"
    echo "  kubectl delete hostedcluster <name> -n clusters"
    echo ""
    exit 1
fi

echo "✓ No HCP clusters found - safe to proceed with GKE deletion"
echo ""

# Step 1: Delete GKE cluster
echo "Step 1: Deleting GKE cluster: ${CLUSTER_NAME}"
if gcloud container clusters describe "${CLUSTER_NAME}" --region="${GCP_REGION}" --project="${CP_PROJECT_ID}" &>/dev/null; then
    gcloud container clusters delete "${CLUSTER_NAME}" \
        --region="${GCP_REGION}" \
        --project="${CP_PROJECT_ID}" \
        --quiet
    echo "GKE cluster deleted successfully!"
else
    echo "GKE cluster ${CLUSTER_NAME} not found, skipping..."
fi
echo ""

# Step 2: Delete PSC subnets
echo "Step 2: Deleting ${PSC_COUNT} PSC subnets..."
for i in $(seq 1 ${PSC_COUNT}); do
    PSC_SUBNET_NUM=$(printf "%03d" $i)
    PSC_SUBNET="${CLUSTER_NAME}-psc-${PSC_SUBNET_NUM}"

    if gcloud compute networks subnets describe "${PSC_SUBNET}" --region="${GCP_REGION}" --project="${CP_PROJECT_ID}" &>/dev/null; then
        echo "Deleting PSC subnet: ${PSC_SUBNET}"
        gcloud compute networks subnets delete "${PSC_SUBNET}" \
            --region="${GCP_REGION}" \
            --project="${CP_PROJECT_ID}" \
            --quiet
    else
        echo "PSC subnet ${PSC_SUBNET} not found, skipping..."
    fi
done
echo "PSC subnets deletion complete!"
echo ""

# Step 3: Delete Cloud NAT
echo "Step 3: Deleting Cloud NAT: ${CLUSTER_NAME}-nat"
if gcloud compute routers nats describe "${CLUSTER_NAME}-nat" --router="${CLUSTER_NAME}-router" --region="${GCP_REGION}" --project="${CP_PROJECT_ID}" &>/dev/null; then
    gcloud compute routers nats delete "${CLUSTER_NAME}-nat" \
        --router="${CLUSTER_NAME}-router" \
        --region="${GCP_REGION}" \
        --project="${CP_PROJECT_ID}" \
        --quiet
    echo "Cloud NAT deleted successfully!"
else
    echo "Cloud NAT ${CLUSTER_NAME}-nat not found, skipping..."
fi
echo ""

# Step 4: Delete Cloud Router
echo "Step 4: Deleting Cloud Router: ${CLUSTER_NAME}-router"
if gcloud compute routers describe "${CLUSTER_NAME}-router" --region="${GCP_REGION}" --project="${CP_PROJECT_ID}" &>/dev/null; then
    gcloud compute routers delete "${CLUSTER_NAME}-router" \
        --region="${GCP_REGION}" \
        --project="${CP_PROJECT_ID}" \
        --quiet
    echo "Cloud Router deleted successfully!"
else
    echo "Cloud Router ${CLUSTER_NAME}-router not found, skipping..."
fi
echo ""

# Step 5: Delete GKE subnet
echo "Step 5: Deleting GKE subnet: ${GKE_SUBNET_NAME}"
if gcloud compute networks subnets describe "${GKE_SUBNET_NAME}" --region="${GCP_REGION}" --project="${CP_PROJECT_ID}" &>/dev/null; then
    gcloud compute networks subnets delete "${GKE_SUBNET_NAME}" \
        --region="${GCP_REGION}" \
        --project="${CP_PROJECT_ID}" \
        --quiet
    echo "GKE subnet deleted successfully!"
else
    echo "GKE subnet ${GKE_SUBNET_NAME} not found, skipping..."
fi
echo ""

# Step 6: Delete VPC network
echo "Step 6: Deleting VPC network: ${VPC_NAME}"
if gcloud compute networks describe "${VPC_NAME}" --project="${CP_PROJECT_ID}" &>/dev/null; then
    gcloud compute networks delete "${VPC_NAME}" \
        --project="${CP_PROJECT_ID}" \
        --quiet
    echo "VPC network deleted successfully!"
else
    echo "VPC network ${VPC_NAME} not found, skipping..."
fi
echo ""

echo "=========================================="
echo "GKE infrastructure deletion complete!"
echo "=========================================="
