#!/bin/bash

echo "📡 Steaming stdout logs from Joels World (Google Cloud Run)..."
gcloud beta run services logs tail joels-world \
  --region us-central1 \
  --log-filter="logName:stdout"
