#!/bin/bash
# Kubernetes deployment script for cold email generator application

set -e

echo "====== Deploying Cold Email Generator to Kubernetes ======"

# Ensure required environment variables are set
if [ -z "$DOCKER_IMAGE" ]; then
  echo "ERROR: DOCKER_IMAGE environment variable is not set"
  echo "Please set DOCKER_IMAGE to the full path of your Docker image including tag"
  echo "Example: export DOCKER_IMAGE=ghcr.io/yourusername/cold-email:latest"
  exit 1
fi

if [ -z "$LB_DNS" ]; then
  echo "WARNING: LB_DNS environment variable is not set"
  echo "The application will be deployed but might not have the load balancer DNS information"
fi

echo "Using Docker image: $DOCKER_IMAGE"
echo "Using Load Balancer DNS: $LB_DNS"

# Apply deployment with environment variable substitution
echo "Deploying the application..."
cd $HOME/k8s
envsubst < deployment.yaml > deployment-rendered.yaml
kubectl apply -f deployment-rendered.yaml

# Apply service
echo "Creating service..."
kubectl apply -f service.yaml

# Apply ingress
echo "Creating ingress..."
kubectl apply -f ingress.yaml

# Wait for deployment to be ready
echo "Waiting for deployment to be ready..."
kubectl rollout status deployment/cold-email-generator -n cold-email --timeout=120s

# Get service details
NODE_PORT=$(kubectl get svc -n cold-email cold-email-service -o jsonpath='{.spec.ports[0].nodePort}')
NODE_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)

echo ""
echo "====== Deployment Summary ======"
echo "Application deployment complete!"
echo ""
echo "Application is accessible at:"
echo "- Load Balancer URL: http://${LB_DNS}"
echo "- Node Port URL: http://${NODE_IP}:${NODE_PORT}"
echo ""
echo "Kubernetes resources:"
echo "- Namespace: cold-email"
echo "- Deployment: cold-email-generator"
echo "- Service: cold-email-service"
echo "- Ingress: cold-email-ingress"
echo ""

# Check pod status
echo "Pod status:"
kubectl get pods -n cold-email

# Show ingress details
echo ""
echo "Ingress details:"
kubectl describe ingress cold-email-ingress -n cold-email 