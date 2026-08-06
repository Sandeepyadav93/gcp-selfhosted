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
export HC_NAME="${HC_NAME:-hc1}"
export BASE_DOMAIN="${BASE_DOMAIN:-gcp2.hyp.azure.rhperfscale.org}"
export CP_PROJECT_ID="${CP_PROJECT_ID:-perfscale-testing-mc}"
export PARENT_DNS_ZONE="${PARENT_DNS_ZONE:-hypershift-gcp-zone}"

ACTION="${1:-create}"

CHILD_DNS_NAME="${HC_NAME}.${BASE_DOMAIN}"

echo "=========================================="
echo "Cluster DNS Management"
echo "=========================================="
echo "  Action: ${ACTION}"
echo "  Cluster Name: ${HC_NAME}"
echo "  Base Domain: ${BASE_DOMAIN}"
echo "  Child DNS: ${CHILD_DNS_NAME}"
echo "  Parent Zone: ${PARENT_DNS_ZONE}"
echo "  Project: ${CP_PROJECT_ID}"
echo ""

case "${ACTION}" in
  create)
    # Step 1: Create child DNS zone
    echo "Step 1: Creating child DNS zone '${HC_NAME}'..."
    if gcloud dns managed-zones describe "${HC_NAME}" --project="${CP_PROJECT_ID}" &>/dev/null; then
        echo "  Zone '${HC_NAME}' already exists, skipping creation."
    else
        gcloud dns managed-zones create "${HC_NAME}" \
          --dns-name="${CHILD_DNS_NAME}." \
          --description="HyperShift HCP base domain for ${HC_NAME}" \
          --visibility=public \
          --project="${CP_PROJECT_ID}" \
          --quiet
        echo "  ✓ Child DNS zone created."
    fi
    echo ""

    # Step 2: Add NS delegation in parent zone
    echo "Step 2: Adding NS delegation in parent zone '${PARENT_DNS_ZONE}'..."
    if gcloud dns record-sets list --zone="${PARENT_DNS_ZONE}" --project="${CP_PROJECT_ID}" \
        --name="${CHILD_DNS_NAME}." --type=NS --format=json 2>/dev/null | grep -q '"rrdata'; then
        echo "  NS delegation already exists, skipping."
    else
        NS_SERVERS=$(gcloud dns managed-zones describe "${HC_NAME}" \
          --project="${CP_PROJECT_ID}" \
          --format="value(nameServers)" | tr ';' ',')

        gcloud dns record-sets create "${CHILD_DNS_NAME}." \
          --zone="${PARENT_DNS_ZONE}" \
          --project="${CP_PROJECT_ID}" \
          --type=NS \
          --ttl=300 \
          --rrdatas="${NS_SERVERS}"
        echo "  ✓ NS delegation added."
    fi
    echo ""

    echo "=========================================="
    echo "DNS Setup Complete!"
    echo "=========================================="
    echo ""
    echo "Child DNS domain: ${CHILD_DNS_NAME}"
    echo ""
    echo "You can now create the cluster with:"
    echo "  HC_NAME=${HC_NAME} ./step4_create_cluster.sh"
    ;;

  delete)
    set +e

    # Step 1: Remove NS delegation from parent zone
    echo "Step 1: Removing NS delegation from parent zone '${PARENT_DNS_ZONE}'..."
    if gcloud dns record-sets list --zone="${PARENT_DNS_ZONE}" --project="${CP_PROJECT_ID}" \
        --name="${CHILD_DNS_NAME}." --type=NS --format=json 2>/dev/null | grep -q '"rrdata'; then
        gcloud dns record-sets delete "${CHILD_DNS_NAME}." \
          --zone="${PARENT_DNS_ZONE}" \
          --project="${CP_PROJECT_ID}" \
          --type=NS \
          --quiet
        echo "  ✓ NS delegation removed."
    else
        echo "  No NS delegation found, skipping."
    fi
    echo ""

    # Step 2: Delete non-default records from child zone
    echo "Step 2: Cleaning up records in child zone '${HC_NAME}'..."
    if gcloud dns managed-zones describe "${HC_NAME}" --project="${CP_PROJECT_ID}" &>/dev/null; then
        RECORDS=$(gcloud dns record-sets list --zone="${HC_NAME}" --project="${CP_PROJECT_ID}" --format=json 2>/dev/null)
        echo "${RECORDS}" | jq -r '.[] | select(.type != "SOA" and .type != "NS") | "\(.name) \(.type)"' 2>/dev/null | \
        while read -r NAME TYPE; do
            echo "  Deleting ${TYPE} ${NAME}..."
            gcloud dns record-sets delete "${NAME}" \
              --zone="${HC_NAME}" \
              --project="${CP_PROJECT_ID}" \
              --type="${TYPE}" \
              --quiet
        done

        # Step 3: Delete child DNS zone
        echo ""
        echo "Step 3: Deleting child DNS zone '${HC_NAME}'..."
        gcloud dns managed-zones delete "${HC_NAME}" \
          --project="${CP_PROJECT_ID}" \
          --quiet
        echo "  ✓ Child DNS zone deleted."
    else
        echo "  Zone '${HC_NAME}' does not exist, skipping."
    fi
    echo ""

    echo "=========================================="
    echo "DNS Cleanup Complete!"
    echo "=========================================="
    ;;

  *)
    echo "Usage: $0 {create|delete}"
    echo ""
    echo "Examples:"
    echo "  HC_NAME=hc1 $0 create"
    echo "  HC_NAME=hc1 $0 delete"
    exit 1
    ;;
esac
