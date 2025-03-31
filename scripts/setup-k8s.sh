#!/bin/bash
set -e

# Install Docker if not already installed
if ! command -v docker &> /dev/null; then
    echo "Installing Docker..."
    sudo apt-get update
    sudo apt-get install -y docker.io
    sudo systemctl enable docker
    sudo systemctl start docker
fi

# Install Kubernetes components
echo "Installing Kubernetes components..."
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl
# Set up repository properly with fallback methods
if [ ! -d "/etc/apt/keyrings" ]; then
    sudo mkdir -p /etc/apt/keyrings
fi
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg || \
    (echo "Failed to add k8s GPG key, trying alternative method"; \
     curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -)

# Try to add the repository with fallback
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list || \
    echo "deb https://apt.kubernetes.io/ kubernetes-xenial main" | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update || (echo "Failed to update apt, retrying with different method" && \
    sudo apt-get update --fix-missing)
sudo apt-get install -y kubelet kubeadm kubectl || \
    (echo "Failed to install kubeadm, trying older version" && \
     sudo apt-get install -y kubelet=1.27.0-00 kubeadm=1.27.0-00 kubectl=1.27.0-00)
sudo apt-mark hold kubelet kubeadm kubectl

# Setup for Kubernetes
echo "Setting up Kubernetes prerequisites..."
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay || echo "Failed to load overlay module - continuing anyway"
sudo modprobe br_netfilter || echo "Failed to load br_netfilter module - continuing anyway"

# sysctl params required by setup, params persist across reboots
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

# Apply sysctl params without reboot
sudo sysctl --system

# Disable swap
sudo swapoff -a
sudo sed -i '/swap/d' /etc/fstab

# Initialize Kubernetes - try with simplified options if it fails
echo "Initializing Kubernetes cluster..."
sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --ignore-preflight-errors=NumCPU,Mem,Swap || \
    (echo "Failed to initialize Kubernetes with CNI options, trying simplified approach" && \
     sudo kubeadm init --ignore-preflight-errors=all)

# Set up kubectl for the ubuntu user
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Ensure we can reach the Kubernetes API
echo "Waiting for Kubernetes API to become available..."
ATTEMPTS=0
MAX_ATTEMPTS=30
until kubectl get nodes || [ $ATTEMPTS -eq $MAX_ATTEMPTS ]; do
    echo "Waiting for Kubernetes API to respond (attempt $ATTEMPTS/$MAX_ATTEMPTS)..."
    ATTEMPTS=$((ATTEMPTS+1))
    sleep 10
done

if [ $ATTEMPTS -eq $MAX_ATTEMPTS ]; then
    echo "Kubernetes API did not become available in time. Continuing anyway as it might still be initializing..."
else
    echo "Kubernetes API is now available!"
fi

# Install Flannel network plugin
echo "Installing Flannel CNI plugin..."
kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml || \
    echo "Failed to install Flannel - continuing anyway, please install CNI manually"

# Wait for core DNS to be ready
echo "Waiting for CoreDNS to be ready..."
ATTEMPTS=0
MAX_ATTEMPTS=30
until kubectl -n kube-system get pods -l k8s-app=kube-dns -o jsonpath='{.items[*].status.phase}' | grep Running || [ $ATTEMPTS -eq $MAX_ATTEMPTS ]; do
    echo "Waiting for CoreDNS to be ready (attempt $ATTEMPTS/$MAX_ATTEMPTS)..."
    ATTEMPTS=$((ATTEMPTS+1))
    sleep 10
done

# Allow scheduling pods on the master node (since we're using a single node for free tier)
echo "Allowing workloads on control-plane node..."
kubectl taint nodes --all node-role.kubernetes.io/control-plane- || echo "No control-plane taint found - continuing"
kubectl taint nodes --all node-role.kubernetes.io/master- || echo "No master taint found - continuing"

# Create namespace
echo "Creating Kubernetes namespace..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: cold-email
EOF

# Create secret
echo "Creating secret for GROQ API key..."
kubectl create secret generic app-secrets \
  --namespace=cold-email \
  --from-literal=GROQ_API_KEY=$GROQ_API_KEY \
  --dry-run=client -o yaml | kubectl apply -f -

# Install nginx ingress controller
echo "Installing NGINX Ingress Controller..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.2/deploy/static/provider/cloud/deploy.yaml || \
    echo "Failed to install NGINX Ingress Controller - continuing anyway, please install manually"

# Wait for ingress controller to be ready - but don't fail if it takes too long
echo "Waiting for ingress controller to be ready..."
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s || echo "Ingress controller pods still not ready, proceeding anyway"

echo "Kubernetes setup completed successfully!"
echo "You can now deploy applications to your Kubernetes cluster."
kubectl get nodes
echo "----------------------------------------------"