#!/bin/bash
set -e

# Check if the Kubernetes API is available
echo "Checking Kubernetes API availability..."
if ! kubectl get nodes &>/dev/null; then
  echo "Error: Cannot reach Kubernetes API. Waiting for 60 seconds to see if it comes online..."
  sleep 60
  
  if ! kubectl get nodes &>/dev/null; then
    echo "Error: Kubernetes API is still not available. Check if Kubernetes is properly initialized."
    echo "You might need to run the setup script again."
    exit 1
  fi
fi

# Create namespace if it doesn't exist
echo "Ensuring namespace exists..."
if ! kubectl get namespace cold-email &>/dev/null; then
  kubectl create namespace cold-email
fi

# Apply deployment with substituted environment variables
echo "Deploying application with CI_REGISTRY=${CI_REGISTRY} and CI_COMMIT_SHA=${CI_COMMIT_SHA}"

# Apply deployment
kubectl apply -f ~/k8s/deployment.yaml || {
  echo "Error applying deployment. Retrying with full path and checking file content..."
  cat ~/k8s/deployment.yaml
  kubectl apply -f ~/k8s/deployment.yaml --validate=false
}

# Apply service
echo "Applying service configuration..."
if [ -f ~/k8s/service.yaml ]; then
  kubectl apply -f ~/k8s/service.yaml
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
if [ -f ~/k8s/ingress.yaml ]; then
  kubectl apply -f ~/k8s/ingress.yaml
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