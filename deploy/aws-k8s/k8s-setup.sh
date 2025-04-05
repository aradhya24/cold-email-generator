#!/bin/bash
# Kubernetes setup script for EC2 instances

set -e

echo "====== Setting up Kubernetes on EC2 instance ======"

# Clean up any previous Kubernetes installations or repo configurations
sudo rm -f /etc/apt/sources.list.d/kubernetes.list /etc/apt/sources.list.d/k8s.list
sudo rm -f /etc/apt/keyrings/kubernetes-archive-keyring.gpg
sudo apt-get remove -y --allow-change-held-packages kubectl kubeadm kubelet kubernetes-cni || true
sudo apt-get autoremove -y

# Update system
sudo apt-get update
sudo apt-get upgrade -y

# Install basic utilities
sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common gnupg

# Install Docker
echo "Installing Docker..."
# Add Docker's official GPG key
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -

# Add Docker repository
sudo add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"

# Install Docker CE
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io

# Use the systemd cgroup driver
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

# Verify Docker is installed correctly
docker --version

# Setup for Kubernetes
echo "Setting up prerequisites for Kubernetes..."

# Disable swap
sudo swapoff -a
sudo sed -i '/swap/d' /etc/fstab

# Configure required sysctl settings
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF

sudo sysctl --system

# Load br_netfilter
sudo modprobe br_netfilter

# Directly install Kubernetes components without using repositories
echo "Installing Kubernetes components directly..."

KUBE_VERSION="1.28.8"
# Create download directory
mkdir -p ~/kube_install
cd ~/kube_install

# Download Kubernetes binaries directly
curl -LO "https://dl.k8s.io/release/v${KUBE_VERSION}/bin/linux/amd64/kubectl"
curl -LO "https://dl.k8s.io/release/v${KUBE_VERSION}/bin/linux/amd64/kubeadm"
curl -LO "https://dl.k8s.io/release/v${KUBE_VERSION}/bin/linux/amd64/kubelet"

# Make executable and move to bin directory
sudo chmod +x kubectl kubeadm kubelet
sudo mv kubectl kubeadm kubelet /usr/local/bin/

# Set up kubelet service
curl -sSL "https://raw.githubusercontent.com/kubernetes/release/v0.14.0/cmd/kubepkg/templates/latest/deb/kubelet/lib/systemd/system/kubelet.service" | sudo tee /etc/systemd/system/kubelet.service
sudo mkdir -p /etc/systemd/system/kubelet.service.d
curl -sSL "https://raw.githubusercontent.com/kubernetes/release/v0.14.0/cmd/kubepkg/templates/latest/deb/kubeadm/10-kubeadm.conf" | sudo tee /etc/systemd/system/kubelet.service.d/10-kubeadm.conf

# Enable and start kubelet
sudo systemctl enable --now kubelet

# Initialize Kubernetes
echo "Initializing Kubernetes cluster..."
sudo kubeadm init --pod-network-cidr=192.168.0.0/16 --ignore-preflight-errors=all

# Set up kubectl for the user
mkdir -p $HOME/.kube
sudo cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Install Calico network plugin
echo "Installing Calico network plugin..."
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.26.0/manifests/tigera-operator.yaml
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.26.0/manifests/custom-resources.yaml

# Remove the control-plane node taint so that pods can be scheduled on it
kubectl taint nodes --all node-role.kubernetes.io/control-plane-

# Open required ports in firewall
echo "Configuring firewall..."
sudo apt-get install -y ufw
sudo ufw allow 6443/tcp  # Kubernetes API server
sudo ufw allow 2379:2380/tcp  # etcd server client API
sudo ufw allow 10250/tcp  # Kubelet API
sudo ufw allow 10251/tcp  # kube-scheduler
sudo ufw allow 10252/tcp  # kube-controller-manager
sudo ufw allow 8472/udp   # Flannel VXLAN
sudo ufw allow 30000:32767/tcp  # NodePort Services
sudo ufw allow 30405/tcp  # Specific NodePort for our application

# Explicitly open NodePort in iptables
sudo iptables -A INPUT -p tcp --dport 30405 -j ACCEPT
sudo iptables -A OUTPUT -p tcp --sport 30405 -j ACCEPT

# Save iptables rules
sudo apt-get install -y iptables-persistent
sudo netfilter-persistent save

# Verify kubectl works
echo "Verifying kubectl..."
kubectl get nodes

# Verify all pods are running (except coredns which might take a moment)
echo "Verifying pods..."
kubectl get pods --all-namespaces

echo "Kubernetes setup complete. Cluster is ready for deployments."

# Test NodePort connectivity
echo "Testing NodePort connectivity..."
nc -zv localhost 30405 || echo "Port 30405 will be opened when service is deployed"

# Print cluster info
kubectl cluster-info

echo "====== Kubernetes setup completed successfully ======"

# Create a file to indicate completion
touch $HOME/k8s-setup-complete 