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

# Configure containerd for Kubernetes
echo "Configuring containerd for Kubernetes..."
cat <<EOF | sudo tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

# Setup required sysctl params, these persist across reboots
cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

# Apply sysctl params without reboot
sudo sysctl --system

# Configure containerd
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

# Restart containerd
sudo systemctl restart containerd
sudo systemctl enable containerd

# Check if Kubernetes is in a broken state
K8S_RESET_NEEDED=false
if [ -f "/etc/kubernetes/admin.conf" ]; then
  echo "Checking if existing Kubernetes cluster is functional..."
  if ! sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes &>/dev/null; then
    echo "Kubernetes appears to be in a broken state, will reset and reinitialize"
    K8S_RESET_NEEDED=true
  else
    echo "Kubernetes appears to be already initialized and working. Skipping initialization."
  fi
fi

# Reset Kubernetes if needed or not initialized
if [ "$K8S_RESET_NEEDED" = true ] || [ ! -f "/etc/kubernetes/admin.conf" ]; then
  # If we need to reset, do it
  if [ "$K8S_RESET_NEEDED" = true ]; then
    echo "Resetting Kubernetes..."
    sudo kubeadm reset -f
    
    # Remove CNI configurations
    sudo rm -rf /etc/cni/net.d/*
    
    # Reset iptables
    sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F && sudo iptables -X
  fi

  # Initialize Kubernetes with pod network CIDR for Flannel
  echo "Initializing Kubernetes cluster..."
  
  # Make sure swap is off (Kubernetes requirement)
  echo "Ensuring swap is disabled..."
  sudo swapoff -a
  sudo sed -i '/swap/d' /etc/fstab
  
  # Check if kubeadm is installed
  if ! command -v kubeadm &> /dev/null; then
    echo "kubeadm not found. Installing Kubernetes components..."
    sudo apt-get update && sudo apt-get install -y apt-transport-https ca-certificates curl
    
    # Update to use the new Kubernetes repository for Ubuntu 22.04
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
    
    sudo apt-get update
    sudo apt-get install -y kubelet kubeadm kubectl
    sudo apt-mark hold kubelet kubeadm kubectl
  fi
  
  # Pull images before initializing
  echo "Pulling Kubernetes images..."
  sudo kubeadm config images pull
  
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
  if ! kubectl get nodes; then
    echo "ERROR: Could not configure kubectl. Continuing with setup..."
  fi
fi

# Install Flannel CNI network plugin with retries
echo "Installing Flannel CNI network plugin..."
retry_command "kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml" 3 15

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
echo "Kubernetes status:"
kubectl get nodes || echo "Unable to get node status"
kubectl -n kube-system get pods || echo "Unable to get system pods"
echo "Ready to deploy the application." 