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

if [ -z "$DEPLOYMENT_EXISTS" ]; then
  echo "❌ Deployment doesn't exist. Need to run k8s-deploy.sh first."
  exit 1
else
  echo "✅ Found existing deployment: $DEPLOYMENT_EXISTS"
  echo "Checking status..."
  $KUBECTL_CMD get deployment ${APP_NAME}-generator -n $NAMESPACE
  
  # Check for pod readiness
  READY_PODS=$($KUBECTL_CMD get deployment ${APP_NAME}-generator -n $NAMESPACE -o jsonpath='{.status.readyReplicas}')
  if [ "$READY_PODS" == "1" ]; then
    echo "✅ Deployment is fully ready"
  else
    echo "⚠️ Deployment not fully ready. Checking for issues..."
    $KUBECTL_CMD describe deployment ${APP_NAME}-generator -n $NAMESPACE
    
    # Check for pod issues
    POD_NAME=$($KUBECTL_CMD get pods -n $NAMESPACE -l app=${APP_NAME}-generator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ ! -z "$POD_NAME" ]; then
      echo "Found pod: $POD_NAME. Checking status..."
      $KUBECTL_CMD describe pod $POD_NAME -n $NAMESPACE
      echo "Pod logs:"
      $KUBECTL_CMD logs $POD_NAME -n $NAMESPACE --tail=50
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
NODE_PORT=$($KUBECTL_CMD get svc ${APP_NAME}-service -n $NAMESPACE -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)
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
  fi
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
echo "==================================================" 