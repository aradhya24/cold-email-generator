#!/bin/bash
# Verification script for Cold Email Generator accessibility
set -e

echo "===== Verifying Cold Email Generator Application Access ====="

# Step 1: Check if the pod is running correctly
echo "Checking pod status..."
RUNNING_PODS=$(kubectl get pods -n cold-email -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}')
if [ -z "$RUNNING_PODS" ]; then
  echo "ERROR: No running pods found in namespace 'cold-email'"
  echo "Checking pod status and events for troubleshooting:"
  kubectl get pods -n cold-email
  
  # Get the name of any pod even if not running
  POD_NAME=$(kubectl get pods -n cold-email -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [ ! -z "$POD_NAME" ]; then
    echo "Pod details:"
    kubectl describe pod $POD_NAME -n cold-email
    
    echo "Pod logs (if available):"
    kubectl logs $POD_NAME -n cold-email --previous || kubectl logs $POD_NAME -n cold-email || echo "No logs available"
  fi
  
  echo "Attempting to fix deployment..."
  echo "Recreating deployment with correct configuration..."
  kubectl delete deployment cold-email-generator -n cold-email --grace-period=0 --force || echo "No deployment to delete"
  sleep 5
  
  # Create fixed deployment
  cat <<EOF | kubectl apply -f -
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
        image: ${DOCKER_IMAGE:-"ghcr.io/aradhya24/cold-email-generator:latest"}
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
  
  echo "Waiting for pod to start..."
  sleep 30
  kubectl get pods -n cold-email
else
  echo "✅ Pods are running: $RUNNING_PODS"
fi

# Step 2: Check service configuration
echo -e "\nChecking service configuration..."
SERVICE_INFO=$(kubectl get svc cold-email-service -n cold-email -o jsonpath='{.spec.type} {.spec.ports[0].nodePort} {.spec.ports[0].targetPort}')
if [ -z "$SERVICE_INFO" ]; then
  echo "ERROR: Service 'cold-email-service' not found"
  echo "Creating correct service..."
  
  # Create a fixed service
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
  - name: http
    port: 80
    targetPort: 3000
    nodePort: 30405
  type: NodePort
EOF
  
  echo "Service created. Waiting for it to be assigned..."
  sleep 10
  kubectl get svc -n cold-email
else
  echo "✅ Service is configured: $SERVICE_INFO"
fi

# Step 3: Check if application is responding on pod IP directly
echo -e "\nChecking if application is responding inside the pod..."
POD_NAME=$(kubectl get pods -n cold-email -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ ! -z "$POD_NAME" ]; then
  echo "Testing connectivity to pod $POD_NAME directly..."
  # Set up port forwarding to test pod directly
  kubectl port-forward $POD_NAME 8080:3000 -n cold-email &
  PF_PID=$!
  sleep 5
  
  # Try to connect to forwarded port
  curl -s -m 5 http://localhost:8080 > /dev/null
  if [ $? -eq 0 ]; then
    echo "✅ Application is accessible directly from pod!"
  else
    echo "❌ Application is not responding from pod. Checking container logs:"
    kubectl logs $POD_NAME -n cold-email
    
    echo "Container may have incorrect listening port or application issues."
    echo "Verifying application is listening on port 3000 inside the container..."
    kubectl exec $POD_NAME -n cold-email -- netstat -tulpn | grep 3000 || echo "Application is not listening on port 3000"
  fi
  
  # Kill port-forwarding process
  kill $PF_PID >/dev/null 2>&1 || true
fi

# Step 4: Check NodePort access
echo -e "\nChecking NodePort (30405) access..."
NODE_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "unknown")
if [ "$NODE_IP" == "unknown" ]; then
  echo "Could not get instance public IP from metadata. Using hostname..."
  NODE_IP=$(hostname -I | awk '{print $1}')
fi

echo "Testing NodePort access at http://$NODE_IP:30405..."
curl -s -m 5 http://$NODE_IP:30405 > /dev/null
if [ $? -eq 0 ]; then
  echo "✅ NodePort is accessible at http://$NODE_IP:30405"
else
  echo "❌ NodePort is not accessible. Checking security group..."
  
  # Get security group ID
  INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
  SG_ID=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --query "Reservations[0].Instances[0].SecurityGroups[0].GroupId" --output text)
  
  echo "Security Group ID: $SG_ID"
  echo "Adding NodePort rule to security group..."
  aws ec2 authorize-security-group-ingress \
    --group-id $SG_ID \
    --protocol tcp \
    --port 30405 \
    --cidr 0.0.0.0/0 || echo "Rule already exists or failed to add"
    
  echo "Testing netcat on localhost:30405..."
  nc -zv -w 5 localhost 30405 || echo "Port not accessible locally"
  
  echo "Testing iptables rules..."
  sudo iptables -L -n | grep 30405 || echo "No iptables rules for port 30405"
  
  echo "Checking if kube-proxy is running correctly..."
  ps aux | grep kube-proxy
fi

# Step 5: Check for any network policy restrictions
echo -e "\nChecking for network policies that might block access..."
NETPOL=$(kubectl get netpol -n cold-email 2>/dev/null)
if [ ! -z "$NETPOL" ]; then
  echo "Network policies found that might restrict access:"
  echo "$NETPOL"
  
  echo "Removing restrictive network policies..."
  kubectl delete netpol --all -n cold-email
else
  echo "✅ No restrictive network policies found"
fi

# Step 6: Final checks and summary
echo -e "\n===== Application Access Summary ====="
echo "Endpoint URLs:"
echo "1. NodePort: http://$NODE_IP:30405"

# Get LoadBalancer info if available
LB_DNS=$(kubectl get svc cold-email-service -n cold-email -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
if [ ! -z "$LB_DNS" ] && [ "$LB_DNS" != "null" ]; then
  echo "2. LoadBalancer: http://$LB_DNS"
  
  echo "Testing LoadBalancer access..."
  curl -s -m 5 http://$LB_DNS > /dev/null
  if [ $? -eq 0 ]; then
    echo "✅ LoadBalancer is accessible at http://$LB_DNS"
  else
    echo "❌ LoadBalancer at $LB_DNS is not accessible yet. This might take a few minutes to provision fully."
  fi
else
  echo "2. LoadBalancer: Not yet provisioned or assigned"
fi

echo -e "\nEndpoint Connectivity Test Results:"
curl -s -o /dev/null -w "NodePort Status: %{http_code}\n" http://$NODE_IP:30405 || echo "NodePort connection failed"
if [ ! -z "$LB_DNS" ] && [ "$LB_DNS" != "null" ]; then
  curl -s -o /dev/null -w "LoadBalancer Status: %{http_code}\n" http://$LB_DNS || echo "LoadBalancer connection failed"
fi

echo -e "\nFor troubleshooting issues, check the following:"
echo "- Pod logs: kubectl logs -n cold-email <pod-name>"
echo "- Service details: kubectl describe svc cold-email-service -n cold-email"
echo "- Application port configuration" 
echo "- Security group rules for ports 30405 and 80"
echo "- Instance health checks and network configuration"
echo "- AWS LoadBalancer provisioning status (may take up to 10 minutes to become fully available)"

echo -e "\nVerification script completed!" 