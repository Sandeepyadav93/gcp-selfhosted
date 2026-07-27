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
# Delete Prometheus and its persistent disks
# ============================================================================
# Run this BEFORE step6 (delete GKE) to avoid orphaned GCE persistent disks.
# When a GKE cluster is deleted, PVCs with reclaimPolicy=Delete should be
# cleaned up, but dynamically provisioned disks can be left behind if the
# PVC/PV deletion doesn't complete before the cluster is gone.
# ============================================================================

export CP_PROJECT_ID="${CP_PROJECT_ID:-YOUR_PROJECT_ID}"
export GCP_REGION="${GCP_REGION:-us-central1}"

MONITORING_NAMESPACE="monitoring"
PROMETHEUS_OPERATOR_NAMESPACE="prometheus-operator"

echo "=========================================="
echo "Deleting Prometheus & Operator (with disk cleanup)"
echo "=========================================="
echo ""
echo "Configuration:"
echo "  Project ID: ${CP_PROJECT_ID}"
echo "  Region: ${GCP_REGION}"
echo "  Monitoring namespace: ${MONITORING_NAMESPACE}"
echo "  Operator namespace: ${PROMETHEUS_OPERATOR_NAMESPACE}"
echo ""

# ============================================================================
# Step 1: Delete Prometheus instance (triggers StatefulSet + PVC deletion)
# ============================================================================
echo "Step 1: Deleting Prometheus instance..."

if kubectl get prometheus gmp-collector -n "${MONITORING_NAMESPACE}" &>/dev/null; then
    kubectl delete prometheus gmp-collector -n "${MONITORING_NAMESPACE}" --timeout=60s
    echo "✓ Prometheus CR deleted"
else
    echo "  Prometheus CR not found, skipping..."
fi
echo ""

# ============================================================================
# Step 2: Wait for StatefulSet and pods to be cleaned up by the operator
# ============================================================================
echo "Step 2: Waiting for Prometheus pods to terminate..."

for i in {1..30}; do
    POD_COUNT=$(kubectl get pods -n "${MONITORING_NAMESPACE}" -l prometheus=gmp-collector --no-headers 2>/dev/null | wc -l)
    if [ "$POD_COUNT" -eq 0 ]; then
        echo "✓ All Prometheus pods terminated"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "⚠ Pods still terminating after 60s, proceeding anyway..."
    fi
    echo "  Waiting for pods to terminate... ($POD_COUNT remaining)"
    sleep 2
done
echo ""

# ============================================================================
# Step 3: Delete PVCs in monitoring namespace (releases the PVs and GCE disks)
# ============================================================================
echo "Step 3: Deleting PVCs in ${MONITORING_NAMESPACE}..."

PVCS=$(kubectl get pvc -n "${MONITORING_NAMESPACE}" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null || true)
if [ -n "$PVCS" ]; then
    echo "  Found PVCs:"
    kubectl get pvc -n "${MONITORING_NAMESPACE}"
    echo ""
    kubectl delete pvc --all -n "${MONITORING_NAMESPACE}" --timeout=60s
    echo "✓ PVCs deleted"
else
    echo "  No PVCs found, skipping..."
fi
echo ""

# ============================================================================
# Step 4: Verify PVs are released/deleted
# ============================================================================
echo "Step 4: Verifying PVs are cleaned up..."

for i in {1..15}; do
    BOUND_PVS=$(kubectl get pv --no-headers 2>/dev/null | grep "${MONITORING_NAMESPACE}" | wc -l)
    if [ "$BOUND_PVS" -eq 0 ]; then
        echo "✓ No PVs bound to ${MONITORING_NAMESPACE}"
        break
    fi
    if [ $i -eq 15 ]; then
        echo "⚠ Some PVs may still exist:"
        kubectl get pv | grep "${MONITORING_NAMESPACE}" || true
        echo ""
        echo "  If reclaimPolicy is Retain, delete manually:"
        echo "    kubectl get pv | grep ${MONITORING_NAMESPACE}"
        echo "    kubectl delete pv <pv-name>"
    fi
    echo "  Waiting for PV cleanup... ($BOUND_PVS remaining)"
    sleep 2
done
echo ""

# ============================================================================
# Step 5: Delete public LoadBalancer service
# ============================================================================
echo "Step 5: Deleting public LoadBalancer service..."

if kubectl get svc prometheus-public -n "${MONITORING_NAMESPACE}" &>/dev/null; then
    kubectl delete svc prometheus-public -n "${MONITORING_NAMESPACE}" --timeout=60s
    echo "✓ Public service deleted"
else
    echo "  Public service not found, skipping..."
fi
echo ""

# ============================================================================
# Step 6: Delete monitoring namespace
# ============================================================================
echo "Step 6: Deleting namespace ${MONITORING_NAMESPACE}..."

if kubectl get namespace "${MONITORING_NAMESPACE}" &>/dev/null; then
    kubectl delete namespace "${MONITORING_NAMESPACE}" --timeout=120s
    echo "✓ Namespace ${MONITORING_NAMESPACE} deleted"
else
    echo "  Namespace not found, skipping..."
fi
echo ""

# ============================================================================
# Step 7: Uninstall Prometheus Operator Helm release
# ============================================================================
echo "Step 7: Uninstalling Prometheus Operator Helm release..."

if helm list -n "${PROMETHEUS_OPERATOR_NAMESPACE}" | grep -q prometheus-operator; then
    helm uninstall prometheus-operator -n "${PROMETHEUS_OPERATOR_NAMESPACE}"
    echo "✓ Prometheus Operator Helm release uninstalled"
else
    echo "  Prometheus Operator Helm release not found, skipping..."
fi
echo ""

# ============================================================================
# Step 8: Delete Prometheus Operator namespace
# ============================================================================
echo "Step 8: Deleting namespace ${PROMETHEUS_OPERATOR_NAMESPACE}..."

if kubectl get namespace "${PROMETHEUS_OPERATOR_NAMESPACE}" &>/dev/null; then
    kubectl delete namespace "${PROMETHEUS_OPERATOR_NAMESPACE}" --timeout=120s
    echo "✓ Namespace ${PROMETHEUS_OPERATOR_NAMESPACE} deleted"
else
    echo "  Namespace not found, skipping..."
fi
echo ""

# ============================================================================
# Step 9: Check for orphaned GCE disks
# ============================================================================
echo "Step 9: Checking for orphaned GCE disks from Prometheus..."
echo ""

ORPHANED_DISKS=$(gcloud compute disks list \
    --project="${CP_PROJECT_ID}" \
    --filter="name~pvc AND -users:*" \
    --format="table(name,zone,sizeGb,status)" 2>/dev/null || true)

if [ -n "$ORPHANED_DISKS" ]; then
    echo "⚠ Found unattached PVC disks that may be orphaned:"
    echo ""
    echo "$ORPHANED_DISKS"
    echo ""
    echo "To delete them manually:"
    echo "  gcloud compute disks list --project=${CP_PROJECT_ID} --filter='name~pvc AND -users:*'"
    echo "  gcloud compute disks delete <disk-name> --zone=<zone> --project=${CP_PROJECT_ID} --quiet"
else
    echo "✓ No orphaned PVC disks found"
fi
echo ""

# ============================================================================
# Done
# ============================================================================
echo "=========================================="
echo "✓ Prometheus cleanup complete!"
echo "=========================================="
echo ""
echo "It is now safe to delete the GKE cluster with step6_delete_gke.sh"
echo "without leaving orphaned persistent disks in GCP."
echo ""
