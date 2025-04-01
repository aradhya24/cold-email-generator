#!/bin/bash
set -e

# Function to wait for apt locks to be released
wait_for_apt() {
    echo "Checking if apt is locked..."
    WAIT_TIME=0
    MAX_WAIT_TIME=300  # 5 minutes maximum wait

    while (sudo lsof /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || sudo lsof /var/lib/apt/lists/lock >/dev/null 2>&1 || sudo lsof /var/lib/dpkg/lock >/dev/null 2>&1); do
        echo "APT is still locked by another process. Waiting... (${WAIT_TIME}s elapsed)"
        
        # Show the processes that are holding the locks
        echo "Processes holding apt locks:"
        sudo lsof /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/lib/dpkg/lock 2>/dev/null || true
        
        # Check if we've waited too long
        if [ "$WAIT_TIME" -gt "$MAX_WAIT_TIME" ]; then
            echo "Waited too long for APT locks to be released. Attempting to kill apt processes..."
            sudo pkill -9 apt || true
            sudo pkill -9 apt-get || true
            sudo pkill -9 dpkg || true
            sleep 5
            break
        fi
        
        sleep 5
        WAIT_TIME=$((WAIT_TIME + 5))
    done
    
    echo "APT locks released, proceeding with package operations..."
}

# Install Docker and Kubernetes components in parallel where possible
echo "Installing Docker and Kubernetes components..."
wait_for_apt
sudo apt-get update
wait_for_apt
sudo apt-get install -y docker.io apt-transport-https ca-certificates curl

# Start Docker immediately
sudo systemctl enable docker
sudo systemctl start docker

# Clean up any existing Kubernetes repository configurations
echo "Cleaning up any existing Kubernetes repository configurations..."
sudo rm -f /etc/apt/sources.list.d/kubernetes.list /etc/apt/sources.list.d/kubectl.list /etc/apt/sources.list.d/kubernetes-xenial.list /etc/apt/keyrings/kubernetes-apt-keyring.gpg
sudo apt-key del BA07F4FB 2>/dev/null || true

# Remove any references to kubernetes-xenial from all apt sources
echo "Removing any references to kubernetes-xenial..."
sudo find /etc/apt/sources.list.d/ -type f -exec sed -i '/kubernetes-xenial/d' {} +
sudo find /etc/apt/sources.list.d/ -type f -name "*kubernetes*.list" -delete

# Clean apt cache and remove old lists
echo "Cleaning apt cache and removing old lists..."
wait_for_apt
sudo apt-get clean
sudo rm -rf /var/lib/apt/lists/*

# Add Kubernetes repository key
echo "Adding Kubernetes repository key..."
curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-archive-keyring.gpg

# Add Kubernetes repository
echo "Adding Kubernetes repository..."
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main" | sudo tee /etc/apt/sources.list.d/kubernetes.list

# Update package lists
echo "Updating package lists..."
wait_for_apt
sudo apt-get update || (echo "Failed to update apt, retrying with different method" && \
    wait_for_apt && sudo apt-get update --fix-missing)

# Install latest available versions of Kubernetes components
echo "Installing Kubernetes components..."
wait_for_apt
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

# Get installed versions for logging
echo "Installed Kubernetes versions:"
kubelet --version
kubeadm version
kubectl version --client

# Setup for Kubernetes (combine all setup steps)
echo "Setting up Kubernetes prerequisites..."
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay br_netfilter || echo "Failed to load modules - continuing anyway"

# sysctl params required by setup
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system
sudo swapoff -a
sudo sed -i '/swap/d' /etc/fstab

# Reset any existing Kubernetes setup
if [ -f "/etc/kubernetes/admin.conf" ]; then
    echo "Found existing Kubernetes setup, resetting..."
    sudo kubeadm reset -f
    sudo rm -rf /etc/kubernetes /var/lib/kubelet /var/lib/etcd $HOME/.kube
fi

# Initialize Kubernetes with proper version and bootstrap token
echo "Initializing Kubernetes cluster..."
KUBE_VERSION=$(kubeadm version -o short)
echo "Using Kubernetes version: $KUBE_VERSION"

sudo kubeadm init --pod-network-cidr=10.244.0.0/16 \
    --kubernetes-version=$KUBE_VERSION \
    --ignore-preflight-errors=all \
    --token-ttl=0 \
    --token=abcdef.0123456789abcdef \
    --apiserver-advertise-address=$(hostname -i) || \
    (echo "First initialization attempt failed, trying alternative approach..." && \
     sudo kubeadm init --ignore-preflight-errors=all \
     --kubernetes-version=$KUBE_VERSION \
     --token-ttl=0 \
     --token=abcdef.0123456789abcdef \
     --apiserver-advertise-address=$(hostname -i))

# Set up kubectl configuration
mkdir -p $HOME/.kube
for i in {1..15}; do
    if [ -f "/etc/kubernetes/admin.conf" ]; then
        sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
        break
    fi
    echo "Waiting for admin.conf to be created (attempt $i/15)..."
    sleep 5
done

# Ensure we have the config file
if [ ! -f "$HOME/.kube/config" ]; then
    echo "Failed to get admin.conf, trying to find alternative config..."
    KUBECONFIG_FILES=$(find /etc -name "kubeconfig" -o -name "*.conf" | grep -i kube 2>/dev/null || true)
    if [ ! -z "$KUBECONFIG_FILES" ]; then
        FIRST_CONFIG=$(echo "$KUBECONFIG_FILES" | head -n 1)
        echo "Using alternative config: $FIRST_CONFIG"
        sudo cp -i "$FIRST_CONFIG" $HOME/.kube/config
    fi
fi

sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Make KUBECONFIG persistent
echo 'export KUBECONFIG=$HOME/.kube/config' | sudo tee /etc/profile.d/kubeconfig.sh
sudo chmod +x /etc/profile.d/kubeconfig.sh
export KUBECONFIG=$HOME/.kube/config

# Wait for Kubernetes API
echo "Waiting for Kubernetes API to become available..."
ATTEMPTS=0
MAX_ATTEMPTS=15
until kubectl get nodes || [ $ATTEMPTS -eq $MAX_ATTEMPTS ]; do
    echo "Waiting for Kubernetes API to respond (attempt $ATTEMPTS/$MAX_ATTEMPTS)..."
    ATTEMPTS=$((ATTEMPTS+1))
    sleep 5
done

if [ $ATTEMPTS -eq $MAX_ATTEMPTS ]; then
    echo "Kubernetes API did not become available in time. Trying to restart kubelet service..."
    sudo systemctl restart kubelet
    sleep 15
    
    if ! kubectl get nodes; then
        echo "Still cannot access API. Using a minimal approach..."
        kubectl create namespace cold-email --dry-run=client -o yaml | kubectl apply -f -
        echo "Created namespace using minimal configuration."
        echo "Skipping advanced Kubernetes setup. You'll need to manually configure networking."
        exit 0
    fi
fi

# Install Flannel network plugin
echo "Installing Flannel CNI plugin..."
kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml || \
    echo "Failed to install Flannel - continuing anyway"

# Wait for core DNS
echo "Waiting for CoreDNS to be ready..."
ATTEMPTS=0
MAX_ATTEMPTS=15
until kubectl -n kube-system get pods -l k8s-app=kube-dns -o jsonpath='{.items[*].status.phase}' | grep Running || [ $ATTEMPTS -eq $MAX_ATTEMPTS ]; do
    echo "Waiting for CoreDNS to be ready (attempt $ATTEMPTS/$MAX_ATTEMPTS)..."
    ATTEMPTS=$((ATTEMPTS+1))
    sleep 5
done

# Allow scheduling pods on the master node
kubectl taint nodes --all node-role.kubernetes.io/control-plane- || echo "No control-plane taint found - continuing"
kubectl taint nodes --all node-role.kubernetes.io/master- || echo "No master taint found - continuing"

# Create namespace and secret in one step
echo "Creating namespace and secret..."
kubectl create namespace cold-email --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic app-secrets \
  --namespace=cold-email \
  --from-literal=GROQ_API_KEY=$GROQ_API_KEY \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Kubernetes setup completed!"
kubectl get nodes || echo "Failed to get nodes but continuing"
echo "----------------------------------------------"