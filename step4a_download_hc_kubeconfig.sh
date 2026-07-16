#!/bin/bash
set -euo pipefail

# Configuration
HC_NAME="${HC_NAME:-hc1}"
HC_NAMESPACE="${HC_NAMESPACE:-clusters}"
export KUBECONFIG_OUTPUT="${KUBECONFIG_OUTPUT:-/tmp/${HC_NAME}}"
POLL_INTERVAL="${POLL_INTERVAL:-30}"
TIMEOUT="${TIMEOUT:-1800}"

echo "=========================================="
echo "Download Hosted Cluster Kubeconfig"
echo "=========================================="
echo ""
echo "  Cluster Name: ${HC_NAME}"
echo "  Namespace: ${HC_NAMESPACE}"
echo "  Output: ${KUBECONFIG_OUTPUT}"
echo "  Poll Interval: ${POLL_INTERVAL}s"
echo "  Timeout: ${TIMEOUT}s"
echo ""

echo "Waiting for HostedCluster '${HC_NAME}' to become available..."
echo ""

ELAPSED=0

while true; do
    if [ ${ELAPSED} -ge ${TIMEOUT} ]; then
        echo ""
        echo "ERROR: Timed out after ${TIMEOUT}s waiting for cluster to become available."
        echo ""
        echo "Current HostedCluster status:"
        oc get hostedcluster -n "${HC_NAMESPACE}" "${HC_NAME}" 2>/dev/null || echo "  HostedCluster not found"
        echo ""
        echo "Current NodePool status:"
        oc get nodepool -n "${HC_NAMESPACE}" "${HC_NAME}" 2>/dev/null || echo "  NodePool not found"
        exit 1
    fi

    # Check if HostedCluster exists
    if ! oc get hostedcluster -n "${HC_NAMESPACE}" "${HC_NAME}" &>/dev/null; then
        echo "[${ELAPSED}s] HostedCluster '${HC_NAME}' not found yet. Retrying in ${POLL_INTERVAL}s..."
        sleep "${POLL_INTERVAL}"
        ELAPSED=$((ELAPSED + POLL_INTERVAL))
        continue
    fi

    # Check if HostedCluster is available
    HC_AVAILABLE=$(oc get hostedcluster -n "${HC_NAMESPACE}" "${HC_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "")
    if [ "${HC_AVAILABLE}" != "True" ]; then
        HC_PROGRESS=$(oc get hostedcluster -n "${HC_NAMESPACE}" "${HC_NAME}" -o jsonpath='{.status.progress}' 2>/dev/null || echo "Unknown")
        HC_MESSAGE=$(oc get hostedcluster -n "${HC_NAMESPACE}" "${HC_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Available")].message}' 2>/dev/null || echo "")
        echo "[${ELAPSED}s] HostedCluster not available yet. Progress: ${HC_PROGRESS}. ${HC_MESSAGE}"
        sleep "${POLL_INTERVAL}"
        ELAPSED=$((ELAPSED + POLL_INTERVAL))
        continue
    fi

    # Check if NodePool has desired nodes ready
    NP_DESIRED=$(oc get nodepool -n "${HC_NAMESPACE}" "${HC_NAME}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
    NP_CURRENT=$(oc get nodepool -n "${HC_NAMESPACE}" "${HC_NAME}" -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0")
    if [ "${NP_CURRENT}" != "${NP_DESIRED}" ] || [ "${NP_CURRENT}" == "0" ]; then
        echo "[${ELAPSED}s] NodePool not ready. Desired: ${NP_DESIRED}, Current: ${NP_CURRENT}"
        sleep "${POLL_INTERVAL}"
        ELAPSED=$((ELAPSED + POLL_INTERVAL))
        continue
    fi

    echo "[${ELAPSED}s] HostedCluster is available and NodePool is ready (${NP_CURRENT}/${NP_DESIRED} nodes)."
    break
done

echo ""
echo "=========================================="
echo "Downloading kubeconfig"
echo "=========================================="
echo ""

# Extract kubeconfig from the admin-kubeconfig secret
HC_SECRET_NAMESPACE="clusters-${HC_NAME}"
SECRET_NAME="admin-kubeconfig"

echo "Extracting kubeconfig from secret '${SECRET_NAME}' in namespace '${HC_SECRET_NAMESPACE}'..."

if ! oc get secret -n "${HC_SECRET_NAMESPACE}" "${SECRET_NAME}" &>/dev/null; then
    echo "ERROR: Secret '${SECRET_NAME}' not found in namespace '${HC_SECRET_NAMESPACE}'"
    exit 1
fi

oc get secret -n "${HC_SECRET_NAMESPACE}" "${SECRET_NAME}" -o json | jq -r '.data.kubeconfig' | base64 -d > "${KUBECONFIG_OUTPUT}"

echo ""
echo "=========================================="
echo "Kubeconfig downloaded successfully!"
echo "=========================================="
echo ""
echo "  Saved to: ${KUBECONFIG_OUTPUT}"
echo ""
echo "To use the hosted cluster:"
echo "  export KUBECONFIG=${KUBECONFIG_OUTPUT}"
echo "  oc get nodes"
echo "  oc get clusterversion"
echo ""
echo "HostedCluster status:"
oc get hostedcluster -n "${HC_NAMESPACE}" "${HC_NAME}"
echo ""
echo "NodePool status:"
oc get nodepool -n "${HC_NAMESPACE}" "${HC_NAME}"
