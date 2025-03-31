#!/bin/bash
set -e

# This script is called by the GitLab CI/CD pipeline
# It simply calls the deploy-k8s.sh script with the correct arguments

echo "Starting deployment..."

# Ensure KUBECONFIG is set
if [ -z "$KUBECONFIG" ]; then
  export KUBECONFIG=$HOME/.kube/config
  echo "KUBECONFIG set to $KUBECONFIG"
fi

# Verify kubectl access
if ! kubectl get nodes; then
  echo "ERROR: Cannot access Kubernetes API. Checking configuration..."
  
  # Check if the config file exists
  if [ -f "$HOME/.kube/config" ]; then
    echo "Config file exists, but kubectl cannot access the API."
    echo "Trying to fix permissions..."
    sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
    sudo chown $(id -u):$(id -g) $HOME/.kube/config
    export KUBECONFIG=$HOME/.kube/config
    
    # Try again
    if ! kubectl get nodes; then
      echo "Still cannot access Kubernetes API. Trying to source environment..."
      source $HOME/.bashrc
      
      if ! kubectl get nodes; then
        echo "kubectl access failed. Kubernetes might not be properly initialized."
        echo "Check Kubernetes setup before continuing."
        exit 1
      fi
    fi
  else
    echo "No Kubernetes config file found at $HOME/.kube/config"
    echo "Please run setup-k8s.sh first to initialize Kubernetes."
    exit 1
  fi
fi

echo "Kubernetes API is accessible!"

# Export variables so the child script can access them
export CI_REGISTRY=${CI_REGISTRY}
export CI_COMMIT_SHA=${CI_COMMIT_SHA}
export LB_DNS=${LB_DNS}
export KUBECONFIG=$HOME/.kube/config

# Check if deploy-k8s.sh exists
if [ ! -f ~/scripts/deploy-k8s.sh ]; then
  echo "Error: deploy-k8s.sh script not found in ~/scripts/"
  echo "Current directory: $(pwd)"
  echo "Contents of ~/scripts/:"
  ls -la ~/scripts/
  exit 1
fi

# Make sure the script is executable
chmod +x ~/scripts/deploy-k8s.sh

# Run the actual deployment script
~/scripts/deploy-k8s.sh

# Check the exit status
if [ $? -ne 0 ]; then
  echo "Error: Deployment script exited with non-zero status"
  exit 1
fi

echo "Deployment completed successfully!" 