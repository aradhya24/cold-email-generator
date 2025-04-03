#!/bin/bash
# Kubernetes setup script for cold email generator application

set -e

echo "====== Kubernetes Setup for Cold Email Generator ======"

# Initialize Kubernetes with pod network CIDR for Flannel
echo "Initializing Kubernetes cluster..."
sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --ignore-preflight-errors=NumCPU,Mem

# Set up kubectl for the ubuntu user
echo "Setting up kubectl configuration..."
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Install Flannel CNI network plugin
echo "Installing Flannel CNI network plugin..."
kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml

# Allow scheduling pods on the master node (for single-node free tier setup)
echo "Allowing pods to be scheduled on the master node..."
kubectl taint nodes --all node-role.kubernetes.io/master- || true
kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true

# Create the application namespace
echo "Creating application namespace..."
cat > namespace.yaml << EOF
apiVersion: v1
kind: Namespace
metadata:
  name: cold-email
EOF

kubectl apply -f namespace.yaml

# Create a secret for the Groq API key
if [ -n "$GROQ_API_KEY" ]; then
  echo "Creating secret for Groq API key..."
  kubectl create secret generic app-secrets \
    --namespace=cold-email \
    --from-literal=GROQ_API_KEY=$GROQ_API_KEY \
    --dry-run=client -o yaml | kubectl apply -f -
else
  echo "GROQ_API_KEY environment variable not set. Please set it and create the secret manually."
fi

# Install NGINX Ingress Controller
echo "Installing NGINX Ingress Controller..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.2/deploy/static/provider/cloud/deploy.yaml

# Wait for ingress controller to be ready
echo "Waiting for Ingress controller to be ready..."
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s || echo "Ingress controller pods still not ready, proceeding anyway"

# Create Kubernetes manifests directory
echo "Creating Kubernetes manifests directory..."
mkdir -p $HOME/k8s

# Create deployment manifest
echo "Creating deployment manifest..."
cat > $HOME/k8s/deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cold-email-generator
  namespace: cold-email
spec:
  replicas: 2
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
        ports:
        - containerPort: 8501
        env:
        - name: GROQ_API_KEY
          valueFrom:
            secretKeyRef:
              name: app-secrets
              key: GROQ_API_KEY
        - name: USER_AGENT
          value: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
        # Add load balancer DNS as environment variable
        - name: LB_DNS
          value: "${LB_DNS}"
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "500m"
        readinessProbe:
          httpGet:
            path: /_stcore/health
            port: 8501
          initialDelaySeconds: 10
          periodSeconds: 5
EOF

# Create service manifest
echo "Creating service manifest..."
cat > $HOME/k8s/service.yaml << 'EOF'
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
    name: http
  type: NodePort
EOF

# Create ingress manifest
echo "Creating ingress manifest..."
cat > $HOME/k8s/ingress.yaml << 'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: cold-email-ingress
  namespace: cold-email
  annotations:
    kubernetes.io/ingress.class: "nginx"
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
spec:
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

echo "Kubernetes setup completed successfully!"
echo "Ready to deploy the application." 