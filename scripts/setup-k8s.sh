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

# Start Docker immediately and configure it
echo "Configuring Docker..."
cat <<EOF | sudo tee /etc/docker/daemon.json
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2"
}
EOF

sudo mkdir -p /etc/systemd/system/docker.service.d
sudo systemctl daemon-reload
sudo systemctl restart docker
sudo systemctl enable docker

# Setup networking prerequisites
echo "Setting up networking prerequisites..."
sudo modprobe br_netfilter
sudo modprobe overlay

cat <<EOF | sudo tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF

cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

sudo sysctl --system

# Configure containerd
echo "Configuring containerd..."
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd

# Reset any existing Kubernetes setup
echo "Resetting any existing Kubernetes setup..."
sudo kubeadm reset -f || true
sudo rm -rf /etc/kubernetes /var/lib/kubelet /var/lib/etcd $HOME/.kube /var/lib/cni/
sudo ip link delete cni0 || true
sudo ip link delete flannel.1 || true
sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F && sudo iptables -X

# Get the primary IP address
PRIMARY_IP=$(ip route get 1.1.1.1 | awk '{print $7; exit}')
echo "Using primary IP: $PRIMARY_IP"

# Create kubeadm config with additional settings
cat <<EOF > kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "${PRIMARY_IP}"
  bindPort: 6443
nodeRegistration:
  criSocket: "unix:///var/run/containerd/containerd.sock"
  taints: []
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
networking:
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/12"
kubernetesVersion: "v1.28.0"
apiServer:
  extraArgs:
    enable-admission-plugins: NodeRestriction
    allow-privileged: "true"
  timeoutForControlPlane: 4m0s
controllerManager:
  extraArgs:
    node-cidr-mask-size: "24"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
failSwapOn: false
EOF

# Initialize Kubernetes with better error handling
echo "Initializing Kubernetes cluster..."
if ! sudo kubeadm init --config=kubeadm-config.yaml --ignore-preflight-errors=all --v=5; then
    echo "First initialization attempt failed, checking logs..."
    sudo journalctl -xeu kubelet
    echo "Trying alternative initialization..."
    sudo kubeadm init --ignore-preflight-errors=all --pod-network-cidr=10.244.0.0/16 --apiserver-advertise-address="${PRIMARY_IP}" --v=5
fi

# Set up kubectl configuration with retries
echo "Setting up kubectl configuration..."
mkdir -p $HOME/.kube
for i in {1..5}; do
    if sudo cp -f /etc/kubernetes/admin.conf $HOME/.kube/config; then
        sudo chown $(id -u):$(id -g) $HOME/.kube/config
        break
    fi
    echo "Attempt $i: Waiting for admin.conf to be available..."
    sleep 5
done

# Export and persist KUBECONFIG
export KUBECONFIG=$HOME/.kube/config
echo "export KUBECONFIG=$HOME/.kube/config" | sudo tee -a $HOME/.bashrc
echo "export KUBECONFIG=$HOME/.kube/config" | sudo tee -a /etc/environment

# Wait for API server with enhanced diagnostics
echo "Waiting for API server to become available..."
ATTEMPTS=0
MAX_ATTEMPTS=30
until curl -k https://${PRIMARY_IP}:6443/healthz >/dev/null 2>&1 || [ $ATTEMPTS -eq $MAX_ATTEMPTS ]; do
    echo "Attempt $((ATTEMPTS+1))/$MAX_ATTEMPTS: API server not ready, checking status..."
    
    # Enhanced diagnostics
    echo "Kubelet status and logs:"
    sudo systemctl status kubelet || true
    sudo journalctl -xeu kubelet --no-pager | tail -n 50 || true
    
    echo "API server container status:"
    sudo crictl ps -a | grep kube-apiserver || true
    
    echo "API server logs:"
    API_CONTAINER=$(sudo crictl ps -a | grep kube-apiserver | awk '{print $1}')
    if [ ! -z "$API_CONTAINER" ]; then
        sudo crictl logs $API_CONTAINER | tail -n 50 || true
    fi
    
    ATTEMPTS=$((ATTEMPTS+1))
    sleep 10
done

# Install Flannel with enhanced error handling
echo "Installing Flannel CNI plugin..."
if ! kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml; then
    echo "Failed to install Flannel directly, trying alternative method..."
    curl -sSL https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml | sed "s/10.244.0.0/10.244.0.0/g" | kubectl apply -f -
fi

# Wait for node to become ready
echo "Waiting for node to become ready..."
ATTEMPTS=0
MAX_ATTEMPTS=30
until kubectl get nodes | grep -w "Ready" || [ $ATTEMPTS -eq $MAX_ATTEMPTS ]; do
    echo "Attempt $((ATTEMPTS+1))/$MAX_ATTEMPTS: Node not ready..."
    kubectl get nodes
    ATTEMPTS=$((ATTEMPTS+1))
    sleep 10
done

# Create namespace and secret with enhanced error handling
echo "Creating namespace and secret..."
if ! kubectl create namespace cold-email 2>/dev/null; then
    echo "Namespace already exists or creation failed, trying to apply..."
    kubectl create namespace cold-email --dry-run=client -o yaml | kubectl apply -f -
fi

if ! kubectl -n cold-email create secret generic app-secrets --from-literal=GROQ_API_KEY=$GROQ_API_KEY 2>/dev/null; then
    echo "Secret already exists or creation failed, trying to apply..."
    kubectl create secret generic app-secrets \
        --namespace=cold-email \
        --from-literal=GROQ_API_KEY=$GROQ_API_KEY \
        --dry-run=client -o yaml | kubectl apply -f -
fi

# Final status check
echo "Kubernetes setup completed! Checking final status..."
kubectl get nodes -o wide
kubectl get pods --all-namespaces
echo "----------------------------------------------"