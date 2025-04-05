#!/bin/bash
# Kubernetes deployment script for cold email generator application

# Exit on error, but enable trapping
set -e

echo "====== Deploying Cold Email Generator to Kubernetes ======"

# Function to retry commands
retry_command() {
  local CMD="$1"
  local MAX_ATTEMPTS="$2"
  local SLEEP_TIME="${3:-10}"
  local ATTEMPT=1
  
  echo "Running command with up to $MAX_ATTEMPTS attempts: $CMD"
  
  while [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
    echo "Attempt $ATTEMPT of $MAX_ATTEMPTS..."
    
    if eval "$CMD"; then
      echo "Command succeeded on attempt $ATTEMPT"
      return 0
    else
      echo "Command failed on attempt $ATTEMPT"
      
      if [ $ATTEMPT -lt $MAX_ATTEMPTS ]; then
        echo "Waiting $SLEEP_TIME seconds before next attempt..."
        sleep $SLEEP_TIME
      fi
    fi
    
    ATTEMPT=$((ATTEMPT + 1))
  done
  
  echo "Command failed after $MAX_ATTEMPTS attempts"
  return 1
}

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
  # Set a default value
  LB_DNS="pending.elb.amazonaws.com"
fi

# Check if kubectl is functioning
echo "Verifying kubectl access..."
if ! kubectl get nodes &>/dev/null; then
  echo "kubectl cannot access the cluster. Checking configuration..."
  
  # Try to fix kubectl configuration
  if [ -f "/etc/kubernetes/admin.conf" ]; then
    echo "Found admin.conf, setting KUBECONFIG..."
    export KUBECONFIG=/etc/kubernetes/admin.conf
    
    if ! kubectl get nodes &>/dev/null; then
      echo "Still cannot access cluster. Trying to recreate kubeconfig..."
      mkdir -p $HOME/.kube
      sudo cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
      sudo chown $(id -u):$(id -g) $HOME/.kube/config
    fi
  else
    echo "ERROR: Cannot access Kubernetes cluster and admin.conf not found."
    echo "Kubernetes may not be properly initialized."
    exit 1
  fi
fi

echo "Using Docker image: $DOCKER_IMAGE"
echo "Using Load Balancer DNS: $LB_DNS"

# Create k8s directory if it doesn't exist
mkdir -p $HOME/k8s

# Check if namespace exists, create if needed
kubectl get namespace cold-email &>/dev/null || kubectl create namespace cold-email

# Check if Groq API key is set, create Kubernetes secret if needed
if [ ! -z "$GROQ_API_KEY" ]; then
  echo "Creating secret for Groq API key..."
  kubectl create secret generic app-secrets \
    --namespace=cold-email \
    --from-literal=GROQ_API_KEY=$GROQ_API_KEY \
    --dry-run=client -o yaml | kubectl apply -f -
else
  echo "WARNING: GROQ_API_KEY is not set, application may have limited functionality"
fi

# Check if deployment template exists, create a simple one if not
if [ ! -f "$HOME/k8s/deployment.yaml" ]; then
  echo "Deployment template not found, creating a default one..."
  cat > $HOME/k8s/deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cold-email-generator
  namespace: cold-email
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cold-email-generator
  template:
    metadata:
      labels:
        app: cold-email-generator
    spec:
      containers:
      - name: app
        image: ${DOCKER_IMAGE}
        ports:
        - containerPort: 8501
        env:
        - name: LB_DNS
          value: "${LB_DNS}"
        - name: GROQ_API_KEY
          valueFrom:
            secretKeyRef:
              name: app-secrets
              key: GROQ_API_KEY
              optional: true
        resources:
          limits:
            memory: "1Gi"
            cpu: "1000m"
        readinessProbe:
          httpGet:
            path: /_stcore/health
            port: 8501
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
EOF
fi

# Check if service template exists, create if needed
if [ ! -f "$HOME/k8s/service.yaml" ]; then
  echo "Service template not found, creating a default one..."
  cat > $HOME/k8s/service.yaml << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: cold-email-service
  namespace: cold-email
spec:
  selector:
    app: cold-email-generator
  ports:
  - port: 80
    targetPort: 8501
  type: NodePort
EOF
fi

# Check if ingress template exists, create if needed
if [ ! -f "$HOME/k8s/ingress.yaml" ]; then
  echo "Ingress template not found, creating a default one..."
  cat > $HOME/k8s/ingress.yaml << 'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: cold-email-ingress
  namespace: cold-email
  annotations:
    kubernetes.io/ingress.class: "nginx"
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
spec:
  rules:
  - http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: cold-email-service
            port:
              number: 80
EOF
fi

# Apply deployment with environment variable substitution
echo "Deploying the application..."
cd $HOME/k8s
envsubst < deployment.yaml > deployment-rendered.yaml

# Apply with retries
echo "Applying deployment..."
retry_command "kubectl apply -f deployment-rendered.yaml" 3 15

# Apply service with retries
echo "Creating service..."
retry_command "kubectl apply -f service.yaml" 3 15

# Try to apply ingress if it exists
if [ -f "$HOME/k8s/ingress.yaml" ]; then
  echo "Creating ingress..."
  retry_command "kubectl apply -f ingress.yaml" 3 15
else
  echo "No ingress manifest found, skipping ingress creation"
fi

# Set a trap for interruption
trap 'echo "Deployment interrupted. Current state may be incomplete."' INT

# Wait for deployment to be ready with extended timeout - but run in background to prevent SSH timeout
echo "Waiting for deployment to be ready (may take several minutes)..."
echo "Note: Running in background to prevent SSH timeout..."
nohup kubectl rollout status deployment/cold-email-generator -n cold-email --timeout=300s > /tmp/deployment-status.log 2>&1 &

# Give some time for initial pod creation
sleep 30

echo "Checking initial deployment status (pods may still be starting):"
kubectl get pods -n cold-email || echo "No pods found yet, they may still be being created"
kubectl get deployments -n cold-email

echo "Note: The deployment continues in the background even after this script finishes."
echo "You can check the status later with: kubectl get pods -n cold-email"

# Get service details with retries
echo "Getting service details..."
NODE_PORT=""
for i in {1..5}; do
  NODE_PORT=$(kubectl get svc -n cold-email cold-email-service -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)
  if [ ! -z "$NODE_PORT" ]; then
    break
  fi
  echo "Waiting for NodePort to be assigned... (attempt $i/5)"
  sleep 10
done

# Get node IP with fallback
NODE_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "unknown")
if [ "$NODE_IP" == "unknown" ]; then
  echo "Could not get instance public IP from metadata. Trying alternative method..."
  NODE_IP=$(hostname -I | awk '{print $1}')
fi

echo ""
echo "====== Deployment Summary ======"
echo "Application deployment attempted!"
echo ""
echo "Application should be accessible at:"
echo "- Load Balancer URL: http://${LB_DNS}"
if [ ! -z "$NODE_PORT" ] && [ "$NODE_IP" != "unknown" ]; then
  echo "- Node Port URL: http://${NODE_IP}:${NODE_PORT}"
fi
echo ""
echo "Kubernetes resources:"
echo "- Namespace: cold-email"
echo "- Deployment: cold-email-generator"
echo "- Service: cold-email-service"
echo "- Ingress: cold-email-ingress"
echo ""

# Check and display deployments
echo "Deployment status:"
kubectl get deployments -n cold-email || echo "Could not retrieve deployments"

# Check pod status and retry if no pods found
echo "Pod status:"
PODS=$(kubectl get pods -n cold-email 2>/dev/null)
if [ -z "$PODS" ]; then
  echo "No pods found. Waiting and trying again..."
  sleep 30
  kubectl get pods -n cold-email || echo "Still no pods found."
else
  echo "$PODS"
fi

# Show pod details for troubleshooting
echo ""
echo "Pod details (for troubleshooting):"
FIRST_POD=$(kubectl get pods -n cold-email -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ ! -z "$FIRST_POD" ]; then
  kubectl describe pod $FIRST_POD -n cold-email || echo "Could not get pod details"
else
  echo "No pods found to describe"
fi

# Show service details
echo ""
echo "Service details:"
kubectl describe service cold-email-service -n cold-email || echo "Could not retrieve service details"

echo ""
echo "Deployment process completed. The application should be available shortly."
echo "You can monitor the deployment status by running: kubectl get pods -n cold-email" 