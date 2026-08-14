#!/usr/bin/env bash
# Runner script for hcp-burner for GCP HyperShift (self-hosted HCP)
set -euo pipefail

# Source environment variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${SCRIPT_DIR}/.env" ]; then
    source "${SCRIPT_DIR}/.env"
    echo "✓ Sourced environment variables from .env"
else
    echo "WARNING: .env file not found at ${SCRIPT_DIR}/.env"
fi

ts="$(date -u +%Y%m%d)"

# Adjust for each new run
iteration=${ts}-0

# Logging and working directory
export HCP_BURNER_PATH=/home/sandyada/perf/gcp/self_hcp/hcpb-gcp-${iteration}
export HCP_BURNER_LOG_LEVEL=DEBUG
export HCP_BURNER_LOG_FILE=/home/sandyada/perf/gcp/self_hcp/hcpb-gcp-${iteration}.log

# Cluster name prefix
export HCP_BURNER_STATIC_CLUSTER_NAME=p3-aug14

export HCP_BURNER_SUBPLATFORM=hypershiftcli

# Rate related arguments
export HCP_BURNER_CLUSTER_COUNT=1
export HCP_BURNER_BATCH_SIZE=1
# Seconds
export HCP_BURNER_DELAY_BETWEEN_BATCH=60

# Minutes
export HCP_BURNER_DELAY_BETWEEN_CLEANUP=1

export HCP_BURNER_WORKERS=2
# Minutes
export HCP_BURNER_WORKERS_WAIT_TIME=60

# GCP config (from .env)
export HCP_BURNER_GCP_PROJECT_ID="${CP_PROJECT_ID}"
export HCP_BURNER_GCP_HC_PROJECT_ID="${HC_PROJECT_ID}"
export HCP_BURNER_GCP_REGION="${GCP_REGION:-us-central1}"
export HCP_BURNER_GCP_CREDENTIALS_FILE="${GCP_CREDENTIALS_FILE:-/home/sandyada/.config/gcloud/application_default_credentials.json}"

# GCP env vars consumed by gcloud / hypershift CLI
export GOOGLE_APPLICATION_CREDENTIALS="${HCP_BURNER_GCP_CREDENTIALS_FILE}"
export GOOGLE_CLOUD_PROJECT="${CP_PROJECT_ID}"
export GKE_MC_CLUSTER_NAME="${CLUSTER_NAME:-autopilot-mc}"
export MC_NAME="${CLUSTER_NAME:-autopilot-mc}"

# MC kubeconfig
export HCP_BURNER_GCP_MC_KUBECONFIG=/tmp/mc_kubeconfig
export MC_KUBECONFIG=/tmp/mc_kubeconfig

# Cluster settings
export HCP_BURNER_GCP_RELEASE_IMAGE="${RELEASE_IMAGE:-quay.io/openshift-release-dev/ocp-release:5.0.0-ec.4-x86_64}"
export HCP_BURNER_GCP_PULL_SECRET_PATH="${PULL_SECRET_PATH}"
export HCP_BURNER_GCP_BASE_DOMAIN="${BASE_DOMAIN}"
export HCP_BURNER_GCP_HC_NAMESPACE=clusters

export HCP_BURNER_WILDCARD_OPTIONS='--control-plane-availability-policy=HighlyAvailable --infra-availability-policy=HighlyAvailable'

# kube-burner-ocp version (v1.12.0+ required for tokenFile support)
export KUBE_BURNER_VERSION=1.12.0

# Workload vars
#export HCP_BURNER_WORKLOAD=node-density
export HCP_BURNER_WORKLOAD=index
export HCP_BURNER_WORKLOAD_REPO=https://github.com/Sandeepyadav93/e2e-benchmarking.git
export HCP_BURNER_WORKLOAD_BRANCH=gcp_enhancements
export HCP_BURNER_WORKLOAD_EXTRA_FLAGS='--pods-per-node=100'
export HCP_BURNER_WORKLOAD_DURATION=10m

# Elastic Search Vars (credentials in .env)
export HCP_BURNER_ES_URL="${ES_URL}"
export HCP_BURNER_ES_INDEX=hypershift-wrapper-timers

# GMP token file for kube-burner auto-refresh (used by e2e-benchmarking run.sh)
export GMP_TOKEN_FILE=/tmp/gmp-token-file

# Extra Vars passed into the workload
export ES_SERVER="${ES_URL}"
export ES_INDEX=ripsaw-kube-burner

# just for index job
#export START_TIME=$(date -d '30 minutes ago' +%s)
#export END_TIME=$(date +%s)

# Each a separate step
#python3 hcp-burner.py --platform gcp --wait-for-workers --es-insecure --install-clusters
#python3 hcp-burner.py --platform gcp --wait-for-workers --es-insecure --enable-workload
python3 hcp-burner.py --platform gcp --wait-for-workers --es-insecure --cleanup-clusters
