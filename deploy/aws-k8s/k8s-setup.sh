#!/bin/bash
# Ultra-simple Kubernetes setup using K3s
set -e

echo "====== Setting up Lightweight Kubernetes (K3s) on EC2 instance ======"

# Clean up any previous installations
echo "Cleaning up any previous Kubernetes installations..."
sudo systemctl stop kubelet microk8s k3s || true
sudo apt-get remove -y kubeadm kubectl kubelet kubernetes-cni || true
sudo snap remove microk8s || true
sudo rm -rf /etc/kubernetes /var/lib/kubelet /etc/cni /opt/cni || true
sudo rm -rf /var/lib/rancher/k3s || true
sudo rm -f /usr/local/bin/k3s /usr/local/bin/kubectl || true

# Install K3s - the simplest way to run Kubernetes
echo "Installing K3s (lightweight Kubernetes)..."
curl -sfL https://get.k3s.io | sh -

# Wait for k3s to be ready
echo "Waiting for K3s to start..."
sleep 10

# Set up kubectl config for the user
echo "Setting up kubectl..."
mkdir -p $HOME/.kube
sudo cp /etc/rancher/k3s/k3s.yaml $HOME/.kube/config
sudo chmod 644 /etc/rancher/k3s/k3s.yaml
sudo chown $USER:$USER $HOME/.kube/config
export KUBECONFIG=$HOME/.kube/config

# Configure firewall
echo "Configuring firewall for NodePort access..."
sudo apt-get install -y ufw
sudo ufw allow 22/tcp
sudo ufw allow 6443/tcp  # Kubernetes API
sudo ufw allow 30000:32767/tcp  # NodePort range
sudo ufw allow 30405/tcp  # Specific NodePort for our application
sudo ufw --force enable

# Create a simple test deployment to verify it's working
echo "Creating test deployment..."
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-test
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx-test
  template:
    metadata:
      labels:
        app: nginx-test
    spec:
      containers:
      - name: nginx
        image: nginx:latest
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: nginx-test
  namespace: default
spec:
  type: NodePort
  ports:
  - port: 80
    targetPort: 80
    nodePort: 30405
  selector:
    app: nginx-test
EOF

# Wait for deployment to be ready
echo "Waiting for test deployment to be ready..."
kubectl rollout status deployment/nginx-test

# Get service details
echo "Testing NodePort service..."
kubectl get service nginx-test

# Get public IP
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
echo "Test application available at: http://$PUBLIC_IP:30405"

# Create a file to indicate completion
touch $HOME/k8s-setup-complete

echo "====== K3s setup completed successfully ======"
echo "Your application will be accessible at: http://$PUBLIC_IP:30405"