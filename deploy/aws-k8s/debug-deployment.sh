#!/bin/bash
# Script to debug Kubernetes deployment issues for Cold Email Generator

set -e

# Set default values
export APP_NAME=${APP_NAME:-cold-email}
export NAMESPACE=${NAMESPACE:-$APP_NAME}
export KUBECTL_CMD="k3s kubectl"

echo "===== Debugging Cold Email Generator Deployment ====="

# Check node status
echo "Checking Kubernetes node status..."
$KUBECTL_CMD get nodes
$KUBECTL_CMD describe nodes

# Check all namespaces and pods
echo "Checking all namespaces and pods..."
$KUBECTL_CMD get namespaces
$KUBECTL_CMD get pods -A

# Check specific namespace and deployment
echo "Checking deployment in namespace $NAMESPACE..."
$KUBECTL_CMD get all -n $NAMESPACE

# Check deployment details
echo "Checking deployment details..."
$KUBECTL_CMD describe deployment ${APP_NAME}-generator -n $NAMESPACE || echo "Deployment not found"

# Check pod status
echo "Checking pod status..."
POD_NAME=$($KUBECTL_CMD get pods -n $NAMESPACE -l app=${APP_NAME}-generator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ ! -z "$POD_NAME" ]; then
  echo "Found pod: $POD_NAME"
  
  # Describe the pod
  echo "Pod details:"
  $KUBECTL_CMD describe pod $POD_NAME -n $NAMESPACE
  
  # Check pod logs
  echo "Pod logs:"
  $KUBECTL_CMD logs $POD_NAME -n $NAMESPACE --tail=100 || echo "No logs available"
  
  # Check for previous pod logs if container restarted
  echo "Previous container logs (if any):"
  $KUBECTL_CMD logs $POD_NAME -n $NAMESPACE --previous --tail=50 || echo "No previous logs available"
  
  # Check resource usage
  echo "Resource usage:"
  $KUBECTL_CMD top pod $POD_NAME -n $NAMESPACE || echo "Resource metrics not available"
else
  echo "No pods found for app=${APP_NAME}-generator in namespace $NAMESPACE"
  
  # Check if any pods exist
  echo "All pods in namespace $NAMESPACE:"
  $KUBECTL_CMD get pods -n $NAMESPACE
fi

# Check container image
echo "Checking Docker image..."
echo "Image: ${DOCKER_IMAGE:-ghcr.io/aradhya24/cold-email:latest}"

# Verify Docker image accessibility
echo "Testing Docker image pull..."
sudo docker pull ${DOCKER_IMAGE:-ghcr.io/aradhya24/cold-email:latest} || echo "Failed to pull image"

# Check events
echo "Recent Kubernetes events:"
$KUBECTL_CMD get events -n $NAMESPACE --sort-by=.metadata.creationTimestamp | tail -n 30

# Check Service
echo "Checking service status..."
$KUBECTL_CMD get svc -n $NAMESPACE
$KUBECTL_CMD describe svc ${APP_NAME}-service -n $NAMESPACE || echo "Service not found"
$KUBECTL_CMD describe svc ${APP_NAME}-nodeport -n $NAMESPACE || echo "NodePort service not found"

# Check DNS and network connectivity
echo "Checking DNS resolution..."
nslookup kubernetes.default.svc.cluster.local || echo "DNS resolution failed"

# Test port forwarding
echo "Testing direct port-forward to pod if available..."
if [ ! -z "$POD_NAME" ]; then
  echo "Setting up port-forward for testing..."
  $KUBECTL_CMD port-forward pod/$POD_NAME 8888:3000 -n $NAMESPACE &
  PF_PID=$!
  sleep 3
  
  # Test the port-forward
  echo "Testing port-forward connection..."
  curl -s --max-time 5 http://localhost:8888 | head -n 20 || echo "Failed to connect via port-forward"
  
  # Kill the port-forward process
  kill $PF_PID
fi

# Check node port connectivity
NODE_PORT=30405
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
echo "Testing NodePort access at http://$PUBLIC_IP:$NODE_PORT..."
curl -s --max-time 5 http://$PUBLIC_IP:$NODE_PORT | head -n 20 || echo "Failed to connect via NodePort"

# Check for security group rules
echo "Checking security group rules..."
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
SECURITY_GROUP=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --query "Reservations[0].Instances[0].SecurityGroups[0].GroupId" --output text)
aws ec2 describe-security-groups --group-ids $SECURITY_GROUP

echo "===== Debug information collection complete ====="
echo "Use this information to diagnose why your deployment is failing."
echo "Common issues include:"
echo "1. Image pull errors - check your Docker image exists and is accessible"
echo "2. Resource limits - pod may be OOMKilled or insufficient CPU"
echo "3. Application startup errors - check the pod logs"
echo "4. Network issues - check security groups and connectivity"
echo "====================================================" 