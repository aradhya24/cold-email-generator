#!/bin/bash
set -e

# Apply deployment with substituted environment variables
echo "Deploying application with CI_REGISTRY=${CI_REGISTRY} and CI_COMMIT_SHA=${CI_COMMIT_SHA}"
LB_DNS=${LB_DNS} envsubst < k8s/deployment.yaml | kubectl apply -f -

# Apply service
kubectl apply -f k8s/service.yaml

# Apply ingress
kubectl apply -f k8s/ingress.yaml

# Wait for deployment to be ready
echo "Waiting for deployment to be ready..."
kubectl rollout status deployment/cold-email-generator -n cold-email --timeout=120s

# Print service details
NODE_PORT=$(kubectl get svc -n cold-email cold-email-service -o jsonpath='{.spec.ports[0].nodePort}')
echo "Application deployed and accessible at:"
echo "Load Balancer URL: http://${LB_DNS}"
echo "Node Port URL: http://$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4):${NODE_PORT}"