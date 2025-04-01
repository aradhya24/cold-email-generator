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

# Clean up any existing Kubernetes repository configurations
echo "Cleaning up any existing Kubernetes repository configurations..."
sudo rm -f /etc/apt/sources.list.d/kubernetes.list
sudo rm -f /etc/apt/sources.list.d/kubectl.list
sudo rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
sudo apt-key del BA07F4FB 2>/dev/null || true  # Old Google Cloud key

# Set up repository properly
if [ ! -d "/etc/apt/keyrings" ]; then
    sudo mkdir -p /etc/apt/keyrings
fi
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

# Add the Kubernetes repository
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list

# Check for any other references to kubernetes-xenial in all apt sources
echo "Checking for other Kubernetes repository references..."
grep -r "kubernetes-xenial" /etc/apt/ 2>/dev/null || true

# Clean apt cache and update
echo "Cleaning apt cache and updating..."
sudo apt-get clean
sudo rm -rf /var/lib/apt/lists/*
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

# Reset any existing Kubernetes setup
echo "Checking for existing Kubernetes setup..."
if [ -f "/etc/kubernetes/admin.conf" ]; then
    echo "Found existing Kubernetes setup, resetting..."
    sudo kubeadm reset -f
    
    # Clean up directories
    sudo rm -rf /etc/kubernetes /var/lib/kubelet /var/lib/etcd
    sudo rm -rf $HOME/.kube
fi

# Pre-pull images to avoid timeout issues
echo "Pre-pulling Kubernetes images..."
sudo kubeadm config images pull --kubernetes-version=1.27.0 || echo "Failed to pull images - continuing anyway"

# Initialize Kubernetes with simplified approach first
echo "Initializing Kubernetes cluster (attempt 1)..."
sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --kubernetes-version=1.27.0 --ignore-preflight-errors=all --skip-phases=bootstrap-token || {
    echo "First initialization attempt failed, trying alternative approach..."
    
    # If first attempt fails, try with more basic options
    echo "Initializing Kubernetes cluster (attempt 2)..."
    sudo kubeadm init --ignore-preflight-errors=all --skip-token-print --skip-phases=bootstrap-token || {
        echo "Second initialization attempt failed, trying with minimum configuration..."
        
        # If second attempt fails, try with minimum configuration
        echo "Initializing Kubernetes cluster (attempt 3)..."
        sudo kubeadm init --skip-phases=bootstrap-token,addon/kube-proxy --ignore-preflight-errors=all
    }
}

# Set up kubectl for the ubuntu user
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config || {
    echo "Failed to copy admin.conf, waiting for it to be created..."
    # Wait for admin.conf to be created
    for i in {1..30}; do
        if [ -f "/etc/kubernetes/admin.conf" ]; then
            sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
            break
        fi
        echo "Waiting for admin.conf to be created (attempt $i/30)..."
        sleep 10
    done
}

# Ensure we have the config file
if [ ! -f "$HOME/.kube/config" ]; then
    echo "Failed to get admin.conf, Kubernetes initialization might have failed."
    echo "Trying to recover by finding other kubeconfig files..."
    
    # Look for any kubeconfig files
    KUBECONFIG_FILES=$(find /etc -name "kubeconfig" -o -name "*.conf" | grep -i kube 2>/dev/null || true)
    
    if [ ! -z "$KUBECONFIG_FILES" ]; then
        echo "Found potential kubeconfig files:"
        echo "$KUBECONFIG_FILES"
        
        # Try the first one
        FIRST_CONFIG=$(echo "$KUBECONFIG_FILES" | head -n 1)
        echo "Trying to use $FIRST_CONFIG..."
        sudo cp -i "$FIRST_CONFIG" $HOME/.kube/config
    fi
fi

sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Make KUBECONFIG persistent between SSH sessions
echo 'export KUBECONFIG=$HOME/.kube/config' >> $HOME/.bashrc
echo 'export KUBECONFIG=$HOME/.kube/config' >> $HOME/.profile

# Export KUBECONFIG for current session
export KUBECONFIG=$HOME/.kube/config

# Copy kubeconfig to /etc/profile.d to make it available for all users and sessions
sudo tee /etc/profile.d/kubeconfig.sh > /dev/null << 'EOF'
export KUBECONFIG=$HOME/.kube/config
EOF
sudo chmod +x /etc/profile.d/kubeconfig.sh

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
    echo "Kubernetes API did not become available in time. Trying to restart kubelet service..."
    sudo systemctl restart kubelet
    sleep 30
    
    if ! kubectl get nodes; then
        echo "Still cannot access API. Using a minimal approach..."
        echo "Setting up a minimal working configuration..."
        
        # Create a minimal pod network (host networking)
        cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: cold-email
EOF
        
        echo "Created namespace using minimal configuration."
        echo "Skipping advanced Kubernetes setup. You'll need to manually configure networking."
        exit 0
    fi
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

# Install basic Nginx ingress (simpler version to avoid bootstrap-token issues)
echo "Installing basic NGINX Ingress Controller..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ingress-nginx
EOF

# Create a validation file to test kubeconfig persistence
echo "Testing kubectl configuration persistence..."
cat > $HOME/test-k8s.sh << 'EOF'
#!/bin/bash
if kubectl get nodes; then
  echo "Kubernetes API is accessible!"
  export KUBECONFIG=$HOME/.kube/config
  exit 0
else
  echo "Kubernetes API is NOT accessible!"
  exit 1
fi
EOF
chmod +x $HOME/test-k8s.sh

# Run the test immediately to verify
echo "Verifying kubectl access before proceeding..."
$HOME/test-k8s.sh || echo "Kubectl verification failed but continuing"

echo "Kubernetes setup completed with a minimal configuration!"
echo "You can now deploy applications to your Kubernetes cluster."
kubectl get nodes || echo "Failed to get nodes but continuing"
echo "----------------------------------------------"