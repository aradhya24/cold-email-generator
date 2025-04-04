#!/bin/bash
# Kubernetes setup script for cold email generator application

# Exit on error, but enable error trapping
set -e

echo "====== Kubernetes Setup for Cold Email Generator ======"

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

# Check if Kubernetes is already initialized
if [ -f "/etc/kubernetes/admin.conf" ]; then
  echo "Kubernetes appears to be already initialized. Skipping initialization."
else
  # Initialize Kubernetes with pod network CIDR for Flannel
  echo "Initializing Kubernetes cluster..."
  
  # Make sure swap is off (Kubernetes requirement)
  echo "Ensuring swap is disabled..."
  sudo swapoff -a
  
  # Check if kubeadm is installed
  if ! command -v kubeadm &> /dev/null; then
    echo "kubeadm not found. Installing Kubernetes components..."
    sudo apt-get update && sudo apt-get install -y apt-transport-https ca-certificates curl
    curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
    echo "deb https://apt.kubernetes.io/ kubernetes-xenial main" | sudo tee /etc/apt/sources.list.d/kubernetes.list
    sudo apt-get update
    sudo apt-get install -y kubelet kubeadm kubectl
    sudo apt-mark hold kubelet kubeadm kubectl
  fi
  
  # Try to initialize kubeadm with retries
  if ! retry_command "sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --ignore-preflight-errors=NumCPU,Mem,Swap" 3 30; then
    echo "Failed to initialize Kubernetes after multiple attempts. Trying again with more permissive flags..."
    sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --ignore-preflight-errors=all
  fi
fi

# Set up kubectl for the ubuntu user
echo "Setting up kubectl configuration..."
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config || {
  echo "Failed to copy admin.conf. Trying again with force..."
  sudo cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
}
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Verify kubectl works
echo "Verifying kubectl configuration..."
if ! kubectl get nodes; then
  echo "kubectl configuration failed. Retrying with alternative approach..."
  export KUBECONFIG=/etc/kubernetes/admin.conf
  kubectl get nodes
fi

# Install Flannel CNI network plugin with retries
echo "Installing Flannel CNI network plugin..."
retry_command "kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml" 3 15

# Allow scheduling pods on the master node (for single-node free tier setup)
echo "Allowing pods to be scheduled on the master node..."
kubectl taint nodes --all node-role.kubernetes.io/master- || true
kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true

# Make sure the node is ready
echo "Waiting for node to be ready..."
READY_TIMEOUT=300  # 5 minutes
START_TIME=$(date +%s)

while [ $(($(date +%s) - START_TIME)) -lt $READY_TIMEOUT ]; do
  NODE_STATUS=$(kubectl get nodes -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
  
  if [ "$NODE_STATUS" == "True" ]; then
    echo "Node is ready!"
    break
  else
    echo "Node not ready yet. Status: $NODE_STATUS. Waiting 20 seconds..."
    sleep 20
  fi
done

if [ "$NODE_STATUS" != "True" ]; then
  echo "Warning: Node did not reach ready state within timeout. Continuing anyway..."
fi

# Create the application namespace
echo "Creating application namespace..."
kubectl create namespace cold-email 2>/dev/null || echo "Namespace cold-email already exists"

# Create a secret for the Groq API key
if [ -n "$GROQ_API_KEY" ]; then
  echo "Creating secret for Groq API key..."
  kubectl create secret generic app-secrets \
    --namespace=cold-email \
    --from-literal=GROQ_API_KEY=$GROQ_API_KEY \
    --dry-run=client -o yaml | kubectl apply -f -
else
  echo "GROQ_API_KEY environment variable not set. Please set it and create the secret manually."
fi

# Install NGINX Ingress Controller with retries
echo "Installing NGINX Ingress Controller..."
retry_command "kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.2/deploy/static/provider/cloud/deploy.yaml" 3 20

# Wait for ingress controller to be ready with extended timeout
echo "Waiting for Ingress controller to be ready (extended timeout)..."
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=300s || echo "Ingress controller pods not ready within timeout, but proceeding anyway"

# Create Kubernetes manifests directory
echo "Creating Kubernetes manifests directory..."
mkdir -p $HOME/k8s

# Create deployment manifest
echo "Creating deployment manifest..."
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
        - name: GROQ_API_KEY
          valueFrom:
            secretKeyRef:
              name: app-secrets
              key: GROQ_API_KEY
        - name: USER_AGENT
          value: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
        # Add load balancer DNS as environment variable
        - name: LB_DNS
          value: "${LB_DNS}"
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
          failureThreshold: 6
        livenessProbe:
          httpGet:
            path: /_stcore/health
            port: 8501
          initialDelaySeconds: 60
          periodSeconds: 15
          timeoutSeconds: 5
          failureThreshold: 3
EOF

# Create service manifest
echo "Creating service manifest..."
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
    name: http
  type: NodePort
EOF

# Create ingress manifest
echo "Creating ingress manifest..."
cat > $HOME/k8s/ingress.yaml << 'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: cold-email-ingress
  namespace: cold-email
  annotations:
    kubernetes.io/ingress.class: "nginx"
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
    nginx.ingress.kubernetes.io/connection-proxy-header: "keep-alive"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
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

echo "Kubernetes setup completed successfully!"
echo "System information:"
uname -a
free -h
df -h
kubectl get nodes
kubectl -n kube-system get pods
echo "Ready to deploy the application." 