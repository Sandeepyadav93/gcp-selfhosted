#!/bin/bash
set -euo pipefail

# Install required CRDs needed by Hypershift operator
# GKE doesn't by default include OpenShift CRDs
echo "Installing required CRDs for Hypershift operator"

echo "Installing Prometheus operator CRDs"
oc apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_servicemonitors.yaml
oc apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_prometheusrules.yaml
oc apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_podmonitors.yaml

echo "Installing OpenShift Route CRD"
oc apply -f https://raw.githubusercontent.com/openshift/api/6bababe9164ea6c78274fd79c94a3f951f8d5ab2/route/v1/zz_generated.crd-manifests/routes.crd.yaml

echo "Installing DNSEndpoint CRD (for ExternalDNS)"
oc apply -f https://raw.githubusercontent.com/kubernetes-sigs/external-dns/v0.15.0/docs/contributing/crd-source/crd-manifest.yaml

echo "CRD installation complete! All required CRDs for Hypershift operator are ready."

# ============================================================================
# Install cert-manager
# GKE Autopilot doesn't allow kube-system modifications, so we change
# leader election namespace to cert-manager
# See: https://cert-manager.io/docs/installation/compatibility/#gke-autopilot
# ============================================================================
CERT_MANAGER_VERSION="v1.14.0"
echo "Installing cert-manager ${CERT_MANAGER_VERSION}..."
curl -sL "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml" \
  | sed 's/kube-system/cert-manager/g' \
  | oc apply -f -

echo "Waiting for cert-manager to be ready..."
oc wait --for=condition=Available deployment/cert-manager -n cert-manager --timeout=300s
oc wait --for=condition=Available deployment/cert-manager-webhook -n cert-manager --timeout=300s
oc wait --for=condition=Available deployment/cert-manager-cainjector -n cert-manager --timeout=300s

# Wait for webhook to be fully operational (CA bundle injection takes time)
echo "Waiting for cert-manager webhook to be fully operational..."
for i in {1..30}; do
  if oc get validatingwebhookconfigurations cert-manager-webhook -o jsonpath='{.webhooks[0].clientConfig.caBundle}' 2>/dev/null | grep -q .; then
    echo "Webhook CA bundle is ready"
    break
  fi
  echo "Waiting for webhook CA bundle injection... (attempt $i/30)"
  sleep 10
done

# ============================================================================
# Create self-signed ClusterIssuer for internal certificates
# ============================================================================
echo "Creating ClusterIssuer..."
for i in {1..10}; do
  if cat <<EOF | oc apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
EOF
  then
    echo "ClusterIssuer created successfully"
    break
  fi
  echo "Failed to create ClusterIssuer, retrying... (attempt $i/10)"
  sleep 10
done

echo "Prerequisites installation complete! Cluster is ready as a Management Cluster for Hypershift."
