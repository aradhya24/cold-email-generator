#!/bin/bash
# Script to deploy the Cold Email Generator to an AWS K3s cluster

set -e

export DOCKER_IMAGE=${DOCKER_IMAGE:-ghcr.io/aradhya24/cold-email:latest}
export APP_NAME=${APP_NAME:-cold-email}
export NAMESPACE=${NAMESPACE:-$APP_NAME}
export KUBECTL_CMD="k3s kubectl"

# Create namespace if it doesn't exist
echo "Creating namespace $NAMESPACE if it doesn't exist..."
$KUBECTL_CMD create namespace $NAMESPACE --dry-run=client -o yaml | $KUBECTL_CMD apply -f -

# Create secret for Groq API key if provided
if [ ! -z "$GROQ_API_KEY" ]; then
  echo "Creating Groq API key secret..."
  $KUBECTL_CMD create secret generic groq-api-key \
    --from-literal=GROQ_API_KEY=$GROQ_API_KEY \
    --namespace $NAMESPACE \
    --dry-run=client -o yaml | $KUBECTL_CMD apply -f -
fi

# Make sure existing services are deleted to avoid conflicts
echo "Removing any existing services to avoid conflicts..."
$KUBECTL_CMD delete service ${APP_NAME}-service -n $NAMESPACE --ignore-not-found
# Also clean up any test deployments if they exist
$KUBECTL_CMD delete deployment test-nginx -n default --ignore-not-found

# Deploy the application
echo "Deploying Cold Email Generator to Kubernetes..."
cat <<EOF | $KUBECTL_CMD apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP_NAME}-generator
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${APP_NAME}-generator
  template:
    metadata:
      labels:
        app: ${APP_NAME}-generator
    spec:
      containers:
      - name: app
        image: ${DOCKER_IMAGE}
        imagePullPolicy: Always
        ports:
        - containerPort: 3000
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "256Mi"
            cpu: "300m"
        env:
        - name: PORT
          value: "3000"
        - name: NODE_ENV
          value: "production"
        readinessProbe:
          httpGet:
            path: /
            port: 3000
          initialDelaySeconds: 10
          periodSeconds: 5
        livenessProbe:
          httpGet:
            path: /
            port: 3000
          initialDelaySeconds: 30
          periodSeconds: 20
EOF

# Create the service
echo "Creating service with LoadBalancer type for Cold Email Generator..."
cat <<EOF | $KUBECTL_CMD apply -f -
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
EOF

# Wait for the deployment to roll out
echo "Waiting for Cold Email Generator deployment to finish..."
$KUBECTL_CMD rollout status deployment/${APP_NAME}-generator -n $NAMESPACE --timeout=300s

# Verify the pods are running and ready
echo "Verifying pod status..."
POD_NAME=$($KUBECTL_CMD get pods -n $NAMESPACE -l app=${APP_NAME}-generator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ ! -z "$POD_NAME" ]; then
  echo "✅ Pod created: $POD_NAME"
  
  # Check if pod is running
  POD_STATUS=$($KUBECTL_CMD get pod $POD_NAME -n $NAMESPACE -o jsonpath='{.status.phase}')
  if [ "$POD_STATUS" == "Running" ]; then
    echo "✅ Pod is running"
    
    # Show pod logs for debugging
    echo "Recent pod logs:"
    $KUBECTL_CMD logs $POD_NAME -n $NAMESPACE --tail=20
  else
    echo "⚠️ Pod is not running yet (status: $POD_STATUS), waiting..."
    $KUBECTL_CMD describe pod $POD_NAME -n $NAMESPACE
  fi
else
  echo "❌ No pods found for Cold Email Generator!"
  $KUBECTL_CMD get pods -n $NAMESPACE
fi

# Wait for the LoadBalancer to be provisioned and save connection info
echo "Waiting for LoadBalancer to be provisioned (this may take a few minutes)..."
MAX_ATTEMPTS=30
ATTEMPT=0
while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
  ATTEMPT=$((ATTEMPT+1))
  echo "Checking LoadBalancer status (attempt $ATTEMPT/$MAX_ATTEMPTS)..."
  
  LB_HOSTNAME=$($KUBECTL_CMD get svc ${APP_NAME}-service -n $NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
  LB_IP=$($KUBECTL_CMD get svc ${APP_NAME}-service -n $NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  
  if [ ! -z "$LB_HOSTNAME" ]; then
    echo "✅ LoadBalancer hostname provisioned: $LB_HOSTNAME"
    MAIN_URL="http://$LB_HOSTNAME"
    break
  elif [ ! -z "$LB_IP" ]; then
    echo "✅ LoadBalancer IP provisioned: $LB_IP"
    MAIN_URL="http://$LB_IP"
    break
  else
    echo "LoadBalancer still provisioning... (attempt $ATTEMPT/$MAX_ATTEMPTS)"
    $KUBECTL_CMD describe svc ${APP_NAME}-service -n $NAMESPACE | grep -E "Type|LoadBalancer|Port"
    
    if [ $ATTEMPT -lt $MAX_ATTEMPTS ]; then
      echo "Waiting 10 seconds before next check..."
      sleep 10
    fi
  fi
done

if [ -z "$MAIN_URL" ]; then
  echo "⚠️ LoadBalancer not fully provisioned within the timeout period"
  echo "This is normal for AWS and may take 3-5 minutes to complete"
  echo "Current LoadBalancer status:"
  $KUBECTL_CMD describe svc ${APP_NAME}-service -n $NAMESPACE
fi

# Get NodePort as fallback access method
NODE_PORT=$($KUBECTL_CMD get svc ${APP_NAME}-service -n $NAMESPACE -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
FALLBACK_URL="http://$PUBLIC_IP:$NODE_PORT"

# Save access information for other scripts to use
echo "Saving access information to ~/app_access.txt..."
cat <<EOF > ~/app_access.txt
MAIN_URL="${MAIN_URL:-pending}"
FALLBACK_URL="${FALLBACK_URL}"
LB_HOSTNAME="${LB_HOSTNAME}"
LB_IP="${LB_IP}"
NODE_PORT="${NODE_PORT}"
PUBLIC_IP="${PUBLIC_IP}"
APP_NAME="${APP_NAME}"
NAMESPACE="${NAMESPACE}"
EOF

# Update security group for NodePort access if needed
if [ ! -z "$NODE_PORT" ]; then
  echo "Ensuring security group allows access to NodePort $NODE_PORT..."
  INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
  SECURITY_GROUP=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --query "Reservations[0].Instances[0].SecurityGroups[0].GroupId" --output text)
  
  if [ ! -z "$SECURITY_GROUP" ]; then
    # Add HTTP port 80 rule
    echo "Ensuring HTTP port 80 is open..."
    aws ec2 authorize-security-group-ingress \
      --group-id $SECURITY_GROUP \
      --protocol tcp \
      --port 80 \
      --cidr 0.0.0.0/0 2>/dev/null || echo "HTTP port rule already exists"
      
    # Add NodePort rule
    echo "Ensuring NodePort $NODE_PORT is open..."
    aws ec2 authorize-security-group-ingress \
      --group-id $SECURITY_GROUP \
      --protocol tcp \
      --port $NODE_PORT \
      --cidr 0.0.0.0/0 2>/dev/null || echo "NodePort rule already exists"
  fi
fi

# Test the service access
echo "Testing service access..."
if [ ! -z "$MAIN_URL" ] && [ "$MAIN_URL" != "pending" ]; then
  echo "Testing access via LoadBalancer: $MAIN_URL"
  curl -s --connect-timeout 5 -I $MAIN_URL || echo "LoadBalancer not yet accessible, this is normal"
fi

if [ ! -z "$FALLBACK_URL" ]; then
  echo "Testing access via NodePort: $FALLBACK_URL"
  curl -s --connect-timeout 5 -I $FALLBACK_URL || echo "NodePort not yet accessible, checking security groups"
fi

# Display access URLs
echo ""
echo "==== Cold Email Generator Deployed Successfully ===="
echo "🚀 Your application has been deployed!"
echo ""
echo "ℹ️ Access URLs:"
if [ ! -z "$MAIN_URL" ] && [ "$MAIN_URL" != "pending" ]; then
  echo "📌 Main URL (LoadBalancer): $MAIN_URL"
else
  echo "📌 Main URL: LoadBalancer still provisioning (may take 3-5 minutes)"
  echo "   Check status with: k3s kubectl describe svc ${APP_NAME}-service -n $NAMESPACE"
fi

if [ ! -z "$FALLBACK_URL" ]; then
  echo "📌 Fallback URL (NodePort): $FALLBACK_URL"
fi

echo ""
echo "⚠️ NOTE: AWS LoadBalancer typically takes 3-5 minutes to become fully accessible"
echo "   If the Main URL doesn't work immediately, try again in a few minutes"
echo "   or use the Fallback URL in the meantime."
echo ""
echo "✅ To verify application access, run: ./verify-access.sh"
echo "==================================================" 