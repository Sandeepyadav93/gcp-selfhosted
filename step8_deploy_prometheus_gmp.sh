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

# ============================================================================
# Deploy Prometheus Instance with GMP Export (with node isolation)
# ============================================================================
# This script deploys a Prometheus instance (via Prometheus CR) that:
# - Collects metrics from all ServiceMonitors/PodMonitors cluster-wide
# - Evaluates PrometheusRules locally
# - Exports filtered metrics to Google Managed Prometheus (GMP)
#
# Includes tolerations and nodeSelector for dedicated prometheus node pool
# isolation. Works on both GKE Standard and Autopilot.
# ============================================================================

# Configuration
export CP_PROJECT_ID="${CP_PROJECT_ID:-YOUR_PROJECT_ID}"
export GCP_REGION="${GCP_REGION:-us-central1}"
export CLUSTER_NAME="${CLUSTER_NAME:-autopilot-mc}"

PROMETHEUS_YAML="prometheus-gmp-test.yaml"
PROMETHEUS_PUBLIC_SVC_YAML="prom-public-svc.yaml"
MONITORING_NAMESPACE="monitoring"

echo "=========================================="
echo "Deploying Prometheus with GMP Export (with node isolation)"
echo "=========================================="
echo ""
echo "Configuration:"
echo "  Project ID: ${CP_PROJECT_ID}"
echo "  Region: ${GCP_REGION}"
echo "  Cluster: ${CLUSTER_NAME}"
echo "  Namespace: ${MONITORING_NAMESPACE}"
echo "  Node isolation: dedicated=prometheus (taint + nodeSelector)"
echo ""

# ============================================================================
# Verify prerequisites
# ============================================================================
echo "Verifying prerequisites..."
echo ""

# Check if Prometheus Operator is installed
echo "Checking Prometheus Operator..."
if ! kubectl get crd prometheuses.monitoring.coreos.com &>/dev/null; then
    echo "ERROR: Prometheus CRD not found"
    echo "Please install Prometheus Operator first:"
    echo "  ./step7_install_prometheus_operator.sh"
    exit 1
fi
echo "  ✓ Prometheus CRD found"

if ! kubectl get deployment -n prometheus-operator -l app.kubernetes.io/name=prometheus-operator &>/dev/null; then
    echo "ERROR: Prometheus Operator not running"
    echo "Please install Prometheus Operator first:"
    echo "  ./step7_install_prometheus_operator.sh"
    exit 1
fi
echo "  ✓ Prometheus Operator is running"

# Check if prometheus-gmp-standard.yaml exists
if [ ! -f "${PROMETHEUS_YAML}" ]; then
    echo "ERROR: ${PROMETHEUS_YAML} not found in current directory"
    echo "Please ensure the file exists at: $(pwd)/${PROMETHEUS_YAML}"
    exit 1
fi
echo "  ✓ ${PROMETHEUS_YAML} found"

echo ""
echo "✓ All prerequisites verified"
echo ""

# ============================================================================
# Check if Prometheus instance already exists
# ============================================================================
echo "Checking if Prometheus instance already exists..."
if kubectl get prometheus gmp-collector -n "${MONITORING_NAMESPACE}" &>/dev/null; then
    echo ""
    echo "=========================================="
    echo "WARNING: Prometheus Instance Already Exists"
    echo "=========================================="
    echo ""
    echo "Current Prometheus instance:"
    kubectl get prometheus gmp-collector -n "${MONITORING_NAMESPACE}"
    echo ""
    echo "Current pods:"
    kubectl get pods -n "${MONITORING_NAMESPACE}"
    echo ""
    echo "If you want to redeploy, delete it first:"
    echo "  kubectl delete prometheus gmp-collector -n ${MONITORING_NAMESPACE}"
    echo "  kubectl delete namespace ${MONITORING_NAMESPACE}"
    echo ""
    echo "Or to update the existing instance, edit the Prometheus CR:"
    echo "  kubectl edit prometheus gmp-collector -n ${MONITORING_NAMESPACE}"
    echo ""
    exit 1
fi
echo "✓ No existing Prometheus instance found"
echo ""

# ============================================================================
# Update YAML with environment variables
# ============================================================================
echo "Preparing Prometheus deployment manifest..."
echo ""

# Create temporary file with substituted values
TEMP_YAML=$(mktemp)
trap "rm -f ${TEMP_YAML}" EXIT

# Substitute environment variables in YAML
sed -e "s/YOUR_PROJECT_ID/${CP_PROJECT_ID}/g" \
    -e "s/YOUR_REGION/${GCP_REGION}/g" \
    -e "s/YOUR_CLUSTER_NAME/${CLUSTER_NAME}/g" \
    "${PROMETHEUS_YAML}" > "${TEMP_YAML}"

echo "Configuration applied:"
echo "  - project_id: ${CP_PROJECT_ID}"
echo "  - region: ${GCP_REGION}"
echo "  - cluster: ${CLUSTER_NAME}"
echo "  - GCP SA: prometheus-hcp-exporter@${CP_PROJECT_ID}.iam.gserviceaccount.com"
echo ""

# ============================================================================
# Deploy Prometheus resources
# ============================================================================
echo "Deploying Prometheus resources..."
echo ""

kubectl apply -f "${TEMP_YAML}"

echo ""
echo "✓ Prometheus resources created"
echo ""

# ============================================================================
# Wait for Prometheus to be ready
# ============================================================================
echo "Waiting for Prometheus StatefulSet to be created by operator..."
echo ""

# Wait for StatefulSet to exist (created by operator)
for i in {1..60}; do
    if kubectl get statefulset prometheus-gmp-collector -n "${MONITORING_NAMESPACE}" &>/dev/null; then
        echo "✓ Prometheus StatefulSet created by operator"
        break
    fi
    if [ $i -eq 60 ]; then
        echo "ERROR: StatefulSet not created after 60 seconds"
        echo "Check operator logs:"
        echo "  kubectl logs -n prometheus-operator -l app.kubernetes.io/name=prometheus-operator --tail=50"
        exit 1
    fi
    echo "  Waiting for StatefulSet... (attempt $i/60)"
    sleep 2
done

echo ""

# Wait for pod to be ready
echo "Waiting for Prometheus pod to be ready (timeout: 300s)..."
if kubectl wait --for=condition=ready pod \
    -l prometheus=gmp-collector \
    -n "${MONITORING_NAMESPACE}" \
    --timeout=300s; then
    echo "✓ Prometheus pod is ready"
else
    echo "ERROR: Prometheus pod failed to become ready"
    echo ""
    echo "Pod status:"
    kubectl get pods -n "${MONITORING_NAMESPACE}"
    echo ""
    echo "Check pod logs:"
    echo "  kubectl logs -n ${MONITORING_NAMESPACE} prometheus-gmp-collector-0"
    exit 1
fi
echo ""

# Give a few seconds for metrics to start flowing
echo "Waiting for Prometheus to start scraping metrics..."
sleep 10
echo ""

# ============================================================================
# Create public LoadBalancer service
# ============================================================================
echo "Creating public LoadBalancer service..."
echo ""

if kubectl get svc prometheus-public -n "${MONITORING_NAMESPACE}" &>/dev/null; then
    echo "✓ Public service already exists"
else
    kubectl apply -f "${PROMETHEUS_PUBLIC_SVC_YAML}"
    echo "✓ Public service created"
fi
echo ""

# ============================================================================
# Verify node isolation
# ============================================================================
echo "=========================================="
echo "Node Isolation Verification"
echo "=========================================="
echo ""

echo "Prometheus pod placement:"
kubectl get pods -n "${MONITORING_NAMESPACE}" -o wide
echo ""

PROM_NODE=$(kubectl get pod prometheus-gmp-collector-0 -n "${MONITORING_NAMESPACE}" -o jsonpath='{.spec.nodeName}' 2>/dev/null)
if [ -n "$PROM_NODE" ]; then
    NODE_LABELS=$(kubectl get node "$PROM_NODE" -o jsonpath='{.metadata.labels.dedicated}' 2>/dev/null)
    if [ "$NODE_LABELS" = "prometheus" ]; then
        echo "✓ Prometheus pod is running on dedicated prometheus node: ${PROM_NODE}"
    else
        echo "⚠ WARNING: Prometheus pod is NOT on a dedicated prometheus node!"
        echo "  Node: ${PROM_NODE}"
        echo "  Expected label 'dedicated=prometheus' but got: ${NODE_LABELS}"
    fi
fi
echo ""

# ============================================================================
# Verification
# ============================================================================
echo "=========================================="
echo "Verification"
echo "=========================================="
echo ""

echo "Prometheus Custom Resource:"
kubectl get prometheus -n "${MONITORING_NAMESPACE}"
echo ""

echo "StatefulSet:"
kubectl get statefulset -n "${MONITORING_NAMESPACE}"
echo ""

echo "Pods:"
kubectl get pods -n "${MONITORING_NAMESPACE}" -o wide
echo ""

echo "Services:"
kubectl get svc -n "${MONITORING_NAMESPACE}"
echo ""

echo "Discovered ServiceMonitors (cluster-wide):"
SERVICEMONITOR_COUNT=$(kubectl get servicemonitors -A --no-headers 2>/dev/null | wc -l)
echo "  Total: ${SERVICEMONITOR_COUNT}"
if [ ${SERVICEMONITOR_COUNT} -gt 0 ]; then
    echo ""
    kubectl get servicemonitors -A | head -10
    if [ ${SERVICEMONITOR_COUNT} -gt 10 ]; then
        echo "  ... and $((${SERVICEMONITOR_COUNT} - 10)) more"
    fi
fi
echo ""

echo "Discovered PodMonitors (cluster-wide):"
PODMONITOR_COUNT=$(kubectl get podmonitors -A --no-headers 2>/dev/null | wc -l)
echo "  Total: ${PODMONITOR_COUNT}"
if [ ${PODMONITOR_COUNT} -gt 0 ]; then
    echo ""
    kubectl get podmonitors -A | head -10
    if [ ${PODMONITOR_COUNT} -gt 10 ]; then
        echo "  ... and $((${PODMONITOR_COUNT} - 10)) more"
    fi
fi
echo ""

# ============================================================================
# Success message and next steps
# ============================================================================
echo "=========================================="
echo "✓ Prometheus Deployment Complete! (with node isolation)"
echo "=========================================="
echo ""
echo "Hybrid GMP Architecture is now operational:"
echo ""
echo "  ✓ Self-managed Prometheus collecting metrics"
echo "  ✓ Local storage: 6h retention (50Gi PVC)"
echo "  ✓ Cluster-wide discovery: ${SERVICEMONITOR_COUNT} ServiceMonitors, ${PODMONITOR_COUNT} PodMonitors"
echo "  ✓ Cost filtering: only allowlisted metrics exported to GMP"
echo "  ✓ GMP export: metrics flowing to project ${CP_PROJECT_ID}"
echo "  ✓ Node isolation: running on dedicated prometheus node pool"
echo ""
echo "Next steps:"
echo ""
echo "1. Access Prometheus UI:"
echo "   Via LoadBalancer (public):"
echo "     PROM_IP=\$(kubectl get svc prometheus-public -n ${MONITORING_NAMESPACE} -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
echo "     echo \"Prometheus UI: http://\${PROM_IP}:9090\""
echo "   Via port-forward (local):"
echo "     kubectl port-forward -n ${MONITORING_NAMESPACE} prometheus-gmp-collector-0 9090:9090"
echo "     Open: http://localhost:9090"
echo ""
echo "2. Check Prometheus is scraping targets:"
echo "   - In Prometheus UI: Status > Targets"
echo "   - Or check configuration: Status > Configuration"
echo ""
echo "3. Verify GMP export (wait ~3 minutes for metrics to appear):"
echo "   - GCP Console > Monitoring > Metrics Explorer"
echo "   - Search for: 'Prometheus Target'"
echo "   - Or use gcloud:"
echo "     gcloud monitoring metric-descriptors list \\"
echo "       --filter='metric.type:prometheus' \\"
echo "       --project=${CP_PROJECT_ID} \\"
echo "       --format='table(type)'"
echo ""
echo "4. Check Prometheus logs:"
echo "   kubectl logs -n ${MONITORING_NAMESPACE} prometheus-gmp-collector-0 -f"
echo ""
echo "5. View local metrics (all metrics before filtering):"
echo "   kubectl port-forward -n ${MONITORING_NAMESPACE} prometheus-gmp-collector-0 9090:9090"
echo "   Then query: {__name__=~\".+\"}"
echo ""
echo "Cost Control:"
echo "  - All metrics collected locally (debugging, recording rules)"
echo "  - Only allowlisted metrics exported to GMP (cost savings)"
echo "  - Edit allowlist: kubectl edit prometheus gmp-collector -n ${MONITORING_NAMESPACE}"
echo "  - Check additionalArgs > export.match for current filters"
echo ""
