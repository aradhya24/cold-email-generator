#!/bin/bash
set -e

# This script is called by the GitLab CI/CD pipeline
# It simply calls the deploy-k8s.sh script with the correct arguments

echo "Starting deployment..."
# Export variables so the child script can access them
export CI_REGISTRY=${CI_REGISTRY}
export CI_COMMIT_SHA=${CI_COMMIT_SHA}
export LB_DNS=${LB_DNS}

# Run the actual deployment script
~/scripts/deploy-k8s.sh

echo "Deployment completed successfully!" 