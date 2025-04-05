#!/bin/bash
# Kubernetes setup script for EC2 instances

set -e

echo "====== Setting up Kubernetes on EC2 instance ======"

# Clean up any previous Kubernetes installations
echo "Cleaning up any previous installations..."
sudo systemctl stop kubelet || true
sudo systemctl disable kubelet || true
sudo kubeadm reset -f || true
sudo apt-get remove -y kubelet kubeadm kubectl kubernetes-cni || true
sudo apt-get remove -y containerd docker.io docker-ce docker-ce-cli || true
sudo rm -rf /etc/kubernetes /var/lib/kubelet /var/lib/etcd /etc/cni /opt/cni /var/run/kubernetes || true
sudo apt-get autoremove -y
sudo apt-get clean

echo "Installing MicroK8s (simplified Kubernetes)..."
# Make sure snapd is installed
sudo apt-get update
sudo apt-get install -y snapd

# Wait for snapd to be fully initialized
echo "Waiting for snapd to be fully initialized..."
sleep 10

# Install MicroK8s
sudo snap install microk8s --classic --channel=1.28/stable

# Wait for MicroK8s to be ready
echo "Waiting for MicroK8s to start..."
sudo microk8s status --wait-ready

# Add current user to microk8s group
sudo usermod -a -G microk8s $USER
sudo chown -R $USER:$USER ~/.kube
newgrp microk8s << EOF

# Enable required MicroK8s addons
echo "Enabling MicroK8s addons..."
sudo microk8s enable dns storage ingress

# Set up kubectl alias and config
echo "Setting up kubectl..."
sudo microk8s kubectl config view --raw > ~/.kube/config
sudo chmod 600 ~/.kube/config

# Allow the node to schedule pods (remove NoSchedule taint)
echo "Allowing control-plane to run workloads..."
sudo microk8s kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true
sudo microk8s kubectl taint nodes --all node-role.kubernetes.io/master- || true

# Open NodePort port in firewall
echo "Configuring firewall..."
sudo apt-get install -y ufw
sudo ufw allow 22/tcp
sudo ufw allow 16443/tcp # Kubernetes API server
sudo ufw allow 10250/tcp # Kubelet
sudo ufw allow 10255/tcp # Kubelet read-only
sudo ufw allow 30000:32767/tcp # NodePort range
sudo ufw allow 30405/tcp # Specific NodePort for our application
sudo ufw --force enable

# Verify everything is working correctly
echo "Verifying MicroK8s installation..."
sudo microk8s kubectl get nodes
sudo microk8s kubectl get services --all-namespaces

# Enable privileged containers (required for some applications)
echo "Enabling privileged containers..."
sudo mkdir -p /var/snap/microk8s/current/args/
echo "--allow-privileged=true" | sudo tee -a /var/snap/microk8s/current/args/kube-apiserver
sudo systemctl restart snap.microk8s.daemon-apiserver

# Check functionality
echo "Checking NodePort access..."
sudo netstat -tulpn | grep -E '30405|30000|32767' || echo "NodePort range is configured but no services yet"

# Create aliases for easier usage
echo "alias kubectl='microk8s kubectl'" >> ~/.bashrc
echo "alias k='microk8s kubectl'" >> ~/.bashrc

# Create a file to indicate completion
touch $HOME/k8s-setup-complete

echo "====== MicroK8s setup completed successfully ======"
echo "You can now use 'microk8s kubectl' to interact with your Kubernetes cluster."
EOF

# Fix permissions just in case
sudo chown -R $USER:$USER ~/.kube

echo "====== Kubernetes setup completed successfully ======"