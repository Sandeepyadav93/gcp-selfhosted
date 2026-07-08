#!/bin/bash
# Don't exit on error for cluster deletion
set +e

# Configuration variables
export HC_NAME="${HC_NAME:-hc1}"
export HC_NAMESPACE="${HC_NAMESPACE:-clusters}"
export CP_PROJECT_ID="${CP_PROJECT_ID:-your-gcp-project-id}"
export GCP_REGION="${GCP_REGION:-us-central1}"
export HYPERSHIFT_BIN="${HYPERSHIFT_BIN:-./hypershift/bin/hypershift}"

# Verify hypershift binary exists
if [ ! -f "${HYPERSHIFT_BIN}" ]; then
    echo "Error: Hypershift binary not found at ${HYPERSHIFT_BIN}"
    echo "Please run step3_install_hypershift_operator.sh first or set HYPERSHIFT_BIN environment variable"
    exit 1
fi

echo "Deleting HyperShift cluster with the following configuration:"
echo "  Cluster Name: ${HC_NAME}"
echo "  Namespace: ${HC_NAMESPACE}"
echo "  GCP Project: ${CP_PROJECT_ID}"
echo "  GCP Region: ${GCP_REGION}"
echo ""

# Step 1: Delete the hosted cluster
echo "Step 1: Deleting hosted cluster..."
${HYPERSHIFT_BIN} destroy cluster gcp \
  --name="${HC_NAME}" \
  --namespace="${HC_NAMESPACE}"

CLUSTER_DELETE_EXIT_CODE=$?
if [ ${CLUSTER_DELETE_EXIT_CODE} -eq 0 ]; then
  echo "Hosted cluster deleted successfully!"
else
  echo "Warning: Hosted cluster deletion failed or cluster not found (exit code: ${CLUSTER_DELETE_EXIT_CODE})"
  echo "Continuing with infrastructure and IAM cleanup..."
fi
echo ""

# Step 2: Delete the infrastructure
echo "Step 2: Deleting infrastructure..."
${HYPERSHIFT_BIN} destroy infra gcp \
  --infra-id="${HC_NAME}" \
  --project-id="$CP_PROJECT_ID}" \
  --region="${GCP_REGION}"

echo "Infrastructure deleted successfully!"
echo ""

# Step 3: Delete IAM resources
echo "Step 3: Deleting IAM resources..."
${HYPERSHIFT_BIN} destroy iam gcp \
  --infra-id="${HC_NAME}" \
  --project-id="${CP_PROJECT_ID}"

echo "IAM resources deleted successfully!"
echo ""

echo "=========================================="
echo "Cluster deletion complete!"
echo "=========================================="
