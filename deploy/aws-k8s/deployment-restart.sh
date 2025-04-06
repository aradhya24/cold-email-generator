#!/bin/bash
# Script to completely restart the Cold Email Generator deployment with updated configuration

set -e

export APP_NAME=${APP_NAME:-cold-email}
export NAMESPACE=${NAMESPACE:-$APP_NAME}
export KUBECTL_CMD="k3s kubectl"
export APP_PORT=8501

echo "===== Completely Restarting Cold Email Generator Deployment ====="

# Backup original configuration
echo "Saving existing app_access.txt if it exists..."
if [ -f ~/app_access.txt ]; then
  cp ~/app_access.txt ~/app_access.txt.bak
  source ~/app_access.txt
  DOCKER_IMAGE=${DOCKER_IMAGE:-ghcr.io/aradhya24/cold-email:latest}
  echo "Using image: $DOCKER_IMAGE"
else
  DOCKER_IMAGE=ghcr.io/aradhya24/cold-email:latest
  echo "No existing configuration found, using default image: $DOCKER_IMAGE"
fi

# Delete all existing resources
echo "Deleting all existing Cold Email Generator resources..."
$KUBECTL_CMD delete deployment ${APP_NAME}-generator -n $NAMESPACE --ignore-not-found
$KUBECTL_CMD delete service ${APP_NAME}-service -n $NAMESPACE --ignore-not-found
$KUBECTL_CMD delete service ${APP_NAME}-nodeport -n $NAMESPACE --ignore-not-found
$KUBECTL_CMD delete pods -l app=${APP_NAME}-generator -n $NAMESPACE --ignore-not-found --force --grace-period=0

# Wait for everything to be cleaned up
echo "Waiting for resources to be fully terminated..."
sleep 10

# Check if namespace exists, create if not
echo "Ensuring namespace $NAMESPACE exists..."
$KUBECTL_CMD create namespace $NAMESPACE --dry-run=client -o yaml | $KUBECTL_CMD apply -f -

# Create secret for Groq API key if provided
if [ ! -z "$GROQ_API_KEY" ]; then
  echo "Re-creating Groq API key secret..."
  $KUBECTL_CMD create secret generic groq-api-key \
    --from-literal=GROQ_API_KEY=$GROQ_API_KEY \
    --namespace $NAMESPACE \
    --dry-run=client -o yaml | $KUBECTL_CMD apply -f -
    
  # Create Streamlit secrets file
  echo "Creating Streamlit secrets file inside container..."
  cat <<EOF | $KUBECTL_CMD apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: streamlit-secrets-config
  namespace: ${NAMESPACE}
data:
  secrets.toml: |
    GROQ_API_KEY = "${GROQ_API_KEY}"
EOF
fi

# Deploy the application with updated port configuration
echo "Deploying Cold Email Generator to Kubernetes with port $APP_PORT..."
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
      volumes:
      - name: streamlit-secrets
        configMap:
          name: streamlit-secrets-config
      containers:
      - name: app
        image: ${DOCKER_IMAGE}
        imagePullPolicy: Always
        ports:
        - containerPort: ${APP_PORT}
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
          value: "${APP_PORT}"
        - name: NODE_ENV
          value: "production"
        - name: GROQ_API_KEY
          valueFrom:
            secretKeyRef:
              name: groq-api-key
              key: GROQ_API_KEY
              optional: true
        volumeMounts:
        - name: streamlit-secrets
          mountPath: /app/.streamlit
        # Add health check with more relaxed settings
        readinessProbe:
          httpGet:
            path: /
            port: ${APP_PORT}
          initialDelaySeconds: 30
          periodSeconds: 15
          timeoutSeconds: 10
          failureThreshold: 8
        livenessProbe:
          httpGet:
            path: /
            port: ${APP_PORT}
          initialDelaySeconds: 60
          periodSeconds: 30
          timeoutSeconds: 15
          failureThreshold: 4
EOF

# Create the LoadBalancer service
echo "Creating LoadBalancer service with port $APP_PORT..."
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
    targetPort: ${APP_PORT}
    name: http
  selector:
    app: ${APP_NAME}-generator
EOF

# Create the NodePort service
echo "Creating NodePort service with port $APP_PORT..."
cat <<EOF | $KUBECTL_CMD apply -f -
apiVersion: v1
kind: Service
metadata:
  name: ${APP_NAME}-nodeport
  namespace: ${NAMESPACE}
spec:
  type: NodePort
  ports:
  - port: ${APP_PORT}
    targetPort: ${APP_PORT}
    nodePort: 30405
    name: http
  selector:
    app: ${APP_NAME}-generator
EOF

# Wait for deployment to become ready
echo "Waiting for deployment to become ready (this may take a few minutes)..."
$KUBECTL_CMD rollout status deployment/${APP_NAME}-generator -n $NAMESPACE --timeout=180s || true

# Check if the deployment is ready
READY_PODS=$($KUBECTL_CMD get deployment ${APP_NAME}-generator -n $NAMESPACE -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
if [ "$READY_PODS" == "1" ]; then
  echo "✅ Deployment is ready!"
else
  echo "⚠️ Deployment is not yet ready. Running diagnostics..."
  POD_NAME=$($KUBECTL_CMD get pods -n $NAMESPACE -l app=${APP_NAME}-generator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [ ! -z "$POD_NAME" ]; then
    echo "Pod details:"
    $KUBECTL_CMD describe pod $POD_NAME -n $NAMESPACE
    echo "Pod logs:"
    $KUBECTL_CMD logs $POD_NAME -n $NAMESPACE --tail=100
  fi
fi

# Get access information
NODE_PORT=30405
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
FALLBACK_URL="http://$PUBLIC_IP:$NODE_PORT"

# Wait for the LoadBalancer to be provisioned
echo "Waiting for LoadBalancer to be provisioned..."
LB_HOSTNAME=$($KUBECTL_CMD get svc ${APP_NAME}-service -n $NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
LB_IP=$($KUBECTL_CMD get svc ${APP_NAME}-service -n $NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)

if [ ! -z "$LB_HOSTNAME" ]; then
  MAIN_URL="http://$LB_HOSTNAME"
  echo "✅ LoadBalancer provisioned: $LB_HOSTNAME"
elif [ ! -z "$LB_IP" ]; then
  MAIN_URL="http://$LB_IP"
  echo "✅ LoadBalancer provisioned: $LB_IP"
else
  echo "⚠️ LoadBalancer still provisioning. This may take a few minutes."
  MAIN_URL="pending"
fi

# Save access information
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
APP_PORT="${APP_PORT}"
DOCKER_IMAGE="${DOCKER_IMAGE}"
EOF

# Ensure security group allows traffic
echo "Ensuring security group rules for port access..."
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

# Ensure iptables allows the nodeport
echo "Configuring iptables for NodePort access..."
sudo iptables -I INPUT -p tcp --dport $NODE_PORT -j ACCEPT
sudo iptables -I OUTPUT -p tcp --sport $NODE_PORT -j ACCEPT

# Display access URLs
echo ""
echo "==== Cold Email Generator Redeployment Summary ===="
echo "🚀 Your application has been redeployed!"
echo ""
echo "ℹ️ Access URLs:"
if [ ! -z "$MAIN_URL" ] && [ "$MAIN_URL" != "pending" ]; then
  echo "📌 Main URL (LoadBalancer): $MAIN_URL"
else
  echo "📌 Main URL: LoadBalancer still provisioning (may take 3-5 minutes)"
  echo "   Check status with: k3s kubectl describe svc ${APP_NAME}-service -n $NAMESPACE"
fi

echo "📌 Fallback URL (NodePort): $FALLBACK_URL"

echo ""
echo "⚠️ NOTE: AWS LoadBalancer typically takes 3-5 minutes to become fully accessible"
echo "   Use the NodePort URL for immediate access"
echo ""
echo "✅ To verify application access, run: ./verify-access.sh"
echo "====================================================" 