#!/bin/bash

echo "🚀 Deploying Joels World to Google Cloud Run..."
gcloud run deploy joels-world \
  --source . \
  --region us-central1 \
  --allow-unauthenticated \
  --port 8080

echo "✅ Deployment complete!"
