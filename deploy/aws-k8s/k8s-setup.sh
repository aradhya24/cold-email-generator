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

# Install required dependencies for Kubernetes
echo "Installing required dependencies for Kubernetes..."
sudo apt-get install -y conntrack socat ebtables ethtool

# Download and install crictl
CRICTL_VERSION="v1.28.0"
echo "Installing crictl $CRICTL_VERSION..."
wget -q "https://github.com/kubernetes-sigs/cri-tools/releases/download/$CRICTL_VERSION/crictl-$CRICTL_VERSION-linux-amd64.tar.gz"
sudo tar -zxvf "crictl-$CRICTL_VERSION-linux-amd64.tar.gz" -C /usr/local/bin
rm -f "crictl-$CRICTL_VERSION-linux-amd64.tar.gz"

# Configure crictl to work with containerd
echo "Configuring crictl..."
cat <<EOF | sudo tee /etc/crictl.yaml
runtime-endpoint: unix:///var/run/containerd/containerd.sock
image-endpoint: unix:///var/run/containerd/containerd.sock
timeout: 10
debug: false
EOF

# Install CNI plugins required for container networking
echo "Installing CNI plugins..."
CNI_PLUGINS_VERSION="v1.3.0"
CNI_PLUGINS_DIR="/opt/cni/bin"
sudo mkdir -p ${CNI_PLUGINS_DIR}
curl -L "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VERSION}/cni-plugins-linux-amd64-${CNI_PLUGINS_VERSION}.tgz" | sudo tar -C ${CNI_PLUGINS_DIR} -xz

# Setup containerd configuration for Kubernetes
echo "Configuring containerd for Kubernetes..."
sudo mkdir -p /etc/containerd
cat <<EOF | sudo tee /etc/containerd/config.toml
version = 2
[plugins]
  [plugins."io.containerd.grpc.v1.cri"]
    [plugins."io.containerd.grpc.v1.cri".containerd]
      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes]
        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
          runtime_type = "io.containerd.runc.v2"
          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
            SystemdCgroup = true
EOF

# Restart containerd to apply changes
sudo systemctl restart containerd

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

# Create the kubelet.service directory
sudo mkdir -p /etc/systemd/system/kubelet.service.d

# Create kubelet service file manually instead of downloading it
echo "Creating kubelet service file..."
cat <<EOF | sudo tee /etc/systemd/system/kubelet.service
[Unit]
Description=kubelet: The Kubernetes Node Agent
Documentation=https://kubernetes.io/docs/home/
Wants=network-online.target
After=network-online.target

[Service]
ExecStart=/usr/local/bin/kubelet
Restart=always
StartLimitInterval=0
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Create kubelet configuration
cat <<EOF | sudo tee /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
# Note: This dropin only works with kubeadm and kubelet v1.11+
[Service]
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
# This is a file that "kubeadm init" and "kubeadm join" generates at runtime, populating the KUBELET_KUBEADM_ARGS variable dynamically
EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env
# This is a file that the user can use for overrides of the kubelet args as a last resort. Preferably, the user should use
# the .NodeRegistration.KubeletExtraArgs object in the configuration files instead. KUBELET_EXTRA_ARGS should be sourced from this file.
EnvironmentFile=-/etc/default/kubelet
ExecStart=
ExecStart=/usr/local/bin/kubelet \$KUBELET_KUBECONFIG_ARGS \$KUBELET_CONFIG_ARGS \$KUBELET_KUBEADM_ARGS \$KUBELET_EXTRA_ARGS
EOF

# Create /etc/default/kubelet with extra args for troubleshooting
cat <<EOF | sudo tee /etc/default/kubelet
KUBELET_EXTRA_ARGS="--container-runtime=remote --container-runtime-endpoint=unix:///var/run/containerd/containerd.sock --fail-swap-on=false --v=4"
EOF

# Create required kubelet directories
sudo mkdir -p /var/lib/kubelet

# Reload systemd and restart kubelet
echo "Reloading systemd and starting kubelet..."
sudo systemctl daemon-reload
sudo systemctl enable kubelet
sudo systemctl restart kubelet
sudo systemctl status kubelet --no-pager

# Wait for kubelet to be ready
echo "Waiting for kubelet to become ready..."
for i in {1..10}; do
  if sudo curl -sSL http://localhost:10248/healthz &>/dev/null; then
    echo "Kubelet is running!"
    break
  fi
  echo "Waiting for kubelet to start... attempt $i/10"
  sleep 5
done

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