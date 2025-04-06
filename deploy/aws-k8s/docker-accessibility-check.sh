#!/bin/bash
# Script to verify Docker image accessibility and ensure it can run properly

set -e

export DOCKER_IMAGE=${DOCKER_IMAGE:-ghcr.io/aradhya24/cold-email:latest}
export APP_NAME=${APP_NAME:-cold-email}
export APP_PORT=8501

echo "===== Docker Image Accessibility Check ====="

# Try to pull the image
echo "Attempting to pull Docker image: $DOCKER_IMAGE"
sudo docker pull $DOCKER_IMAGE || {
  echo "❌ Failed to pull image $DOCKER_IMAGE"
  echo "Checking if Docker registry authentication is needed..."
  
  if [[ $DOCKER_IMAGE == ghcr.io/* ]]; then
    echo "This is a GitHub Container Registry image."
    
    if [ -z "$GITHUB_TOKEN" ]; then
      echo "❌ GITHUB_TOKEN is not set. Unable to authenticate with GHCR."
      echo "Please provide a GitHub token with read:packages scope to access private packages."
    else
      echo "Attempting to log in to GHCR using provided token..."
      echo "$GITHUB_TOKEN" | sudo docker login ghcr.io -u $GITHUB_USERNAME --password-stdin
      
      echo "Trying to pull image again after authentication..."
      sudo docker pull $DOCKER_IMAGE || echo "❌ Still unable to pull image. Might be a non-existent image or insufficient permissions."
    fi
  fi
}

# Check if image exists locally now
if sudo docker image inspect $DOCKER_IMAGE &>/dev/null; then
  echo "✅ Image is accessible and pulled successfully"
  
  # Try to run the image
  echo "Testing image by running a container..."
  CONTAINER_ID=$(sudo docker run -d -p 8899:$APP_PORT $DOCKER_IMAGE)
  
  if [ ! -z "$CONTAINER_ID" ]; then
    echo "✅ Container started successfully with ID: $CONTAINER_ID"
    
    # Wait for container to start up
    echo "Waiting for container to start up (10 seconds)..."
    sleep 10
    
    # Check container status
    CONTAINER_STATUS=$(sudo docker inspect --format="{{.State.Status}}" $CONTAINER_ID)
    echo "Container status: $CONTAINER_STATUS"
    
    if [ "$CONTAINER_STATUS" == "running" ]; then
      echo "✅ Container is running properly"
      
      # Test container accessibility
      echo "Testing container accessibility on port 8899..."
      curl -s --connect-timeout 5 http://localhost:8899 | head -n 20 || echo "❌ Cannot connect to container"
      
      # Check container logs
      echo "Container logs:"
      sudo docker logs $CONTAINER_ID --tail 30
    else
      echo "❌ Container is not running. Status: $CONTAINER_STATUS"
      echo "Container logs:"
      sudo docker logs $CONTAINER_ID
    fi
    
    # Clean up the container
    echo "Cleaning up test container..."
    sudo docker stop $CONTAINER_ID
    sudo docker rm $CONTAINER_ID
  else
    echo "❌ Failed to start container from image"
  fi
else
  echo "❌ Image is not accessible locally"
fi

echo "===== Docker Image Check Complete ====="
echo "If there were issues, ensure:"
echo "1. The image exists and is correctly tagged"
echo "2. You have authentication if needed (for private registries)"
echo "3. The image contains a working application that listens on port $APP_PORT"
echo "==================================================" 