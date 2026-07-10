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

# Configuration
export CP_PROJECT_ID="${CP_PROJECT_ID:-your-gcp-project-id}"
export GCP_REGION="${GCP_REGION:-us-central1}"
export HC_NAME="${HC_NAME:-hc1}"
export HC_NAMESPACE="${HC_NAMESPACE:-clusters}"
export RELEASE_IMAGE="${RELEASE_IMAGE:-quay.io/openshift-release-dev/ocp-release:5.0.0-ec.3-x86_64}"
export PULL_SECRET_PATH="${PULL_SECRET_PATH:-/path/to/pull-secret}"
export DNS_DOMAIN="${DNS_DOMAIN:-${HC_NAME}.your-base-domain.example.com}"
export HYPERSHIFT_BIN="${HYPERSHIFT_BIN:-./hypershift/bin/hypershift}"

# Verify hypershift binary exists
if [ ! -f "${HYPERSHIFT_BIN}" ]; then
    echo "Error: Hypershift binary not found at ${HYPERSHIFT_BIN}"
    echo "Please run step3_install_hypershift_operator.sh first or set HYPERSHIFT_BIN environment variable"
    exit 1
fi

# Check if cluster already exists
echo "Checking if cluster already exists..."
if kubectl get hostedcluster ${HC_NAME} -n ${HC_NAMESPACE} &>/dev/null; then
    echo ""
    echo "=========================================="
    echo "ERROR: Cluster Already Exists"
    echo "=========================================="
    echo ""
    echo "A hosted cluster named '${HC_NAME}' already exists in namespace '${HC_NAMESPACE}'."
    echo ""
    echo "Current cluster status:"
    kubectl get hostedcluster ${HC_NAME} -n ${HC_NAMESPACE}
    echo ""
    echo "If you want to recreate the cluster, please delete it first:"
    echo "  HC_NAME=${HC_NAME} ./step5_delete_hc_cluster.sh"
    echo ""
    echo "Or use a different cluster name:"
    echo "  HC_NAME=my-cluster-name ./step4_create_cluster.sh"
    echo ""
    exit 1
fi
echo "No existing cluster found. Proceeding with creation..."
echo ""

echo "=========================================="
echo "Step 1: Creating IAM and Infrastructure"
echo "=========================================="
echo ""

# Clean up any previous cluster files to avoid conflicts
echo "Cleaning up previous cluster files if they exist..."
rm -f iam-output.json infra-output.json jwks.json sa-signer.key sa-signer.pub
echo ""

# Generate 4096-bit RSA key in PKCS#1 format
echo "Generating RSA keypair for OIDC provider..."
openssl genrsa -traditional -out sa-signer.key 4096
openssl rsa -in sa-signer.key -pubout -out sa-signer.pub

echo "Creating JWKS file from public key..."
# Extract modulus and compute key ID
HEX_MODULUS=$(openssl rsa -in sa-signer.key -pubout -outform DER 2>/dev/null | \
  openssl rsa -pubin -inform DER -text -noout 2>/dev/null | \
  grep -A 100 "^Modulus:" | grep -v "^Modulus:" | grep -v "^Exponent:" | \
  tr -d ' \n:' | sed 's/^00//')
MODULUS=$(printf '%b' "$(echo "$HEX_MODULUS" | sed 's/../\\x&/g')" | base64 -w0 | tr '+/' '-_' | tr -d '=')
KID=$(openssl rsa -in sa-signer.key -pubout -outform DER 2>/dev/null | \
  openssl dgst -sha256 -binary | base64 -w0 | tr '+/' '-_' | tr -d '=')

cat > jwks.json << EOF
{
  "keys": [
    {
      "kty": "RSA",
      "alg": "RS256",
      "use": "sig",
      "kid": "${KID}",
      "n": "${MODULUS}",
      "e": "AQAB"
    }
  ]
}
EOF

echo "JWKS file created successfully"

echo "Creating IAM resources with hypershift..."
${HYPERSHIFT_BIN} create iam gcp \
  --infra-id="${HC_NAME}" \
  --project-id="${CP_PROJECT_ID}" \
  --oidc-jwks-file=jwks.json | tee iam-output.json

echo ""
echo "IAM resources creation complete!"
echo ""

echo "Creating infrastructure resources with hypershift..."
${HYPERSHIFT_BIN} create infra gcp \
  --infra-id="${HC_NAME}" \
  --project-id="${CP_PROJECT_ID}" \
  --region="${GCP_REGION}" | tee infra-output.json

echo ""
echo "Infrastructure resources creation complete!"
echo ""

echo "=========================================="
echo "Step 2: Creating Hosted Cluster"
echo "=========================================="
echo ""

echo "Extracting values from output files..."

# From infra-output.json
NETWORK_NAME=$(jq -r '.networkName' infra-output.json)
SUBNET_NAME=$(jq -r '.subnetName' infra-output.json)

# From iam-output.json
PROJECT_NUMBER=$(jq -r '.projectNumber' iam-output.json)
POOL_ID=$(jq -r '.workloadIdentityPool.poolId' iam-output.json)
PROVIDER_ID=$(jq -r '.workloadIdentityPool.providerId' iam-output.json)
SA_CTRLPLANE=$(jq -r '.serviceAccounts["ctrlplane-op"]' iam-output.json)
SA_NODEPOOL=$(jq -r '.serviceAccounts["nodepool-mgmt"]' iam-output.json)
SA_CLOUD_CTRL=$(jq -r '.serviceAccounts["cloud-controller"]' iam-output.json)
SA_STORAGE=$(jq -r '.serviceAccounts["gcp-pd-csi"]' iam-output.json)
SA_IMG_REG=$(jq -r '.serviceAccounts["image-registry"]' iam-output.json)
SA_NETWORK=$(jq -r '.serviceAccounts["cloud-network"]' iam-output.json)

echo "Extracted configuration:"
echo "  Network: ${NETWORK_NAME}"
echo "  Subnet: ${SUBNET_NAME}"
echo "  Project Number: ${PROJECT_NUMBER}"
echo "  Workload Identity Pool ID: ${POOL_ID}"
echo "  Workload Identity Provider ID: ${PROVIDER_ID}"
echo ""

echo "Creating hosted cluster: ${HC_NAME}"
${HYPERSHIFT_BIN} create cluster gcp \
  --name=${HC_NAME} \
  --namespace=${HC_NAMESPACE} \
  --release-image=${RELEASE_IMAGE} \
  --pull-secret=${PULL_SECRET_PATH} \
  --project=${CP_PROJECT_ID} \
  --region=${GCP_REGION} \
  --network=${NETWORK_NAME} \
  --subnet=${SUBNET_NAME} \
  --private-service-connect-subnet=${SUBNET_NAME} \
  --endpoint-access=PublicAndPrivate \
  --workload-identity-project-number=${PROJECT_NUMBER} \
  --workload-identity-pool-id=${POOL_ID} \
  --workload-identity-provider-id=${PROVIDER_ID} \
  --control-plane-service-account=${SA_CTRLPLANE} \
  --node-pool-service-account=${SA_NODEPOOL} \
  --cloud-controller-service-account=${SA_CLOUD_CTRL} \
  --storage-service-account=${SA_STORAGE} \
  --image-registry-service-account=${SA_IMG_REG} \
  --network-service-account=${SA_NETWORK} \
  --service-account-signing-key-path=sa-signer.key \
  --oidc-issuer-url=https://hypershift-${HC_NAME}-oidc \
  --base-domain=${DNS_DOMAIN} \
  --external-dns-domain=${DNS_DOMAIN} \
  --node-pool-replicas=2 \
  --feature-set=TechPreviewNoUpgrade \
  --disable-cluster-capabilities Console,Ingress \
  --annotations "hypershift.openshift.io/pod-security-admission-label-override=baseline"

echo ""
echo "=========================================="
echo "Deployment Complete!"
echo "=========================================="
echo ""
echo "Generated files:"
echo "  - sa-signer.key (RSA private key)"
echo "  - sa-signer.pub (RSA public key)"
echo "  - jwks.json (JWKS file)"
echo "  - iam-output.json (IAM output)"
echo "  - infra-output.json (Infrastructure output)"
echo ""
echo "Hosted cluster created:"
echo "  Cluster name: ${HC_NAME}"
echo "  Namespace: ${HC_NAMESPACE}"
echo ""
echo "To check cluster status:"
echo "  oc get hostedcluster -n ${HC_NAMESPACE} ${HC_NAME}"
echo "  oc get nodepools -n ${HC_NAMESPACE}"
