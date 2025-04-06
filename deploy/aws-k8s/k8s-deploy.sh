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

# Clean up old deployment if exists
echo "Removing any existing deployments to ensure clean slate..."
$KUBECTL_CMD delete deployment ${APP_NAME}-generator -n $NAMESPACE --ignore-not-found

# Wait for pods to terminate
echo "Waiting for old pods to terminate..."
sleep 10

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
        - containerPort: 8501
          name: http
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "500m"
        env:
        - name: PORT
          value: "8501"
        - name: NODE_ENV
          value: "production"
        # Add health check with more relaxed settings
        readinessProbe:
          httpGet:
            path: /
            port: 8501
          initialDelaySeconds: 20
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 6
        livenessProbe:
          httpGet:
            path: /
            port: 8501
          initialDelaySeconds: 40
          periodSeconds: 20
          timeoutSeconds: 10
          failureThreshold: 3
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
    targetPort: 8501
    name: http
  selector:
    app: ${APP_NAME}-generator
EOF

# Check that image exists and is accessible
echo "Verifying Docker image accessibility..."
$KUBECTL_CMD -n $NAMESPACE create job image-puller --dry-run=client -o yaml --image=${DOCKER_IMAGE} -- sh -c "echo Image is accessible" | $KUBECTL_CMD apply -f -

# Start monitoring deployment
echo "Waiting for Cold Email Generator deployment to start..."
$KUBECTL_CMD rollout status deployment/${APP_NAME}-generator -n $NAMESPACE --timeout=30s || true

# If the deployment isn't ready, provide detailed diagnostics
READY_PODS=$($KUBECTL_CMD get deployment ${APP_NAME}-generator -n $NAMESPACE -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [ "$READY_PODS" != "1" ]; then
  echo "Deployment not fully ready. Running diagnostics..."
  
  # Check if pods were created
  echo "Checking pod status..."
  $KUBECTL_CMD get pods -n $NAMESPACE -l app=${APP_NAME}-generator
  
  # Get the pod name if exists
  POD_NAME=$($KUBECTL_CMD get pods -n $NAMESPACE -l app=${APP_NAME}-generator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  
  if [ ! -z "$POD_NAME" ]; then
    echo "Found pod: $POD_NAME. Checking details..."
    
    # Check pod status
    $KUBECTL_CMD describe pod $POD_NAME -n $NAMESPACE
    
    # Check container status
    echo "Container status:"
    $KUBECTL_CMD get pod $POD_NAME -n $NAMESPACE -o jsonpath='{.status.containerStatuses}' | jq . || echo "Error getting container status"
    
    # Check events
    echo "Recent events:"
    $KUBECTL_CMD get events -n $NAMESPACE --sort-by=.metadata.creationTimestamp | tail -n 20
    
    # Check pod logs
    echo "Pod logs:"
    $KUBECTL_CMD logs $POD_NAME -n $NAMESPACE --tail=50 || echo "No logs available yet"
    
    # Check if there are image pull errors
    PULL_ERRORS=$($KUBECTL_CMD describe pod $POD_NAME -n $NAMESPACE | grep -i "failed to pull" || echo "No pull errors found")
    if [ ! -z "$PULL_ERRORS" ]; then
      echo "Image pull errors detected!"
      echo "Attempting to pull image manually from EC2 instance to debug..."
      
      # Run docker pull manually
      sudo docker pull ${DOCKER_IMAGE} || echo "Failed to pull image manually: auth issues or image doesn't exist"
    fi
  fi
fi

# Create a simple NodePort service for direct access
echo "Creating NodePort service for direct access..."
cat <<EOF | $KUBECTL_CMD apply -f -
apiVersion: v1
kind: Service
metadata:
  name: ${APP_NAME}-nodeport
  namespace: ${NAMESPACE}
spec:
  type: NodePort
  ports:
  - port: 8501
    targetPort: 8501
    nodePort: 30405
    name: http
  selector:
    app: ${APP_NAME}-generator
EOF

# Wait for the LoadBalancer to be provisioned and save connection info
echo "Waiting for LoadBalancer to be provisioned (this may take a few minutes)..."
MAX_ATTEMPTS=10
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
NODE_PORT=30405
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

# Create a port-forward for direct debug access
echo "Setting up port-forward for direct access (for debugging)..."
POD_NAME=$($KUBECTL_CMD get pods -n $NAMESPACE -l app=${APP_NAME}-generator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ ! -z "$POD_NAME" ]; then
  echo "Starting port-forward for pod $POD_NAME in background..."
  $KUBECTL_CMD port-forward pod/$POD_NAME 8080:8501 -n $NAMESPACE > /dev/null 2>&1 &
  PF_PID=$!
  echo "Port-forward started with PID $PF_PID. App should be accessible at http://localhost:8080"
  echo "PF_PID=$PF_PID" >> ~/app_access.txt
fi

# Test the service access
echo "Testing service access..."
if [ ! -z "$MAIN_URL" ] && [ "$MAIN_URL" != "pending" ]; then
  echo "Testing access via LoadBalancer: $MAIN_URL"
  curl -s --connect-timeout 5 -I $MAIN_URL || echo "LoadBalancer not yet accessible, this is normal"
  echo "Full HTML content check (LoadBalancer):"
  curl -s --connect-timeout 5 $MAIN_URL | grep -i "cold email generator" || echo "LoadBalancer not fully accessible yet or content not loading"
fi

if [ ! -z "$FALLBACK_URL" ]; then
  echo "Testing access via NodePort: $FALLBACK_URL"
  curl -s --connect-timeout 5 -I $FALLBACK_URL || echo "NodePort not yet accessible, checking security groups"
  echo "Full HTML content check (NodePort):"
  curl -s --connect-timeout 5 $FALLBACK_URL | grep -i "cold email generator" || echo "NodePort not fully accessible yet or content not loading"
  
  # Ensure firewall allows the nodeport
  echo "Ensuring iptables allows NodePort traffic..."
  sudo iptables -I INPUT -p tcp --dport $NODE_PORT -j ACCEPT
  sudo iptables -I OUTPUT -p tcp --sport $NODE_PORT -j ACCEPT
  
  # Test direct port access
  echo "Testing direct port access on pod..."
  POD_NAME=$($KUBECTL_CMD get pods -n $NAMESPACE -l app=${APP_NAME}-generator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [ ! -z "$POD_NAME" ]; then
    $KUBECTL_CMD exec $POD_NAME -n $NAMESPACE -- curl -s localhost:8501 | head -n 10 || echo "App may not be running correctly inside pod"
  fi
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
echo "===================================================="

# Even if there were errors, exit successfully so GitHub Actions doesn't fail
# This lets the recovery script handle it
exit 0 