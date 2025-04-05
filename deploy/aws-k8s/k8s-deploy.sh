#!/bin/bash
# Kubernetes deployment script for cold email generator application

# Exit on error, but enable trapping
set -e

echo "====== Deploying Cold Email Generator to Kubernetes ======"

# Function to retry commands
retry_command() {
  local CMD="$1"
  local MAX_ATTEMPTS="$2"
  local SLEEP_TIME="${3:-10}"
  local ATTEMPT=1
  
  echo "Running command with up to $MAX_ATTEMPTS attempts: $CMD"
  
  while [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
    echo "Attempt $ATTEMPT of $MAX_ATTEMPTS..."
    
    if eval "$CMD"; then
      echo "Command succeeded on attempt $ATTEMPT"
      return 0
    else
      echo "Command failed on attempt $ATTEMPT"
      
      if [ $ATTEMPT -lt $MAX_ATTEMPTS ]; then
        echo "Waiting $SLEEP_TIME seconds before next attempt..."
        sleep $SLEEP_TIME
      fi
    fi
    
    ATTEMPT=$((ATTEMPT + 1))
  done
  
  echo "Command failed after $MAX_ATTEMPTS attempts"
  return 1
}

# Ensure required environment variables are set
if [ -z "$DOCKER_IMAGE" ]; then
  echo "ERROR: DOCKER_IMAGE environment variable is not set"
  echo "Please set DOCKER_IMAGE to the full path of your Docker image including tag"
  echo "Example: export DOCKER_IMAGE=ghcr.io/yourusername/cold-email:latest"
  exit 1
fi

if [ -z "$LB_DNS" ]; then
  echo "WARNING: LB_DNS environment variable is not set"
  echo "The application will be deployed but might not have the load balancer DNS information"
  # Set a default value
  LB_DNS="pending.elb.amazonaws.com"
fi

# Check if kubectl is functioning
echo "Verifying kubectl access..."
if ! kubectl get nodes &>/dev/null; then
  echo "kubectl cannot access the cluster. Checking configuration..."
  
  # Try to fix kubectl configuration
  if [ -f "/etc/kubernetes/admin.conf" ]; then
    echo "Found admin.conf, setting KUBECONFIG..."
    export KUBECONFIG=/etc/kubernetes/admin.conf
    
    if ! kubectl get nodes &>/dev/null; then
      echo "Still cannot access cluster. Trying to recreate kubeconfig..."
      mkdir -p $HOME/.kube
      sudo cp -f /etc/kubernetes/admin.conf $HOME/.kube/config
      sudo chown $(id -u):$(id -g) $HOME/.kube/config
    fi
  else
    echo "ERROR: Cannot access Kubernetes cluster and admin.conf not found."
    echo "Kubernetes may not be properly initialized."
    exit 1
  fi
fi

echo "Using Docker image: $DOCKER_IMAGE"
echo "Using Load Balancer DNS: $LB_DNS"

# Create k8s directory if it doesn't exist
mkdir -p $HOME/k8s

# Check if namespace exists, create if needed
kubectl get namespace cold-email &>/dev/null || kubectl create namespace cold-email

# Check if Groq API key is set, create Kubernetes secret if needed
if [ ! -z "$GROQ_API_KEY" ]; then
  echo "Creating secret for Groq API key..."
  kubectl create secret generic app-secrets \
    --namespace=cold-email \
    --from-literal=GROQ_API_KEY=$GROQ_API_KEY \
    --dry-run=client -o yaml | kubectl apply -f -
else
  echo "WARNING: GROQ_API_KEY is not set, application may have limited functionality"
fi

# Fix container port configuration
echo "Ensuring container is using the correct port..."
grep -q 'PORT="3000"' $HOME/.bashrc || echo 'export PORT="3000"' >> $HOME/.bashrc
source $HOME/.bashrc

# Create a simple deployment with correct port configuration
echo "Creating deployment with explicit port configuration..."
cat << EOF | kubectl apply -f -
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
      - name: app
        image: ${DOCKER_IMAGE}
        imagePullPolicy: Always
        ports:
        - containerPort: 3000
          name: http
        env:
        - name: PORT
          value: "3000"
        - name: GROQ_API_KEY
          valueFrom:
            secretKeyRef:
              name: app-secrets
              key: GROQ_API_KEY
              optional: true
EOF

# Create a service with the correct NodePort configuration
echo "Creating service with fixed NodePort..."
cat << EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: cold-email-service
  namespace: cold-email
spec:
  selector:
    app: cold-email-generator
  ports:
  - name: http
    port: 80
    targetPort: 3000
    nodePort: 30405
  type: NodePort
EOF

# Verify the deployment and fix iptables rules
echo "Verifying deployment and fixing network rules..."
kubectl rollout status deployment/cold-email-generator -n cold-email --timeout=120s

# Ensure iptables rules allow traffic
sudo iptables -I INPUT -p tcp --dport 30405 -j ACCEPT
sudo iptables -I OUTPUT -p tcp --sport 30405 -j ACCEPT

# Ensure node port is accessible by testing connection
echo "Testing NodePort connection..."
curl -s -o /dev/null -w "NodePort Status: %{http_code}\n" http://localhost:30405 || echo "Not accessible yet"

# Get public IP for easier access
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)

echo ""
echo "====== Application Access Information ======"
echo "Application should now be accessible at:"
echo "- NodePort URL: http://$PUBLIC_IP:30405"
echo "- Load Balancer URL: http://$LB_DNS"
echo ""
echo "If access fails, please run the verify-access.sh script for detailed diagnostics and automatic fixes."

# Check and display deployments
echo "Deployment status:"
kubectl get deployments -n cold-email || echo "Could not retrieve deployments"

# Check pod status and retry if no pods found
echo "Pod status:"
PODS=$(kubectl get pods -n cold-email 2>/dev/null)
if [ -z "$PODS" ]; then
  echo "No pods found. Waiting and trying again..."
  sleep 30
  kubectl get pods -n cold-email || echo "Still no pods found."
else
  echo "$PODS"
fi

# Show pod details for troubleshooting
echo ""
echo "Pod details (for troubleshooting):"
FIRST_POD=$(kubectl get pods -n cold-email -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ ! -z "$FIRST_POD" ]; then
  kubectl describe pod $FIRST_POD -n cold-email || echo "Could not get pod details"
else
  echo "No pods found to describe"
fi

# Show service details
echo ""
echo "Service details:"
kubectl describe service cold-email-service -n cold-email || echo "Could not retrieve service details"

echo ""
echo "Deployment process completed. Thank you for using the Cold Email Generator!"

# Check service status and print additional connectivity debugging info
echo "Checking service details and connectivity..."
kubectl get svc -n cold-email -o wide
echo ""

# Check if any pods are running and get their status
echo "Checking pod status:"
kubectl get pods -n cold-email
FIRST_POD=$(kubectl get pods -n cold-email -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

# Check pod logs to see if there are any application errors
if [ ! -z "$FIRST_POD" ]; then
  echo ""
  echo "Pod logs for application container:"
  kubectl logs $FIRST_POD -n cold-email -c app || echo "Couldn't get logs"
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
echo "1. Check pod status: kubectl get pods -n cold-email"
echo "2. Check pod logs: kubectl logs -n cold-email [pod-name]"
echo "3. Verify service endpoints: kubectl get endpoints -n cold-email"
echo "4. Test connectivity directly to pod: kubectl port-forward -n cold-email [pod-name] 8080:3000"
echo ""
echo "Deployment process completed. Thank you for using the Cold Email Generator!" 