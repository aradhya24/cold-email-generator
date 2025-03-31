#!/bin/bash
set -e

# Apply deployment
envsubst < k8s/deployment.yaml | kubectl apply -f -

# Apply service
kubectl apply -f k8s/service.yaml

# Apply ingress
kubectl apply -f k8s/ingress.yaml

# Wait for deployment to be ready
kubectl rollout status deployment/cold-email-generator -n cold-email