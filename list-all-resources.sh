#!/bin/bash
PROJECT="managed-cloud-pltaforms"

echo "=== COMPUTE ==="
echo "Instances:"
gcloud compute instances list --project=$PROJECT

echo -e "\nDisks:"
gcloud compute disks list --project=$PROJECT

echo -e "\nSnapshots:"
gcloud compute snapshots list --project=$PROJECT

echo -e "\n=== NETWORKING ==="
echo "Networks:"
gcloud compute networks list --project=$PROJECT

echo -e "\nSubnets:"
gcloud compute networks subnets list --project=$PROJECT

echo -e "\nFirewall Rules:"
gcloud compute firewall-rules list --project=$PROJECT --format="table(name,network,direction,priority,sourceRanges.list():label=SRC_RANGES,allowed[].map().firewall_rule().list():label=ALLOW)"

echo -e "\nRoutes:"
gcloud compute routes list --project=$PROJECT

echo -e "\nIP Addresses (All):"
gcloud compute addresses list --project=$PROJECT

echo -e "\nIP Addresses (Global):"
gcloud compute addresses list --global --project=$PROJECT

echo -e "\nCloud Routers:"
gcloud compute routers list --project=$PROJECT

echo -e "\nVPN Gateways:"
gcloud compute vpn-gateways list --project=$PROJECT

echo -e "\nVPN Tunnels:"
gcloud compute vpn-tunnels list --project=$PROJECT

echo -e "\n=== LOAD BALANCING ==="
echo "Forwarding Rules (Regional):"
gcloud compute forwarding-rules list --project=$PROJECT

echo -e "\nForwarding Rules (Global):"
gcloud compute forwarding-rules list --global --project=$PROJECT

echo -e "\nBackend Services (Regional):"
gcloud compute backend-services list --project=$PROJECT

echo -e "\nBackend Services (Global):"
gcloud compute backend-services list --global --project=$PROJECT

echo -e "\nTarget Pools:"
gcloud compute target-pools list --project=$PROJECT

echo -e "\nTarget HTTP Proxies:"
gcloud compute target-http-proxies list --project=$PROJECT

echo -e "\nTarget HTTPS Proxies:"
gcloud compute target-https-proxies list --project=$PROJECT

echo -e "\nURL Maps:"
gcloud compute url-maps list --project=$PROJECT

echo -e "\nHealth Checks:"
gcloud compute health-checks list --project=$PROJECT

echo -e "\nSSL Certificates:"
gcloud compute ssl-certificates list --project=$PROJECT

echo -e "\nNetwork Endpoint Groups:"
gcloud compute network-endpoint-groups list --project=$PROJECT

echo -e "\n=== PRIVATE SERVICE CONNECT ==="
echo "Service Attachments:"
gcloud compute service-attachments list --project=$PROJECT

echo -e "\n=== KUBERNETES ==="
echo "GKE Clusters:"
gcloud container clusters list --project=$PROJECT

echo -e "\n=== STORAGE ==="
echo "Cloud Storage Buckets:"
gcloud storage buckets list --project=$PROJECT 2>/dev/null || gsutil ls -p $PROJECT



echo -e "\n=== IAM ==="
echo "Service Accounts:"
gcloud iam service-accounts list --project=$PROJECT


echo -e "\n=== DONE ==="
echo "Review the output above for any resources that need cleanup"
