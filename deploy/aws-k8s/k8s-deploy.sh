#!/bin/bash
# Script to deploy application to Kubernetes
set -e

echo "====== Deploying Cold Email Generator to Kubernetes ======"

# Get environment variables
DOCKER_IMAGE=${DOCKER_IMAGE:-ghcr.io/aradhya24/cold-email:latest}
LB_DNS=${LB_DNS:-pending.elb.amazonaws.com}
APP_NAME=${APP_NAME:-cold-email}

# Check if LB_DNS is set
if [ -z "$LB_DNS" ]; then
  echo "WARNING: LB_DNS environment variable is not set"
  echo "The application will be deployed but might not have the load balancer DNS information"
fi

# Check that kubectl is available
echo "Verifying kubectl access..."
# Use direct path for K3s kubectl
if [ -f /usr/local/bin/kubectl ]; then
  KUBECTL_CMD="/usr/local/bin/kubectl"
elif [ -f ~/.kube/config ]; then
  KUBECTL_CMD="kubectl"
else
  KUBECTL_CMD="/usr/local/bin/k3s kubectl"
fi

$KUBECTL_CMD get nodes

# Create namespace if it doesn't exist
echo "Creating namespace..."
$KUBECTL_CMD create namespace ${APP_NAME} --dry-run=client -o yaml | $KUBECTL_CMD apply -f -

# Print Docker image being used
echo "Using Docker image: ${DOCKER_IMAGE}"
echo "Using Load Balancer DNS: ${LB_DNS}"

# Create secret for API key
echo "Creating secret for Groq API key..."
$KUBECTL_CMD create secret generic app-secrets \
  --from-literal=GROQ_API_KEY="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" \
  --namespace=${APP_NAME} \
  --dry-run=client -o yaml | $KUBECTL_CMD apply -f -

# First, delete any existing service to avoid port conflicts
echo "Removing any existing services to avoid port conflicts..."
$KUBECTL_CMD delete service ${APP_NAME}-service --namespace=${APP_NAME} --ignore-not-found=true

# Create deployment with explicit PORT environment variable
echo "Ensuring container is using the correct port..."
echo "Creating deployment with explicit port configuration..."

cat <<EOF | $KUBECTL_CMD apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP_NAME}-generator
  namespace: ${APP_NAME}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${APP_NAME}-generator
  template:
    metadata:
      labels:
        app: ${APP_NAME}-generator
    spec:
      containers:
      - name: ${APP_NAME}-generator
        image: ${DOCKER_IMAGE}
        ports:
        - containerPort: 3000
          name: http
        env:
        - name: PORT
          value: "3000"
        - name: NODE_ENV
          value: "production"
        - name: HOST
          value: "0.0.0.0"
        - name: GROQ_API_KEY
          valueFrom:
            secretKeyRef:
              name: app-secrets
              key: GROQ_API_KEY
        # Use a startup probe instead of readiness/liveness
        # This allows more time for the application to start
        startupProbe:
          tcpSocket:
            port: 3000
          failureThreshold: 30
          periodSeconds: 10
        resources:
          limits:
            memory: "512Mi"
            cpu: "500m"
          requests:
            memory: "256Mi"
            cpu: "250m"
EOF

# Create service with LoadBalancer type instead of NodePort
echo "Creating service with LoadBalancer type..."
cat <<EOF | $KUBECTL_CMD apply -f -
apiVersion: v1
kind: Service
metadata:
  name: ${APP_NAME}-service
  namespace: ${APP_NAME}
spec:
  type: LoadBalancer
  ports:
  - port: 80
    targetPort: 3000
  selector:
    app: ${APP_NAME}-generator
EOF

# Wait for deployment to be ready with longer timeout
echo "Waiting for deployment to be ready (this may take a few minutes)..."
$KUBECTL_CMD rollout status deployment/${APP_NAME}-generator --namespace=${APP_NAME} --timeout=300s || echo "Deployment not fully ready, but continuing..."

# Continue with deployment even if rollout status times out
echo "Checking pod status regardless of rollout status..."
$KUBECTL_CMD get pods -n ${APP_NAME} -o wide

# Get service details
echo "Waiting for LoadBalancer to be provisioned..."
sleep 30  # Give time for the LoadBalancer to be provisioned

# Get service details
SERVICE_IP=$($KUBECTL_CMD get svc ${APP_NAME}-service -n ${APP_NAME} -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
SERVICE_HOSTNAME=$($KUBECTL_CMD get svc ${APP_NAME}-service -n ${APP_NAME} -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)

# Fallback to NodePort if LoadBalancer isn't ready yet
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
NODE_PORT=$($KUBECTL_CMD get svc ${APP_NAME}-service -n ${APP_NAME} -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)

# Display access URLs
echo ""
echo "Application deployment attempted!"
echo ""
echo "Application should be accessible at:"
# Only show this if we have a hostname or IP from the LoadBalancer
if [ ! -z "$SERVICE_HOSTNAME" ]; then
  echo "- Load Balancer URL: http://${SERVICE_HOSTNAME}"
elif [ ! -z "$SERVICE_IP" ]; then
  echo "- Load Balancer IP: http://${SERVICE_IP}"
fi

if [ ! -z "$NODE_PORT" ]; then
  echo "- Node Port URL (fallback): http://${PUBLIC_IP}:${NODE_PORT}"
fi
echo ""
echo "Kubernetes resources:"
echo "- Namespace: ${APP_NAME}"
echo "- Deployment: ${APP_NAME}-generator"
echo "- Service: ${APP_NAME}-service"
echo "- Ingress: ${APP_NAME}-ingress"
echo ""

# Create a simple health check that will work even if the application is not yet ready
echo "Testing application access..."
if [ ! -z "$SERVICE_HOSTNAME" ]; then
  curl -s --connect-timeout 5 http://${SERVICE_HOSTNAME} || echo "Application not yet responding (this is normal if it's still starting up)"
elif [ ! -z "$SERVICE_IP" ]; then
  curl -s --connect-timeout 5 http://${SERVICE_IP} || echo "Application not yet responding (this is normal if it's still starting up)"
elif [ ! -z "$NODE_PORT" ]; then
  curl -s --connect-timeout 5 http://${PUBLIC_IP}:${NODE_PORT} || echo "Application not yet responding (this is normal if it's still starting up)"
else
  echo "No accessible endpoints found yet. This is normal if the LoadBalancer is still being provisioned."
fi

# Check and display deployments
echo "Deployment status:"
$KUBECTL_CMD get deployments -n ${APP_NAME} || echo "Could not retrieve deployments"

# Check pod status and retry if no pods found
echo "Pod status:"
PODS=$($KUBECTL_CMD get pods -n ${APP_NAME} 2>/dev/null)
if [ -z "$PODS" ]; then
  echo "No pods found. Waiting and trying again..."
  sleep 30
  $KUBECTL_CMD get pods -n ${APP_NAME} || echo "Still no pods found."
else
  echo "$PODS"
fi

# Show pod details for troubleshooting
echo ""
echo "Pod details (for troubleshooting):"
FIRST_POD=$($KUBECTL_CMD get pods -n ${APP_NAME} -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ ! -z "$FIRST_POD" ]; then
  $KUBECTL_CMD describe pod $FIRST_POD -n ${APP_NAME} || echo "Could not get pod details"
else
  echo "No pods found to describe"
fi

# Show service details
echo ""
echo "Service details:"
$KUBECTL_CMD describe service ${APP_NAME}-service -n ${APP_NAME} || echo "Could not retrieve service details"

echo ""
echo "Deployment process completed. Thank you for using the Cold Email Generator!"

# Check service status and print additional connectivity debugging info
echo "Checking service details and connectivity..."
$KUBECTL_CMD get svc -n ${APP_NAME} -o wide
echo ""

# Check if any pods are running and get their status
echo "Checking pod status:"
$KUBECTL_CMD get pods -n ${APP_NAME}
FIRST_POD=$($KUBECTL_CMD get pods -n ${APP_NAME} -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

# Check pod logs to see if there are any application errors
if [ ! -z "$FIRST_POD" ]; then
  echo ""
  echo "Pod logs for application container:"
  $KUBECTL_CMD logs $FIRST_POD -n ${APP_NAME} -c ${APP_NAME}-generator || echo "Couldn't get logs"
fi

# Check if the application is accessible on the NodePort
echo ""
echo "Testing connectivity..."
if [ ! -z "$NODE_PORT" ]; then
  echo "Testing NodePort connectivity on port ${NODE_PORT}..."
  nc -zv -w 5 localhost ${NODE_PORT} || echo "NodePort not accessible locally"
fi

if [ ! -z "$SERVICE_HOSTNAME" ]; then
  echo "Testing LoadBalancer connectivity..."
  curl -s --connect-timeout 5 http://${SERVICE_HOSTNAME} -I || echo "LoadBalancer hostname not accessible yet"
fi

# Check if the security group has the required ports open
echo ""
echo "Verifying security group rules for EC2 instance..."
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
SG_ID=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --query "Reservations[0].Instances[0].SecurityGroups[0].GroupId" --output text)
aws ec2 describe-security-groups --group-ids $SG_ID --query "SecurityGroups[0].IpPermissions[?FromPort==\`30407\`]" --output json

echo ""
echo "Important ports to check in security group:"
echo "- Port 22: SSH access"
echo "- Port 80: HTTP/Load Balancer access" 
if [ ! -z "$NODE_PORT" ]; then
  echo "- Port ${NODE_PORT}: Kubernetes NodePort access (fallback)"
fi
echo ""
echo "If the application is still not accessible, try updating security group rules to allow these ports."
echo ""
if [ ! -z "$NODE_PORT" ]; then
  echo "Complete troubleshooting command to run on EC2 instance:"
  echo "sudo netstat -tulpn | grep -E '(${NODE_PORT}|3000)'"
fi
echo ""
echo "Wait a few minutes for the LoadBalancer to be fully provisioned and endpoints to be registered."
echo "If application is still not accessible after 5-10 minutes, try these troubleshooting steps:"
echo "1. Check pod status: kubectl get pods -n ${APP_NAME}"
echo "2. Check pod logs: kubectl logs -n ${APP_NAME} [pod-name]"
echo "3. Verify service endpoints: kubectl get endpoints -n ${APP_NAME}"
echo "4. Test connectivity directly to pod: kubectl port-forward -n ${APP_NAME} [pod-name] 8080:3000"
echo ""
echo "Deployment process completed. Thank you for using the Cold Email Generator!"

# Show pod logs to debug application startup
echo "Showing application logs to debug startup issues..."
sleep 10  # Give the application a moment to start and generate logs
FIRST_POD=$($KUBECTL_CMD get pods -n ${APP_NAME} -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ ! -z "$FIRST_POD" ]; then
  echo "Pod logs for the application container:"
  $KUBECTL_CMD logs $FIRST_POD -n ${APP_NAME} || true
  
  # Try checking for listening ports inside the container
  echo "Checking listening ports inside the container..."
  $KUBECTL_CMD exec $FIRST_POD -n ${APP_NAME} -- sh -c "netstat -tulpn | grep LISTEN || ps aux" || echo "Could not check ports inside container"
  
  # Try to check what port the application is actually using
  echo "Checking environment variables inside the container..."
  $KUBECTL_CMD exec $FIRST_POD -n ${APP_NAME} -- sh -c "env | grep PORT" || echo "Could not check environment variables"
fi 