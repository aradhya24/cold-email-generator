#!/bin/bash
# Script to verify and troubleshoot Cold Email Generator application access

set -e

APP_NAME=${APP_NAME:-cold-email}
NAMESPACE=${NAMESPACE:-$APP_NAME}
KUBECTL_CMD="k3s kubectl"

echo "===== Verifying Cold Email Generator Application Access ====="

# Check if the pod exists and is running
echo "Checking pod status..."
POD_NAME=$($KUBECTL_CMD get pods -n $NAMESPACE -l app=${APP_NAME}-generator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -z "$POD_NAME" ]; then
  echo "❌ No pods found! Checking for deployment issues..."
  $KUBECTL_CMD describe deployment ${APP_NAME}-generator -n $NAMESPACE
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
        image: nginx
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
  else
    echo "❌ Pod $POD_NAME is not running (status: $POD_STATUS)"
    echo "Pod details:"
    $KUBECTL_CMD describe pod $POD_NAME -n $NAMESPACE
    echo "Pod logs:"
    $KUBECTL_CMD logs $POD_NAME -n $NAMESPACE
    exit 1
  fi
fi

# Check service configuration
echo "Checking service configuration..."
SERVICE_TYPE=$($KUBECTL_CMD get svc ${APP_NAME}-service -n $NAMESPACE -o jsonpath='{.spec.type}' 2>/dev/null)
NODE_PORT=$($KUBECTL_CMD get svc ${APP_NAME}-service -n $NAMESPACE -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)
TARGET_PORT=$($KUBECTL_CMD get svc ${APP_NAME}-service -n $NAMESPACE -o jsonpath='{.spec.ports[0].targetPort}' 2>/dev/null)

if [ -z "$SERVICE_TYPE" ]; then
  echo "❌ Service not found!"
  echo "Creating service manually..."
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
    targetPort: 3000
  selector:
    app: ${APP_NAME}-generator
EOF
  sleep 10
  NODE_PORT=$($KUBECTL_CMD get svc ${APP_NAME}-service -n $NAMESPACE -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null)
  echo "Service created with NodePort: $NODE_PORT"
else
  echo "✅ Service is configured: $SERVICE_TYPE $NODE_PORT $TARGET_PORT"
fi

# Check if application is responding inside the pod
echo "Checking if application is responding inside the pod..."
echo "Testing connectivity to pod $POD_NAME directly..."
$KUBECTL_CMD port-forward $POD_NAME -n $NAMESPACE 8080:3000 &
PF_PID=$!
sleep 5

# Try to kill the port-forward process gracefully when the script exits
trap "kill $PF_PID 2>/dev/null || true" EXIT

# Check application inside container
echo "Checking port 3000 inside the container..."
$KUBECTL_CMD exec $POD_NAME -n $NAMESPACE -- sh -c "nc -zv localhost 3000 || echo 'Port not open'"

echo "Checking what processes are running inside container..."
$KUBECTL_CMD exec $POD_NAME -n $NAMESPACE -- sh -c "ps aux"

echo "Checking container environment variables..."
$KUBECTL_CMD exec $POD_NAME -n $NAMESPACE -- sh -c "env | grep -E 'PORT|HOST|NODE'"

echo "Checking container networking..."
$KUBECTL_CMD exec $POD_NAME -n $NAMESPACE -- sh -c "netstat -tulpn || echo 'netstat not available'"

echo "Checking container logs..."
$KUBECTL_CMD logs $POD_NAME -n $NAMESPACE

# Test connecting directly to NodePort
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
if [ ! -z "$NODE_PORT" ]; then
  echo "Testing NodePort directly at $PUBLIC_IP:$NODE_PORT..."
  curl -v --connect-timeout 5 http://$PUBLIC_IP:$NODE_PORT || echo "NodePort not accessible"
fi

# Check security group configuration
echo "Checking EC2 security group..."
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
aws ec2 describe-instance-attribute --instance-id $INSTANCE_ID --attribute groupSet

echo "==== Verification completed ====" 