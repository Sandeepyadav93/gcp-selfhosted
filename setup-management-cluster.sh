#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    echo "Usage: $0 [autopilot|standard]"
    echo "  autopilot  - Deploy a GKE Autopilot management cluster (default)"
    echo "  standard   - Deploy a GKE Standard management cluster"
    exit 1
}

CLUSTER_MODE="${1:-autopilot}"
case "$CLUSTER_MODE" in
    autopilot|standard) ;;
    *) usage ;;
esac

run_step() {
    local label="$1"
    local script="$2"

    echo ""
    echo "================================================================"
    echo "  STEP: ${label}"
    echo "  Script: ${script}"
    echo "================================================================"

    if [[ ! -f "${SCRIPT_DIR}/${script}" ]]; then
        echo "ERROR: Script not found: ${SCRIPT_DIR}/${script}"
        exit 1
    fi

    bash "${SCRIPT_DIR}/${script}"
    echo "  [OK] ${label}"
}

echo "Starting management cluster setup (mode: ${CLUSTER_MODE})"
echo "Timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

if [[ "$CLUSTER_MODE" == "autopilot" ]]; then
    run_step "Deploy GKE Autopilot cluster" "step1_deploy_gke_autopilot.sh"
else
    run_step "Deploy GKE Standard cluster" "step1_deploy_gke_standard.sh"
fi

run_step "Install prerequisites"          "step2_install_prerequisites.sh"
run_step "Install HyperShift operator"    "step3_install_hypershift_operator.sh"
run_step "Install Prometheus operator"    "step7_install_prometheus_operator.sh"
run_step "Deploy Prometheus (GMP)"        "step8_deploy_prometheus_gmp.sh"

echo ""
echo "================================================================"
echo "  All steps completed successfully."
echo "  Timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "================================================================"
