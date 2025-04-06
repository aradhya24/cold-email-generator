#!/bin/bash
# Script to verify and troubleshoot Cold Email Generator application access

set -e

APP_NAME=${APP_NAME:-cold-email}
NAMESPACE=${NAMESPACE:-$APP_NAME}
KUBECTL_CMD="k3s kubectl"
APP_PORT=3000

echo "===== Verifying Cold Email Generator Application Access ====="

# Check if we have saved access information from the deployment script
if [ -f ~/app_access.txt ]; then
  echo "Loading saved access information..."
  source ~/app_access.txt
  echo "Main URL: ${MAIN_URL}"
  echo "Fallback URL: ${FALLBACK_URL}"
fi

# Check if the pod exists and is running
echo "Checking pod status..."
POD_NAME=$($KUBECTL_CMD get pods -n $NAMESPACE -l app=${APP_NAME}-generator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -z "$POD_NAME" ]; then
  echo "❌ No pods found! Checking for deployment issues..."
  $KUBECTL_CMD describe deployment ${APP_NAME}-generator -n $NAMESPACE || echo "No deployment found"
  
  echo "Creating a test deployment to verify Kubernetes functionality..."
  cat <<EOF | $KUBECTL_CMD apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-nginx
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test-nginx
  template:
    metadata:
      labels:
        app: test-nginx
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
EOF
  echo "Waiting for test deployment..."
  sleep 20
  $KUBECTL_CMD get pods -A
  exit 1
else
  POD_STATUS=$($KUBECTL_CMD get pod $POD_NAME -n $NAMESPACE -o jsonpath='{.status.phase}')
  if [ "$POD_STATUS" == "Running" ]; then
    echo "✅ Pods are running: $POD_NAME"
    
    # Check readiness
    IS_READY=$($KUBECTL_CMD get pod $POD_NAME -n $NAMESPACE -o jsonpath='{.status.containerStatuses[0].ready}')
    if [ "$IS_READY" == "true" ]; then
      echo "✅ Pod is ready and passing health checks"
    else
      echo "⚠️ Pod is running but not ready yet"
      
      # Check logs to see why it might not be ready
      echo "Checking pod logs for possible issues..."
      $KUBECTL_CMD logs $POD_NAME -n $NAMESPACE | tail -n 20
      
      # Check if port is open in container
      echo "Checking if app is listening on port $APP_PORT inside container..."
      $KUBECTL_CMD exec $POD_NAME -n $NAMESPACE -- sh -c "netstat -tulpn | grep $APP_PORT || echo 'Port not open'" 2>/dev/null || echo "Could not check ports (command not available)"
    fi
  else
    echo "❌ Pod $POD_NAME is not running (status: $POD_STATUS)"
    echo "Pod details:"
    $KUBECTL_CMD describe pod $POD_NAME -n $NAMESPACE
    echo "Pod logs:"
    $KUBECTL_CMD logs $POD_NAME -n $NAMESPACE
    exit 1
  fi
fi

# Check load balancer status
echo "Checking LoadBalancer status..."
LB_TYPE=$($KUBECTL_CMD get svc ${APP_NAME}-service -n $NAMESPACE -o jsonpath='{.spec.type}' 2>/dev/null)
LB_HOSTNAME=$($KUBECTL_CMD get svc ${APP_NAME}-service -n $NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
LB_IP=$($KUBECTL_CMD get svc ${APP_NAME}-service -n $NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)

if [ "$LB_TYPE" == "LoadBalancer" ]; then
  echo "✅ Service type is correctly set to LoadBalancer"
  
  if [ ! -z "$LB_HOSTNAME" ]; then
    echo "✅ LoadBalancer hostname is provisioned: $LB_HOSTNAME"
    echo "Testing LoadBalancer hostname connectivity..."
    curl -s -I --connect-timeout 5 http://$LB_HOSTNAME || echo "LoadBalancer is still being set up (this is normal)"
    
    # Test with a GET request to see the actual response
    echo "Testing with regular GET request:"
    curl -s --connect-timeout 5 http://$LB_HOSTNAME | head -n 15 || echo "Could not get response content"
  elif [ ! -z "$LB_IP" ]; then
    echo "✅ LoadBalancer IP is provisioned: $LB_IP"
    echo "Testing LoadBalancer IP connectivity..."
    curl -s -I --connect-timeout 5 http://$LB_IP || echo "LoadBalancer is still being set up (this is normal)"
    
    # Test with a GET request to see the actual response
    echo "Testing with regular GET request:"
    curl -s --connect-timeout 5 http://$LB_IP | head -n 15 || echo "Could not get response content"
  else
    echo "⚠️ LoadBalancer hostname/IP not yet provisioned"
    echo "This is normal and may take 3-5 minutes after creation"
    echo "Current service status:"
    $KUBECTL_CMD describe svc ${APP_NAME}-service -n $NAMESPACE
  fi
else
  echo "❌ Service is not of type LoadBalancer!"
  echo "Current service type: $LB_TYPE"
  echo "Service details:"
  $KUBECTL_CMD describe svc ${APP_NAME}-service -n $NAMESPACE
fi

# Verify service configuration matches the app port
echo "Checking service port configuration..."
TARGET_PORT=$($KUBECTL_CMD get svc ${APP_NAME}-service -n $NAMESPACE -o jsonpath='{.spec.ports[0].targetPort}' 2>/dev/null)
if [ "$TARGET_PORT" == "$APP_PORT" ]; then
  echo "✅ Service targetPort ($TARGET_PORT) correctly matches application port ($APP_PORT)"
else
  echo "❌ Service targetPort ($TARGET_PORT) does not match application port ($APP_PORT)!"
  echo "This will cause connectivity issues. Updating service..."
  cat <<EOF | $KUBECTL_CMD apply -f -
apiVersion: v1
kind: Service
metadata:
  name: ${APP_NAME}-service
  namespace: ${NAMESPACE}
spec:
  type: LoadBalancer
  ports:
  - port: 80
    targetPort: $APP_PORT
  selector:
    app: ${APP_NAME}-generator
EOF
  echo "Service updated to use targetPort: $APP_PORT"
fi

# Check NodePort as fallback
NODE_PORT=$($KUBECTL_CMD get svc ${APP_NAME}-service -n $NAMESPACE -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)
if [ ! -z "$NODE_PORT" ]; then
  echo "✅ NodePort is available as fallback: $NODE_PORT"
  PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
  echo "Testing NodePort connectivity at http://$PUBLIC_IP:$NODE_PORT..."
  curl -s -I --connect-timeout 5 http://$PUBLIC_IP:$NODE_PORT || echo "NodePort not yet accessible (check security group rules)"
fi

# Check security group configuration for LoadBalancer
echo "Checking security group configuration..."
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
SECURITY_GROUP=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --query "Reservations[0].Instances[0].SecurityGroups[0].GroupId" --output text)

if [ ! -z "$SECURITY_GROUP" ]; then
  echo "Instance Security Group: $SECURITY_GROUP"
  echo "Checking HTTP port (80) access..."
  HTTP_RULE=$(aws ec2 describe-security-groups --group-ids $SECURITY_GROUP --query "SecurityGroups[0].IpPermissions[?FromPort==\`80\`]" --output text)
  if [ ! -z "$HTTP_RULE" ]; then
    echo "✅ HTTP port 80 is open in security group"
  else
    echo "❌ HTTP port 80 is not open!"
    echo "Adding HTTP rule to security group..."
    aws ec2 authorize-security-group-ingress \
      --group-id $SECURITY_GROUP \
      --protocol tcp \
      --port 80 \
      --cidr 0.0.0.0/0 || echo "Error adding rule, may already exist"
  fi
  
  if [ ! -z "$NODE_PORT" ]; then
    echo "Checking NodePort ($NODE_PORT) access..."
    NODE_RULE=$(aws ec2 describe-security-groups --group-ids $SECURITY_GROUP --query "SecurityGroups[0].IpPermissions[?FromPort==\`$NODE_PORT\`]" --output text)
    if [ ! -z "$NODE_RULE" ]; then
      echo "✅ NodePort $NODE_PORT is open in security group"
    else
      echo "❌ NodePort $NODE_PORT is not open!"
      echo "Adding NodePort rule to security group..."
      aws ec2 authorize-security-group-ingress \
        --group-id $SECURITY_GROUP \
        --protocol tcp \
        --port $NODE_PORT \
        --cidr 0.0.0.0/0 || echo "Error adding rule, may already exist"
    fi
  fi
else
  echo "❌ Could not get security group information"
fi

# Try direct port-forwarding to verify app is accessible
echo "Testing direct access to the application using port-forwarding..."
# Run port-forward in background
$KUBECTL_CMD port-forward $POD_NAME 8088:$APP_PORT -n $NAMESPACE &
PF_PID=$!
sleep 3

# Try to access app via port-forward
echo "Checking app via port-forward on http://localhost:8088..."
curl -s -I --connect-timeout 5 http://localhost:8088 || echo "App not accessible via port-forward"
curl -s --connect-timeout 5 http://localhost:8088 | head -n 10 || echo "Could not get app content"

# Kill port-forward process
kill $PF_PID 2>/dev/null || true

echo ""
echo "==== IMPORTANT NOTES ===="
echo "1. AWS LoadBalancer takes 3-5 minutes to become fully accessible after creation"
echo "2. If the application is not accessible through the LoadBalancer URL, try again in a few minutes"
echo "3. You can use the NodePort URL as a fallback during LoadBalancer provisioning"
echo ""

if [ ! -z "$LB_HOSTNAME" ]; then
  echo "LoadBalancer URL: http://$LB_HOSTNAME"
elif [ ! -z "$LB_IP" ]; then
  echo "LoadBalancer IP URL: http://$LB_IP"
else 
  echo "LoadBalancer still provisioning (check status again in a few minutes)"
fi

if [ ! -z "$NODE_PORT" ] && [ ! -z "$PUBLIC_IP" ]; then
  echo "NodePort URL (fallback): http://$PUBLIC_IP:$NODE_PORT"
fi

echo "==== Verification completed ====" 