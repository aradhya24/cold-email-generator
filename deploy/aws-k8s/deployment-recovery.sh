#!/bin/bash
# Script to recover and verify a previously started deployment

set -e

export APP_NAME=${APP_NAME:-cold-email}
export NAMESPACE=${NAMESPACE:-$APP_NAME}
export KUBECTL_CMD="k3s kubectl"

echo "===== Deployment Recovery for Cold Email Generator ====="

# Check if deployment exists
echo "Checking if deployment exists..."
DEPLOYMENT_EXISTS=$($KUBECTL_CMD get deployment ${APP_NAME}-generator -n $NAMESPACE --ignore-not-found -o name)

# Run debug script first to collect info
echo "Running diagnostics to gather information..."
./debug-deployment.sh || echo "Warning: Debug script completed with errors, continuing recovery process"

# Take appropriate action based on deployment status
if [ -z "$DEPLOYMENT_EXISTS" ]; then
  echo "❌ Deployment doesn't exist. Creating a new deployment..."
  
  # Check for configuration files
  if [ -f ~/app_access.txt ]; then
    echo "Loading saved configuration..."
    source ~/app_access.txt
  fi
  
  # Run k8s-deploy.sh to create a new deployment
  echo "Running deployment script with extended timeout..."
  DOCKER_IMAGE=${DOCKER_IMAGE:-ghcr.io/aradhya24/cold-email:latest} ./k8s-deploy.sh
else
  echo "✅ Found existing deployment: $DEPLOYMENT_EXISTS"
  echo "Checking status..."
  $KUBECTL_CMD get deployment ${APP_NAME}-generator -n $NAMESPACE
  
  # Check for pod readiness
  READY_PODS=$($KUBECTL_CMD get deployment ${APP_NAME}-generator -n $NAMESPACE -o jsonpath='{.status.readyReplicas}')
  if [ "$READY_PODS" == "1" ]; then
    echo "✅ Deployment is fully ready"
  else
    echo "⚠️ Deployment not fully ready. Attempting to fix..."
    
    # Reset the deployment by scaling down and up
    echo "Scaling deployment to 0 replicas..."
    $KUBECTL_CMD scale deployment ${APP_NAME}-generator -n $NAMESPACE --replicas=0
    
    echo "Waiting for all pods to terminate..."
    sleep 15
    
    echo "Scaling deployment back to 1 replica..."
    $KUBECTL_CMD scale deployment ${APP_NAME}-generator -n $NAMESPACE --replicas=1
    
    # Wait for new pod to be created
    echo "Waiting for new pod to be created..."
    sleep 10
    
    # Check new pod
    POD_NAME=$($KUBECTL_CMD get pods -n $NAMESPACE -l app=${APP_NAME}-generator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ ! -z "$POD_NAME" ]; then
      echo "Found pod: $POD_NAME. Checking status..."
      $KUBECTL_CMD describe pod $POD_NAME -n $NAMESPACE
      
      # Check for any images that might be failing to pull
      PULL_ERRORS=$($KUBECTL_CMD describe pod $POD_NAME -n $NAMESPACE | grep -i "failed to pull" || echo "")
      if [ ! -z "$PULL_ERRORS" ]; then
        echo "Image pull errors detected! Attempting to authenticate with container registry..."
        
        # Try to create a service account with registry access
        echo "Creating registry pull secret..."
        $KUBECTL_CMD create secret docker-registry ghcr-pull-secret \
          --docker-server=ghcr.io \
          --docker-username=$GITHUB_USERNAME \
          --docker-password=$GITHUB_TOKEN \
          --namespace $NAMESPACE \
          --dry-run=client -o yaml | $KUBECTL_CMD apply -f -
        
        # Update the deployment to use the pull secret
        echo "Patching deployment to use pull secret..."
        $KUBECTL_CMD patch deployment ${APP_NAME}-generator -n $NAMESPACE -p '{"spec":{"template":{"spec":{"imagePullSecrets":[{"name":"ghcr-pull-secret"}]}}}}'
      fi
    fi
  fi
fi

# Check if service exists
echo "Checking if service exists..."
SERVICE_EXISTS=$($KUBECTL_CMD get service ${APP_NAME}-service -n $NAMESPACE --ignore-not-found -o name)

if [ -z "$SERVICE_EXISTS" ]; then
  echo "❌ Service doesn't exist. Creating it now..."
  cat <<EOFSERVICE | $KUBECTL_CMD apply -f -
apiVersion: v1
kind: Service
metadata:
  name: ${APP_NAME}-service
  namespace: ${NAMESPACE}
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
    service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled: "true"
spec:
  type: LoadBalancer
  ports:
  - port: 80
    targetPort: 3000
    name: http
  selector:
    app: ${APP_NAME}-generator
EOFSERVICE
  echo "Service created. Waiting for LoadBalancer provisioning..."
else
  echo "✅ Found existing service: $SERVICE_EXISTS"
  echo "Checking service details..."
  $KUBECTL_CMD get service ${APP_NAME}-service -n $NAMESPACE
fi

# Check for NodePort service
NODEPORT_EXISTS=$($KUBECTL_CMD get service ${APP_NAME}-nodeport -n $NAMESPACE --ignore-not-found -o name)
if [ -z "$NODEPORT_EXISTS" ]; then
  echo "Creating NodePort service for direct access..."
  cat <<EOFNODEPORT | $KUBECTL_CMD apply -f -
apiVersion: v1
kind: Service
metadata:
  name: ${APP_NAME}-nodeport
  namespace: ${NAMESPACE}
spec:
  type: NodePort
  ports:
  - port: 3000
    targetPort: 3000
    nodePort: 30405
    name: http
  selector:
    app: ${APP_NAME}-generator
EOFNODEPORT
else
  echo "✅ NodePort service exists"
fi

# Check LoadBalancer status
echo "Checking LoadBalancer status..."
LB_HOSTNAME=$($KUBECTL_CMD get svc ${APP_NAME}-service -n $NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
LB_IP=$($KUBECTL_CMD get svc ${APP_NAME}-service -n $NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)

if [ ! -z "$LB_HOSTNAME" ]; then
  echo "✅ LoadBalancer hostname is provisioned: $LB_HOSTNAME"
  MAIN_URL="http://$LB_HOSTNAME"
elif [ ! -z "$LB_IP" ]; then
  echo "✅ LoadBalancer IP is provisioned: $LB_IP"
  MAIN_URL="http://$LB_IP"
else
  echo "⚠️ LoadBalancer not yet provisioned. This can take 3-5 minutes on AWS."
  echo "Current service status:"
  $KUBECTL_CMD describe svc ${APP_NAME}-service -n $NAMESPACE
fi

# Get NodePort as fallback access method
NODE_PORT=30405
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
FALLBACK_URL="http://$PUBLIC_IP:$NODE_PORT"

# Save access information for other scripts to use
echo "Saving access information to ~/app_access.txt..."
cat <<EOFACCESS > ~/app_access.txt
MAIN_URL="${MAIN_URL:-pending}"
FALLBACK_URL="${FALLBACK_URL}"
LB_HOSTNAME="${LB_HOSTNAME}"
LB_IP="${LB_IP}"
NODE_PORT="${NODE_PORT}"
PUBLIC_IP="${PUBLIC_IP}"
APP_NAME="${APP_NAME}"
NAMESPACE="${NAMESPACE}"
DOCKER_IMAGE="${DOCKER_IMAGE:-ghcr.io/aradhya24/cold-email:latest}"
EOFACCESS

# Update security group for NodePort access if needed
if [ ! -z "$NODE_PORT" ]; then
  echo "Ensuring security group allows access to NodePort $NODE_PORT..."
  INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
  SECURITY_GROUP=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --query "Reservations[0].Instances[0].SecurityGroups[0].GroupId" --output text)
  
  if [ ! -z "$SECURITY_GROUP" ]; then
    # Add NodePort rule
    echo "Ensuring NodePort $NODE_PORT is open..."
    aws ec2 authorize-security-group-ingress \
      --group-id $SECURITY_GROUP \
      --protocol tcp \
      --port $NODE_PORT \
      --cidr 0.0.0.0/0 2>/dev/null || echo "NodePort rule already exists"
    
    # Add HTTP rule
    echo "Ensuring HTTP port 80 is open..."
    aws ec2 authorize-security-group-ingress \
      --group-id $SECURITY_GROUP \
      --protocol tcp \
      --port 80 \
      --cidr 0.0.0.0/0 2>/dev/null || echo "HTTP rule already exists"
  fi
fi

# Create a port-forward for direct debug access
echo "Setting up port-forward for direct access (for debugging)..."
POD_NAME=$($KUBECTL_CMD get pods -n $NAMESPACE -l app=${APP_NAME}-generator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ ! -z "$POD_NAME" ]; then
  echo "Starting port-forward for pod $POD_NAME in background..."
  $KUBECTL_CMD port-forward pod/$POD_NAME 8080:3000 -n $NAMESPACE > /dev/null 2>&1 &
  PF_PID=$!
  echo "Port-forward started with PID $PF_PID. App should be accessible at http://localhost:8080"
  echo "PF_PID=$PF_PID" >> ~/app_access.txt
fi

# Display access URLs
echo ""
echo "==== Cold Email Generator Deployment Recovery Summary ===="
echo "ℹ️ Access URLs:"
if [ ! -z "$MAIN_URL" ] && [ "$MAIN_URL" != "pending" ]; then
  echo "📌 Main URL (LoadBalancer): $MAIN_URL"
  echo "Testing access..."
  curl -s --connect-timeout 5 -I "$MAIN_URL" || echo "LoadBalancer not fully accessible yet, this is normal"
else
  echo "📌 Main URL: LoadBalancer still provisioning (may take 3-5 minutes)"
  echo "   Check status with: k3s kubectl describe svc ${APP_NAME}-service -n $NAMESPACE"
fi

if [ ! -z "$FALLBACK_URL" ]; then
  echo "📌 Fallback URL (NodePort): $FALLBACK_URL"
  echo "Testing access..."
  curl -s --connect-timeout 5 -I "$FALLBACK_URL" || echo "NodePort not accessible yet"
fi

echo ""
echo "⚠️ NOTE: AWS LoadBalancer typically takes 3-5 minutes to become fully accessible"
echo "   If the Main URL doesn't work immediately, try again in a few minutes"
echo "   or use the Fallback URL in the meantime."
echo ""
echo "✅ To verify application access, run: ./verify-access.sh"
echo "===== Troubleshooting ====="
echo "- If you're having deployment issues, run: ./debug-deployment.sh"
echo "- To force a new deployment, run: ./k8s-deploy.sh"
echo "==================================================" 