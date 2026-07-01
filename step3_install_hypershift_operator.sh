#!/bin/bash
set -euo pipefail

# Configuration
export CP_PROJECT_ID="${CP_PROJECT_ID:-your-gcp-project-id}"
export GCP_REGION="${GCP_REGION:-us-central1}"
export BASE_DOMAIN="${BASE_DOMAIN:-your-base-domain.example.com}"
export PULL_SECRET_PATH="${PULL_SECRET_PATH:-/path/to/pull-secret}"

# Service account name
SA_NAME="hypershift-operator"
SA_EMAIL="${SA_NAME}@${CP_PROJECT_ID}.iam.gserviceaccount.com"
EXTERNAL_DNS_GSA="external-dns@${CP_PROJECT_ID}.iam.gserviceaccount.com"

# Clone Hypershift repository
echo "Cloning Hypershift repository..."
if [ -d "hypershift" ]; then
    echo "Hypershift directory already exists, skipping clone"
    cd hypershift
    git pull
else
    git clone git@github.com:openshift/hypershift.git
    cd hypershift
fi

# Build Hypershift binary
echo "Building Hypershift binary..."
make hypershift

# Install Hypershift operator
echo "Installing Hypershift operator..."
./bin/hypershift install \
    --external-dns-provider=google \
    --external-dns-domain-filter="${BASE_DOMAIN}" \
    --external-dns-google-project="${CP_PROJECT_ID}" \
    --private-platform=GCP \
    --gcp-project="${CP_PROJECT_ID}" \
    --gcp-region="${GCP_REGION}" \
    --platform-monitoring=All \
    --enable-ci-debug-output \
    --pull-secret="${PULL_SECRET_PATH}" \
    --wait-until-available \
    --tech-preview-no-upgrade \
    --metrics-set All

# echo "Hypershift operator installation complete!"

# Annotate K8s ServiceAccount for Workload Identity
echo "Annotating K8s ServiceAccount for Workload Identity"
oc annotate serviceaccount operator -n hypershift \
  "iam.gke.io/gcp-service-account=${SA_EMAIL}" \
  --overwrite

# Restart the operator to pick up the new annotation
echo "Restarting operator deployment to pick up Workload Identity"
oc rollout restart deployment/operator -n hypershift
oc rollout status deployment/operator -n hypershift --timeout=300s

echo "Verifying operator ServiceAccount annotation:"
oc get sa -n hypershift operator -o yaml

# Annotate K8s SA for Workload Identity and restart ExternalDNS
echo "Annotating ExternalDNS ServiceAccount for Workload Identity"
oc annotate serviceaccount external-dns -n hypershift \
  "iam.gke.io/gcp-service-account=${EXTERNAL_DNS_GSA}" \
  --overwrite

echo "Restarting ExternalDNS deployment"
oc rollout restart deployment/external-dns -n hypershift
echo "Waiting for ExternalDNS rollout..."
oc rollout status deployment/external-dns -n hypershift --timeout=300s

echo "Verifying external-dns ServiceAccount annotation:"
oc get sa -n hypershift external-dns -o yaml

echo "Workload Identity configuration complete!"

# Verification
echo ""
echo "=========================================="
echo "Verification"
echo "=========================================="
echo ""
echo "Deployments in hypershift namespace:"
oc get deployment -n hypershift

echo ""
echo "Pods in hypershift namespace:"
oc get pods -n hypershift

echo ""
echo "Hypershift operator installation and configuration complete!"
