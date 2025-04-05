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
        env:
        - name: PORT
          value: "3000"
        - name: GROQ_API_KEY
          valueFrom:
            secretKeyRef:
              name: app-secrets
              key: GROQ_API_KEY
        resources:
          limits:
            memory: "512Mi"
            cpu: "500m"
          requests:
            memory: "256Mi"
            cpu: "250m"
EOF

# Create NodePort service
echo "Creating service with fixed NodePort..."
cat <<EOF | $KUBECTL_CMD apply -f -
apiVersion: v1
kind: Service
metadata:
  name: ${APP_NAME}-service
  namespace: ${APP_NAME}
spec:
  type: NodePort
  ports:
  - port: 80
    targetPort: 3000
    nodePort: 30405
  selector:
    app: ${APP_NAME}-generator
EOF

# Wait for deployment to be ready
echo "Waiting for deployment to be ready..."
$KUBECTL_CMD rollout status deployment/${APP_NAME}-generator --namespace=${APP_NAME} --timeout=120s

# Get public IP of the node
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)

# Display access URLs
echo ""
echo "Application deployment attempted!"
echo ""
echo "Application should be accessible at:"
echo "- Load Balancer URL: http://${LB_DNS}"
echo "- Node Port URL: http://${PUBLIC_IP}:30405"
echo ""
echo "Kubernetes resources:"
echo "- Namespace: ${APP_NAME}"
echo "- Deployment: ${APP_NAME}-generator"
echo "- Service: ${APP_NAME}-service"
echo "- Ingress: ${APP_NAME}-ingress"
echo ""

# Create a simple health check that will work even if the application is not yet ready
echo "Testing application access..."
curl -s --connect-timeout 5 http://${PUBLIC_IP}:30405 || echo "Application not yet responding (this is normal if it's still starting up)"

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
echo "Testing NodePort connectivity on port 30405..."
nc -zv -w 5 localhost 30405 || echo "NodePort not accessible locally"

# Check if the security group has the required ports open
echo ""
echo "Verifying security group rules for EC2 instance..."
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
SG_ID=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --query "Reservations[0].Instances[0].SecurityGroups[0].GroupId" --output text)
aws ec2 describe-security-groups --group-ids $SG_ID --query "SecurityGroups[0].IpPermissions[?FromPort==\`30405\`]" --output json

echo ""
echo "Important ports to check in security group:"
echo "- Port 22: SSH access"
echo "- Port 80: HTTP/Load Balancer access" 
echo "- Port 30405: Kubernetes NodePort access"
echo ""
echo "If the application is still not accessible, try updating security group rules to allow these ports."
echo ""
echo "Complete troubleshooting command to run on EC2 instance:"
echo "sudo netstat -tulpn | grep -E '(30405|3000)'"
echo ""
echo "Wait a few minutes for the LoadBalancer to be fully provisioned and endpoints to be registered."
echo "If application is still not accessible after 5-10 minutes, try these troubleshooting steps:"
echo "1. Check pod status: kubectl get pods -n ${APP_NAME}"
echo "2. Check pod logs: kubectl logs -n ${APP_NAME} [pod-name]"
echo "3. Verify service endpoints: kubectl get endpoints -n ${APP_NAME}"
echo "4. Test connectivity directly to pod: kubectl port-forward -n ${APP_NAME} [pod-name] 8080:3000"
echo ""
echo "Deployment process completed. Thank you for using the Cold Email Generator!" 