#!/bin/bash
set -e

# Initialize Kubernetes
sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --ignore-preflight-errors=NumCPU,Mem

# Set up kubectl for the ubuntu user
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Install Flannel network plugin
kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml

# Allow scheduling pods on the master node (since we're using a single node for free tier)
kubectl taint nodes --all node-role.kubernetes.io/master-

# Create namespace
kubectl apply -f k8s/namespace.yaml

# Create secret
kubectl create secret generic app-secrets \
  --namespace=cold-email \
  --from-literal=GROQ_API_KEY=$GROQ_API_KEY \
  --dry-run=client -o yaml | kubectl apply -f -

# Install nginx ingress controller
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.2/deploy/static/provider/cloud/deploy.yaml