#!/bin/bash
while true; do
  gcloud auth print-access-token > /tmp/gmp-token-file
  echo "$(date): token refreshed"
  sleep 600
done
