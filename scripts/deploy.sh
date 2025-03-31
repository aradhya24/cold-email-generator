#!/bin/bash
set -e

# This script is called by the GitLab CI/CD pipeline
# It simply calls the deploy-k8s.sh script with the correct arguments

echo "Starting deployment..."
# Export variables so the child script can access them
export CI_REGISTRY=${CI_REGISTRY}
export CI_COMMIT_SHA=${CI_COMMIT_SHA}
export LB_DNS=${LB_DNS}

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