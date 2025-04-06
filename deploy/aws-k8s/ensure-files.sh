#!/bin/bash
# Script to ensure all required files are in place on the EC2 instance

set -e

echo "===== Ensuring all required deployment files are in place ====="

# Create deploy directory if it doesn't exist
mkdir -p ~/deploy/aws-k8s

# Check if required script files are present
for script in k8s-deploy.sh verify-access.sh deployment-recovery.sh k8s-setup.sh; do
  if [ ! -f ~/deploy/aws-k8s/$script ]; then
    echo "❌ Missing script: $script - downloading from GitHub..."
    
    # Download from GitHub repository
    curl -s https://raw.githubusercontent.com/aradhya24/cold-email-generator/main/deploy/aws-k8s/$script > ~/deploy/aws-k8s/$script
    
    if [ $? -ne 0 ]; then
      echo "Failed to download $script from GitHub. Manual intervention required."
      exit 1
    fi
  else
    echo "✅ Script file exists: $script"
  fi
  
  # Ensure script is executable
  chmod +x ~/deploy/aws-k8s/$script
done

# Create k8s_manifests directory if it doesn't exist
mkdir -p ~/k8s_manifests

# Check if k3s is installed, if not run the setup script
if ! command -v k3s &> /dev/null; then
  echo "⚠️ k3s not found, running k8s-setup.sh to install it..."
  ~/deploy/aws-k8s/k8s-setup.sh
else
  echo "✅ k3s is already installed"
  # Check if kubectl works
  if ! k3s kubectl get nodes &> /dev/null; then
    echo "⚠️ k3s installed but not working properly, reinstalling..."
    ~/deploy/aws-k8s/k8s-setup.sh
  else
    echo "✅ k3s is working properly"
  fi
fi

echo "✅ All required deployment files are in place"
echo "You can now run deployment scripts:"
echo "  ~/deploy/aws-k8s/k8s-deploy.sh - For fresh deployment"
echo "  ~/deploy/aws-k8s/deployment-recovery.sh - For recovering interrupted deployments"
echo "  ~/deploy/aws-k8s/verify-access.sh - For verifying access to the deployment" 