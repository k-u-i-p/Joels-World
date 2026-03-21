#!/bin/bash

echo "🚀 Deploying Joels World to Google Cloud Run..."
# Read the API key from the local file
API_KEY=$(cat gemini_key)

gcloud run deploy joels-world \
  --source . \
  --region us-central1 \
  --allow-unauthenticated \
  --port 8080 \
  --set-env-vars GEMINI_API_KEY="${API_KEY}"

echo "✅ Deployment complete!"
