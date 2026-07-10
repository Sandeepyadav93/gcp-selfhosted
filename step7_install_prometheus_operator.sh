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
# Install Prometheus Operator for GMP Hybrid Architecture
# ============================================================================
# This script installs ONLY the Prometheus Operator (controller), not any
# Prometheus instances. The operator watches for Prometheus CRs and manages
# Prometheus StatefulSets.
#
# This matches production PR #337 approach:
# - Uses kube-prometheus-stack Helm chart in operator-only mode
# - All components except operator are disabled
# - CRDs are installed by the chart
# ============================================================================

PROMETHEUS_OPERATOR_VERSION="79.2.1"
PROMETHEUS_OPERATOR_NAMESPACE="prometheus-operator"

echo "=========================================="
echo "Installing Prometheus Operator"
echo "=========================================="
echo ""
echo "Version: ${PROMETHEUS_OPERATOR_VERSION}"
echo "Namespace: ${PROMETHEUS_OPERATOR_NAMESPACE}"
echo ""

# ============================================================================
# Check if Helm is installed
# ============================================================================
if ! command -v helm &> /dev/null; then
    echo "ERROR: helm is not installed or not in PATH"
    echo "Please install Helm: https://helm.sh/docs/intro/install/"
    exit 1
fi

echo "✓ Helm is installed: $(helm version --short)"
echo ""

# ============================================================================
# Add Prometheus Community Helm repository
# ============================================================================
echo "Adding prometheus-community Helm repository..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

echo "✓ Prometheus Community Helm repository added"
echo ""

# ============================================================================
# Check if Prometheus Operator is already installed
# ============================================================================
echo "Checking if Prometheus Operator is already installed..."
if helm list -n "${PROMETHEUS_OPERATOR_NAMESPACE}" | grep -q prometheus-operator; then
    echo ""
    echo "=========================================="
    echo "WARNING: Prometheus Operator Already Installed"
    echo "=========================================="
    echo ""
    echo "Current installation:"
    helm list -n "${PROMETHEUS_OPERATOR_NAMESPACE}"
    echo ""
    echo "If you want to reinstall, uninstall it first:"
    echo "  helm uninstall prometheus-operator -n ${PROMETHEUS_OPERATOR_NAMESPACE}"
    echo ""
    exit 1
fi

echo "✓ No existing Prometheus Operator installation found"
echo ""

# ============================================================================
# Create namespace
# ============================================================================
echo "Creating namespace ${PROMETHEUS_OPERATOR_NAMESPACE}..."
if ! kubectl get namespace "${PROMETHEUS_OPERATOR_NAMESPACE}" &>/dev/null; then
    kubectl create namespace "${PROMETHEUS_OPERATOR_NAMESPACE}"
    echo "✓ Namespace created"
else
    echo "✓ Namespace already exists"
fi
echo ""

# ============================================================================
# Install Prometheus Operator (operator-only mode)
# ============================================================================
echo "Installing Prometheus Operator ${PROMETHEUS_OPERATOR_VERSION}..."
echo ""
echo "Configuration:"
echo "  - CRDs: enabled (required for ServiceMonitor/PodMonitor/PrometheusRule)"
echo "  - Prometheus Operator: enabled"
echo "  - Prometheus instance: disabled"
echo "  - Alertmanager: disabled"
echo "  - Grafana: disabled"
echo "  - Node Exporter: disabled"
echo "  - Kube State Metrics: disabled"
echo "  - Default Rules: disabled"
echo "  - ServiceMonitors for K8s components: disabled"
echo ""

helm install prometheus-operator prometheus-community/kube-prometheus-stack \
  --namespace "${PROMETHEUS_OPERATOR_NAMESPACE}" \
  --version "${PROMETHEUS_OPERATOR_VERSION}" \
  --set crds.enabled=true \
  --set prometheusOperator.enabled=true \
  --set prometheus.enabled=false \
  --set alertmanager.enabled=false \
  --set grafana.enabled=false \
  --set nodeExporter.enabled=false \
  --set kubeStateMetrics.enabled=false \
  --set defaultRules.create=false \
  --set kubeApiServer.enabled=false \
  --set kubelet.enabled=false \
  --set kubeControllerManager.enabled=false \
  --set coreDns.enabled=false \
  --set kubeEtcd.enabled=false \
  --set kubeScheduler.enabled=false \
  --set kubeProxy.enabled=false

echo ""
echo "✓ Prometheus Operator Helm chart installed"
echo ""

# ============================================================================
# Wait for Prometheus Operator to be ready
# ============================================================================
echo "Waiting for Prometheus Operator to be ready..."
echo ""

# Wait for deployment to exist
echo "Waiting for operator deployment to be created..."
DEPLOYMENT_NAME=""
for i in {1..30}; do
  # Try to find the deployment by multiple possible selectors
  DEPLOYMENT_NAME=$(kubectl get deployment -n "${PROMETHEUS_OPERATOR_NAMESPACE}" \
    -l app.kubernetes.io/name=prometheus-operator -o name 2>/dev/null | head -1)

  # Fallback: try by partial name match
  if [ -z "$DEPLOYMENT_NAME" ]; then
    DEPLOYMENT_NAME=$(kubectl get deployment -n "${PROMETHEUS_OPERATOR_NAMESPACE}" \
      -o name 2>/dev/null | grep -i "operator" | head -1)
  fi

  if [ -n "$DEPLOYMENT_NAME" ]; then
    echo "✓ Operator deployment found: ${DEPLOYMENT_NAME}"
    break
  fi

  if [ $i -eq 30 ]; then
    echo "ERROR: Operator deployment not created after 60 seconds"
    echo "Available deployments:"
    kubectl get deployment -n "${PROMETHEUS_OPERATOR_NAMESPACE}"
    exit 1
  fi

  echo "  Waiting for deployment... (attempt $i/30)"
  sleep 2
done

# Wait for deployment to be available
echo "Waiting for operator deployment to be available (timeout: 300s)..."
if kubectl wait --for=condition=Available "${DEPLOYMENT_NAME}" \
    -n "${PROMETHEUS_OPERATOR_NAMESPACE}" \
    --timeout=300s 2>/dev/null; then
    echo "✓ Prometheus Operator is ready"
else
    echo "⚠ Condition=Available check failed, checking pod status directly..."

    # Fallback: wait for pods to be ready
    PODS_READY=false
    for i in {1..60}; do
      READY_PODS=$(kubectl get pods -n "${PROMETHEUS_OPERATOR_NAMESPACE}" \
        -l app.kubernetes.io/name=prometheus-operator \
        -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' 2>/dev/null | wc -w)

      if [ "$READY_PODS" -gt 0 ]; then
        echo "✓ Prometheus Operator pod is running"
        PODS_READY=true
        break
      fi

      if [ $i -eq 60 ]; then
        echo "ERROR: Prometheus Operator failed to become ready"
        echo ""
        echo "Pod status:"
        kubectl get pods -n "${PROMETHEUS_OPERATOR_NAMESPACE}"
        echo ""
        echo "Deployment status:"
        kubectl get deployment -n "${PROMETHEUS_OPERATOR_NAMESPACE}"
        echo ""
        echo "Check logs with:"
        echo "  kubectl logs -n ${PROMETHEUS_OPERATOR_NAMESPACE} -l app.kubernetes.io/name=prometheus-operator"
        exit 1
      fi

      echo "  Waiting for pods... (attempt $i/60)"
      sleep 2
    done
fi
echo ""

# ============================================================================
# Verify CRDs are installed
# ============================================================================
echo "Verifying Prometheus Operator CRDs are installed..."
echo ""

CRDS_TO_CHECK=(
    "prometheuses.monitoring.coreos.com"
    "prometheusrules.monitoring.coreos.com"
    "servicemonitors.monitoring.coreos.com"
    "podmonitors.monitoring.coreos.com"
    "alertmanagers.monitoring.coreos.com"
    "prometheusagents.monitoring.coreos.com"
)

ALL_CRDS_FOUND=true
for crd in "${CRDS_TO_CHECK[@]}"; do
    if kubectl get crd "${crd}" &>/dev/null; then
        echo "  ✓ ${crd}"
    else
        echo "  ✗ ${crd} NOT FOUND"
        ALL_CRDS_FOUND=false
    fi
done

if [ "$ALL_CRDS_FOUND" = false ]; then
    echo ""
    echo "ERROR: Some CRDs are missing. Installation may have failed."
    exit 1
fi

echo ""
echo "✓ All Prometheus Operator CRDs are installed"
echo ""

# ============================================================================
# Verification
# ============================================================================
echo "=========================================="
echo "Verification"
echo "=========================================="
echo ""

echo "Helm releases in ${PROMETHEUS_OPERATOR_NAMESPACE}:"
helm list -n "${PROMETHEUS_OPERATOR_NAMESPACE}"
echo ""

echo "Deployments in ${PROMETHEUS_OPERATOR_NAMESPACE}:"
kubectl get deployment -n "${PROMETHEUS_OPERATOR_NAMESPACE}"
echo ""

echo "Pods in ${PROMETHEUS_OPERATOR_NAMESPACE}:"
kubectl get pods -n "${PROMETHEUS_OPERATOR_NAMESPACE}"
echo ""

echo "Prometheus Operator CRDs:"
kubectl get crd | grep monitoring.coreos.com
echo ""

# ============================================================================
# Success message
# ============================================================================
echo "=========================================="
echo "✓ Prometheus Operator Installation Complete!"
echo "=========================================="
echo ""
echo "The Prometheus Operator (controller) is now running."
echo "It watches for Prometheus, ServiceMonitor, PodMonitor, and PrometheusRule CRs."
echo ""
echo "Next steps:"
echo "  1. Deploy Prometheus instance with step8_deploy_prometheus_gmp.sh"
echo "  2. Prometheus will automatically discover ServiceMonitors/PodMonitors cluster-wide"
echo "  3. Metrics will be exported to Google Managed Prometheus (GMP)"
echo ""
echo "To verify the operator is working:"
echo "  kubectl logs -n ${PROMETHEUS_OPERATOR_NAMESPACE} -l app.kubernetes.io/name=prometheus-operator -f"
echo ""
