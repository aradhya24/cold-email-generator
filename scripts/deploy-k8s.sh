#!/bin/bash
set -e

# Print debugging information
echo "==== Kubernetes Environment Debug Info ===="
echo "USER: $(whoami)"
echo "HOME: $HOME"
echo "KUBECONFIG: $KUBECONFIG"
echo "Config file exists: $([ -f "$HOME/.kube/config" ] && echo "Yes" || echo "No")"
echo "Admin conf exists: $([ -f "/etc/kubernetes/admin.conf" ] && echo "Yes" || echo "No")"
echo "========================================"

# Ensure KUBECONFIG is set
if [ -z "$KUBECONFIG" ]; then
  # Try to find and use the kubeconfig file
  if [ -f "$HOME/.kube/config" ]; then
    export KUBECONFIG=$HOME/.kube/config
    echo "Set KUBECONFIG to $KUBECONFIG"
  elif [ -f "/etc/kubernetes/admin.conf" ]; then
    # If admin.conf exists but user doesn't have their own config, create it
    mkdir -p $HOME/.kube
    sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
    sudo chown $(id -u):$(id -g) $HOME/.kube/config
    export KUBECONFIG=$HOME/.kube/config
    echo "Created and set KUBECONFIG to $KUBECONFIG"
  else
    echo "No Kubernetes config found. Kubernetes may not be initialized."
  fi
fi

# Check if the Kubernetes API is available
echo "Checking Kubernetes API availability..."
if ! kubectl get nodes &>/dev/null; then
  echo "Error: Cannot reach Kubernetes API. Trying alternative approaches..."
  
  # Try with explicit kubeconfig
  if [ -f "/etc/kubernetes/admin.conf" ]; then
    echo "Trying with admin.conf..."
    if ! KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes &>/dev/null; then
      echo "Still cannot access API with admin.conf"
    else
      echo "Access worked with admin.conf, using that..."
      sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
      sudo chown $(id -u):$(id -g) $HOME/.kube/config
      export KUBECONFIG=$HOME/.kube/config
    fi
  fi
  
  # Try again
  if ! kubectl get nodes &>/dev/null; then
    echo "Error: Cannot reach Kubernetes API even after recovery attempts."
    echo "Waiting for 60 seconds in case the API is still starting up..."
    sleep 60
    
    if ! kubectl get nodes &>/dev/null; then
      echo "Error: Kubernetes API is still not available."
      echo "Please check the Kubernetes setup and ensure the API server is running."
      echo "You can run the following to view API server status:"
      echo "  sudo systemctl status kubelet"
      echo "  sudo crictl ps | grep kube-apiserver"
      exit 1
    fi
  fi
fi

echo "Kubernetes API is accessible!"
kubectl get nodes

# Create namespace if it doesn't exist
echo "Ensuring namespace exists..."
if ! kubectl get namespace cold-email &>/dev/null; then
  kubectl create namespace cold-email
fi

# Apply deployment with substituted environment variables
echo "Deploying application with CI_REGISTRY=${CI_REGISTRY} and CI_COMMIT_SHA=${CI_COMMIT_SHA}"

# Set the correct manifest directory
MANIFEST_DIR="/opt/cold-email/k8s"

# Check if deployment file exists and show its content for debugging
echo "Checking deployment file..."
if [ -f "${MANIFEST_DIR}/deployment.yaml" ]; then
  echo "Found deployment file at ${MANIFEST_DIR}/deployment.yaml"
  echo "First 10 lines of deployment file:"
  head -n 10 "${MANIFEST_DIR}/deployment.yaml"
else
  echo "Warning: deployment.yaml not found at ${MANIFEST_DIR}/deployment.yaml"
  echo "Current directory: $(pwd)"
  echo "Files in ${MANIFEST_DIR}:"
  ls -la "${MANIFEST_DIR}" || echo "Directory doesn't exist or can't be accessed"
  
  # Create default deployment if file doesn't exist
  echo "Creating default deployment..."
  cat <<EOF > "${MANIFEST_DIR}/deployment.yaml"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cold-email-generator
  namespace: cold-email
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cold-email-generator
  template:
    metadata:
      labels:
        app: cold-email-generator
    spec:
      containers:
      - name: cold-email-generator
        image: ${CI_REGISTRY:-docker.io/library}/cold-email-generator:${CI_COMMIT_SHA:-latest}
        ports:
        - containerPort: 8501
        env:
        - name: GROQ_API_KEY
          valueFrom:
            secretKeyRef:
              name: app-secrets
              key: GROQ_API_KEY
        resources:
          requests:
            memory: "512Mi"
            cpu: "250m"
          limits:
            memory: "1Gi"
            cpu: "500m"
EOF
fi

# Apply deployment
echo "Applying deployment..."
kubectl apply -f "${MANIFEST_DIR}/deployment.yaml" || {
  echo "Error applying deployment. Retrying with --validate=false..."
  kubectl apply -f "${MANIFEST_DIR}/deployment.yaml" --validate=false
}

# Apply service
echo "Applying service configuration..."
if [ -f "${MANIFEST_DIR}/service.yaml" ]; then
  kubectl apply -f "${MANIFEST_DIR}/service.yaml"
else
  echo "Warning: service.yaml not found. Creating default service..."
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: cold-email-service
  namespace: cold-email
spec:
  selector:
    app: cold-email-generator
  ports:
  - port: 80
    targetPort: 8501
  type: NodePort
EOF
fi

# Apply ingress
echo "Applying ingress configuration..."
if [ -f "${MANIFEST_DIR}/ingress.yaml" ]; then
  kubectl apply -f "${MANIFEST_DIR}/ingress.yaml"
else
  echo "Warning: ingress.yaml not found. Creating default ingress..."
  cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: cold-email-ingress
  namespace: cold-email
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  rules:
  - http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: cold-email-service
            port:
              number: 80
EOF
fi

# Wait for deployment to be ready with timeout and more verbose output
echo "Waiting for deployment to be ready..."
TIMEOUT=180
start_time=$(date +%s)
end_time=$((start_time + TIMEOUT))

while true; do
  current_time=$(date +%s)
  if [ $current_time -gt $end_time ]; then
    echo "Timeout waiting for deployment to be ready. Check the status manually with:"
    echo "kubectl get pods -n cold-email"
    echo "kubectl describe pods -n cold-email"
    break
  fi
  
  # Get deployment status
  READY=$(kubectl get deployment -n cold-email cold-email-generator -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  DESIRED=$(kubectl get deployment -n cold-email cold-email-generator -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
  
  echo "Current status: $READY/$DESIRED pods ready"
  
  if [ "$READY" = "$DESIRED" ] && [ "$DESIRED" != "0" ]; then
    echo "Deployment is ready!"
    break
  fi
  
  # Show pod status for debugging
  echo "Pod status:"
  kubectl get pods -n cold-email
  
  # Wait before checking again
  sleep 10
done

# Print service details
NODE_PORT=$(kubectl get svc -n cold-email cold-email-service -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "N/A")
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "unknown")

echo "Application deployed! Access details:"
if [ ! -z "$LB_DNS" ] && [ "$LB_DNS" != "null" ]; then
  echo "Load Balancer URL: http://${LB_DNS}"
fi
if [ "$NODE_PORT" != "N/A" ] && [ "$PUBLIC_IP" != "unknown" ]; then
  echo "Node Port URL: http://${PUBLIC_IP}:${NODE_PORT}"
fi

# Show pods and services for final verification
echo "Current pods:"
kubectl get pods -n cold-email
echo "Current services:"
kubectl get svc -n cold-email
echo "Current ingress:"
kubectl get ingress -n cold-email

echo "Deployment process completed."