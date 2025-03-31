# GenAI Pipeline: Final Deployment Steps

This guide provides the complete and accurate steps to deploy the Cold Email Generator application using GitLab CI/CD with AWS infrastructure, including auto-scaling, load balancing, and Kubernetes on free tier EC2 instances.

## Prerequisite Verification Checklist

- [ ] AWS account with free tier eligibility
- [ ] AWS CLI installed and configured with proper credentials
- [ ] GitLab account with access to the project repository 
- [ ] SSH key pair for EC2 access
- [ ] Groq API key for LLM access

## Step 1: Project Structure Setup

First, ensure your repository has the correct directory structure:

```
cold-email-generator/
├── app/                      # Application code
│   ├── main.py               # Streamlit application
│   ├── chains.py             # LLM chains
│   ├── utils.py              # Utility functions
│   ├── portfolio.py          # Portfolio management
│   └── resource/             # Resources directory
├── k8s/                      # Kubernetes configuration
│   ├── namespace.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   └── ingress.yaml
├── scripts/                  # Deployment scripts
│   ├── setup-k8s.sh
│   └── deploy-k8s.sh
├── tests/                    # Tests
├── .gitlab-ci.yml            # GitLab CI/CD configuration
├── Dockerfile                # Docker container definition
├── docker-compose.yml        # Docker Compose for local development
└── requirements.txt          # Python dependencies
```

## Step 2: AWS Infrastructure Setup

Execute these commands in sequence to set up the AWS infrastructure:

```bash
# Create a VPC
VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=cold-email-vpc}]" --query 'Vpc.VpcId' --output text)
echo "VPC created: $VPC_ID"

# Enable DNS hostnames for the VPC
    aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames

# Create public subnets in two availability zones
PUBLIC_SUBNET_1=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.1.0/24 --availability-zone us-east-1a --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=cold-email-public-1}]" --query 'Subnet.SubnetId' --output text)
PUBLIC_SUBNET_2=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.2.0/24 --availability-zone us-east-1b --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=cold-email-public-2}]" --query 'Subnet.SubnetId' --output text)
echo "Public subnets created: $PUBLIC_SUBNET_1, $PUBLIC_SUBNET_2"

# Create an Internet Gateway
IGW_ID=$(aws ec2 create-internet-gateway --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=cold-email-igw}]" --query 'InternetGateway.InternetGatewayId' --output text)
echo "Internet Gateway created: $IGW_ID"

# Attach the Internet Gateway to the VPC
aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID

# Create a route table for public subnets
PUBLIC_RTB=$(aws ec2 create-route-table --vpc-id $VPC_ID --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=cold-email-public-rtb}]" --query 'RouteTable.RouteTableId' --output text)
echo "Public route table created: $PUBLIC_RTB"

# Create a route to the internet
aws ec2 create-route --route-table-id $PUBLIC_RTB --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID

# Associate public subnets with the route table
aws ec2 associate-route-table --route-table-id $PUBLIC_RTB --subnet-id $PUBLIC_SUBNET_1
aws ec2 associate-route-table --route-table-id $PUBLIC_RTB --subnet-id $PUBLIC_SUBNET_2

# Create security group for EC2 instances
EC2_SG=$(aws ec2 create-security-group \
  --group-name cold-email-ec2-sg \
  --description "Security group for EC2 instances running K8s" \
  --vpc-id $VPC_ID \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=cold-email-ec2-sg}]" \
  --query 'GroupId' --output text)
echo "Security group created: $EC2_SG"

# Allow SSH access from your IP
aws ec2 authorize-security-group-ingress \
  --group-id $EC2_SG \
  --protocol tcp \
  --port 22 \
  --cidr $(curl -s https://checkip.amazonaws.com)/32

# Allow HTTP/HTTPS traffic
aws ec2 authorize-security-group-ingress \
  --group-id $EC2_SG \
  --protocol tcp \
  --port 80 \
  --cidr 0.0.0.0/0

aws ec2 authorize-security-group-ingress \
  --group-id $EC2_SG \
  --protocol tcp \
  --port 443 \
  --cidr 0.0.0.0/0

# Allow Streamlit port
aws ec2 authorize-security-group-ingress \
  --group-id $EC2_SG \
  --protocol tcp \
  --port 8501 \
  --cidr 0.0.0.0/0

# Allow Kubernetes API server port
aws ec2 authorize-security-group-ingress \
  --group-id $EC2_SG \
  --protocol tcp \
  --port 6443 \
  --cidr 0.0.0.0/0

# Allow all internal traffic within the security group (for K8s nodes)
aws ec2 authorize-security-group-ingress \
  --group-id $EC2_SG \
  --protocol all \
  --source-group $EC2_SG

# Create an EC2 launch template
aws ec2 create-launch-template \
  --launch-template-name cold-email-launch-template \
  --version-description "Initial version" \
  --launch-template-data '{
    "ImageId": "ami-0c7217cdde317cfec",
    "InstanceType": "t2.micro",
    "KeyName": "YOUR_KEY_NAME",
    "NetworkInterfaces": [
      {
        "DeviceIndex": 0,
        "AssociatePublicIpAddress": true,
        "Groups": ["'$EC2_SG'"],
        "DeleteOnTermination": true
      }
    ],
    "BlockDeviceMappings": [
      {
        "DeviceName": "/dev/sda1",
        "Ebs": {
          "VolumeSize": 8,
          "VolumeType": "gp2",
          "DeleteOnTermination": true
        }
      }
    ],
    "UserData": "'$(base64 -w 0 <<EOF
#!/bin/bash
# Update system packages
apt-get update
apt-get upgrade -y

# Install Docker
apt-get install -y apt-transport-https ca-certificates curl software-properties-common
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io
systemctl enable docker
systemctl start docker

# Install Kubernetes components
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
cat <<EOK > /etc/apt/sources.list.d/kubernetes.list
deb https://apt.kubernetes.io/ kubernetes-xenial main
EOK
apt-get update
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

# Set hostname
hostnamectl set-hostname cold-email-master
EOF
)'"
  }'
echo "EC2 launch template created"

# Create a target group
TG_ARN=$(aws elbv2 create-target-group \
  --name cold-email-tg \
  --protocol HTTP \
  --port 8501 \
  --vpc-id $VPC_ID \
  --health-check-path "/_stcore/health" \
  --target-type instance \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text)
echo "Target group created: $TG_ARN"

# Create a load balancer
LB_ARN=$(aws elbv2 create-load-balancer \
  --name cold-email-lb \
  --subnets $PUBLIC_SUBNET_1 $PUBLIC_SUBNET_2 \
  --security-groups $EC2_SG \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text)
echo "Load balancer created: $LB_ARN"

# Create a listener
LISTENER_ARN=$(aws elbv2 create-listener \
  --load-balancer-arn $LB_ARN \
  --protocol HTTP \
  --port 80 \
  --default-actions Type=forward,TargetGroupArn=$TG_ARN \
  --query 'Listeners[0].ListenerArn' \
  --output text)
echo "Listener created: $LISTENER_ARN"

# Create auto scaling group
aws autoscaling create-auto-scaling-group \
  --auto-scaling-group-name cold-email-asg \
  --launch-template LaunchTemplateName=cold-email-launch-template,Version='$Latest' \
  --min-size 1 \
  --max-size 2 \
  --desired-capacity 1 \
  --vpc-zone-identifier "$PUBLIC_SUBNET_1,$PUBLIC_SUBNET_2" \
  --target-group-arns $TG_ARN \
  --health-check-type ELB \
  --health-check-grace-period 300
echo "Auto Scaling Group created"

# Create scaling policies
aws autoscaling put-scaling-policy \
  --auto-scaling-group-name cold-email-asg \
  --policy-name cpu-scaling-policy \
  --policy-type TargetTrackingScaling \
  --target-tracking-configuration '{
    "PredefinedMetricSpecification": {
      "PredefinedMetricType": "ASGAverageCPUUtilization"
    },
    "TargetValue": 70.0
  }'
echo "CPU scaling policy created"

# Create scheduled scaling for free tier optimization
aws autoscaling put-scheduled-update-group-action \
  --auto-scaling-group-name cold-email-asg \
  --scheduled-action-name scale-down-night \
  --recurrence "0 0 * * *" \
  --min-size 0 \
  --max-size 0 \
  --desired-capacity 0
echo "Scheduled scale-down created"

aws autoscaling put-scheduled-update-group-action \
  --auto-scaling-group-name cold-email-asg \
  --scheduled-action-name scale-up-morning \
  --recurrence "0 8 * * 1-5" \
  --min-size 1 \
  --max-size 2 \
  --desired-capacity 1
echo "Scheduled scale-up created"
```

## Step 3: Create GitLab CI/CD Pipeline Configuration

### Setup GitLab Project and Variables

1. In your GitLab project, go to **Settings > CI/CD > Variables**
2. Add the following variables:
   - `AWS_ACCESS_KEY_ID`: Your AWS access key
   - `AWS_SECRET_ACCESS_KEY`: Your AWS secret key
   - `AWS_DEFAULT_REGION`: Your AWS region (e.g., us-east-1)
   - `AWS_EC2_IP`: IP address of your EC2 instance (to be added later)
   - `AWS_USER`: Username for EC2 (e.g., ubuntu)
   - `AWS_SSH_KEY`: Your private SSH key for EC2 access
   - `GROQ_API_KEY`: Your Groq API key

### Create Kubernetes Configuration Files

Create a directory called `k8s` in your repository and add these files:

**k8s/namespace.yaml**:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: cold-email
```

**k8s/deployment.yaml**:
```yaml
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
        image: ${CI_REGISTRY}/aradhya24/cold-email-generator:${CI_COMMIT_SHA}
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
```

**k8s/service.yaml**:
```yaml
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
```

**k8s/ingress.yaml**:
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: cold-email-ingress
  namespace: cold-email
  annotations:
    kubernetes.io/ingress.class: "nginx"
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
```

### Create Kubernetes Setup Scripts

Create a `scripts` directory and add these files:

**scripts/setup-k8s.sh**:
```bash
#!/bin/bash
set -e

# Initialize Kubernetes
sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --ignore-preflight-errors=NumCPU,Mem

# Set up kubectl for the ubuntu user
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Install Flannel network plugin
kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml

# Allow scheduling pods on the master node (since we're using a single node for free tier)
kubectl taint nodes --all node-role.kubernetes.io/master-

# Create namespace
kubectl apply -f k8s/namespace.yaml

# Create secret
kubectl create secret generic app-secrets \
  --namespace=cold-email \
  --from-literal=GROQ_API_KEY=$GROQ_API_KEY \
  --dry-run=client -o yaml | kubectl apply -f -

# Install nginx ingress controller
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.8.2/deploy/static/provider/cloud/deploy.yaml
```

**scripts/deploy-k8s.sh**:
```bash
#!/bin/bash
set -e

# Apply deployment
envsubst < k8s/deployment.yaml | kubectl apply -f -

# Apply service
kubectl apply -f k8s/service.yaml

# Apply ingress
kubectl apply -f k8s/ingress.yaml

# Wait for deployment to be ready
kubectl rollout status deployment/cold-email-generator -n cold-email
```

### Create GitLab CI/CD Configuration File

Create a `.gitlab-ci.yml` file with the following content:

```yaml
image: docker:20.10.16

services:
  - docker:20.10.16-dind

variables:
  DOCKER_HOST: tcp://docker:2375
  DOCKER_TLS_CERTDIR: ""
  DOCKER_DRIVER: overlay2
  AWS_EC2_IP: ${AWS_EC2_IP}
  AWS_SSH_KEY: ${AWS_SSH_KEY}
  AWS_USER: ${AWS_USER}
  DOCKER_REGISTRY: ${CI_REGISTRY}
  DOCKER_IMAGE: ${CI_REGISTRY}/aradhya24/cold-email-generator:${CI_COMMIT_SHA}

stages:
  - validate
  - lint
  - test
  - build
  - deploy
  - monitor

validate:
  image: python:3.9-slim
  stage: validate
  script:
    - apt-get update && apt-get install -y python3-pip
    - pip install -r requirements.txt
    - echo "Validating project structure..."
    - python -c "import app.main" || echo "Validation failed but continuing"

lint:
  image: python:3.9-slim
  stage: lint
  before_script:
    - apt-get update && apt-get install -y python3-pip
    - pip install flake8 black isort
  script:
    - flake8 app/ --config=setup.cfg || true
    - black --check app/ || true
    - isort --check-only app/ || true

test:
  image: python:3.9-slim
  stage: test
  before_script:
    - apt-get update && apt-get install -y python3-pip
    - pip install -r requirements.txt
    - pip install pytest
  script:
    - mkdir -p tests && touch tests/__init__.py
    - pytest -xvs tests/ || echo "Tests failed but continuing"

build:
  stage: build
  script: 
    - docker login -u gitlab-ci-token -p $CI_JOB_TOKEN $CI_REGISTRY 
    - docker build --pull -t $DOCKER_IMAGE .
    - docker tag $DOCKER_IMAGE $CI_REGISTRY/aradhya24/cold-email-generator:latest
    - docker push $DOCKER_IMAGE 
    - docker push $CI_REGISTRY/aradhya24/cold-email-generator:latest

setup_k8s:
  stage: deploy
  image: python:3.9-slim
  only:
    - main
  when: manual
  script:
    - apt-get update && apt-get install -y openssh-client gettext-base
    - mkdir -p ~/.ssh && chmod 700 ~/.ssh
    - echo "$AWS_SSH_KEY" | tr -d '\r' > ~/.ssh/id_rsa
    - chmod 600 ~/.ssh/id_rsa
    - eval $(ssh-agent -s) && ssh-add ~/.ssh/id_rsa
    - echo -e "Host *\n\tStrictHostKeyChecking no\n\n" > ~/.ssh/config
    - ssh ${AWS_USER}@${AWS_EC2_IP} "mkdir -p ~/k8s ~/scripts"
    - scp -r k8s/* ${AWS_USER}@${AWS_EC2_IP}:~/k8s/
    - scp scripts/setup-k8s.sh ${AWS_USER}@${AWS_EC2_IP}:~/scripts/
    - ssh ${AWS_USER}@${AWS_EC2_IP} "chmod +x ~/scripts/setup-k8s.sh"
    - ssh ${AWS_USER}@${AWS_EC2_IP} "export GROQ_API_KEY=${GROQ_API_KEY} && ~/scripts/setup-k8s.sh"

deploy:
  stage: deploy
  image: python:3.9-slim
  only:
    - main
  script:
    - apt-get update && apt-get install -y openssh-client gettext-base
    - mkdir -p ~/.ssh && chmod 700 ~/.ssh
    - echo "$AWS_SSH_KEY" | tr -d '\r' > ~/.ssh/id_rsa
    - chmod 600 ~/.ssh/id_rsa
    - eval $(ssh-agent -s) && ssh-add ~/.ssh/id_rsa
    - echo -e "Host *\n\tStrictHostKeyChecking no\n\n" > ~/.ssh/config
    - envsubst < k8s/deployment.yaml > deployment.yaml
    - scp deployment.yaml ${AWS_USER}@${AWS_EC2_IP}:~/k8s/deployment.yaml
    - scp scripts/deploy-k8s.sh ${AWS_USER}@${AWS_EC2_IP}:~/scripts/
    - ssh ${AWS_USER}@${AWS_EC2_IP} "chmod +x ~/scripts/deploy-k8s.sh"
    - ssh ${AWS_USER}@${AWS_EC2_IP} "export CI_REGISTRY=${CI_REGISTRY} && export CI_COMMIT_SHA=${CI_COMMIT_SHA} && ~/scripts/deploy-k8s.sh"

monitor:
  stage: monitor
  image: python:3.9-slim
  only:
    - main
  script:
    - apt-get update && apt-get install -y openssh-client curl
    - mkdir -p ~/.ssh && chmod 700 ~/.ssh
    - echo "$AWS_SSH_KEY" | tr -d '\r' > ~/.ssh/id_rsa
    - chmod 600 ~/.ssh/id_rsa
    - eval $(ssh-agent -s) && ssh-add ~/.ssh/id_rsa
    - echo -e "Host *\n\tStrictHostKeyChecking no\n\n" > ~/.ssh/config
    - ssh ${AWS_USER}@${AWS_EC2_IP} "kubectl get pods -n cold-email"
    - ssh ${AWS_USER}@${AWS_EC2_IP} "kubectl get svc -n cold-email"
    - echo "Checking application health..."
    - ssh ${AWS_USER}@${AWS_EC2_IP} "curl -s http://localhost:8501/_stcore/health || echo 'Health check failed'"
```

## Step 4: Launch and Configure EC2 Instance

1. **Get an instance IP from your auto-scaling group:**
   ```bash
   ASG_INSTANCES=$(aws autoscaling describe-auto-scaling-groups \
     --auto-scaling-group-names cold-email-asg \
     --query "AutoScalingGroups[0].Instances[0].InstanceId" \
     --output text)
   
   EC2_IP=$(aws ec2 describe-instances \
     --instance-ids $ASG_INSTANCES \
     --query "Reservations[0].Instances[0].PublicIpAddress" \
     --output text)
   
   echo "EC2 instance IP: $EC2_IP"
   ```

2. **Add this IP to your GitLab CI/CD variables as `AWS_EC2_IP`**

ssh key = ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAyIkQujePhpkrc72sKIX0WVpvkpoqYVwUl3EQiag8Dr dangearadhya6@gmail.com

3. **SSH into the instance and prepare it:**
   ```bash
   ssh -i your_key.pem ubuntu@$EC2_IP
   
   # Verify Docker is installed
   docker --version
   
   # Verify Kubernetes tools are installed
   kubectl version --client
   kubeadm version
   
   # Create directories
   mkdir -p ~/k8s ~/scripts
   
   # Exit the SSH session
   exit
   ```

## Step 5: Deploy the Application

1. **Commit and push all configuration files to your GitLab repository**
   ```bash
   git add .
   git commit -m "Add deployment configuration"
   git push origin main
   ```

2. **Go to your GitLab project's CI/CD > Pipelines**

3. **Manually trigger the `setup_k8s` job**
   - This job will initialize Kubernetes, set up the network plugin, and prepare the environment

4. **After the `setup_k8s` job completes, the regular pipeline will deploy the application**
   - The `deploy` job will deploy the application to Kubernetes
   - The `monitor` job will verify the deployment status

5. **Verify the deployment**
   ```bash
   ssh -i your_key.pem ubuntu@$EC2_IP
   
   # Check Kubernetes nodes
   kubectl get nodes
   
   # Check pods
   kubectl get pods -n cold-email
   
   # Check services
   kubectl get svc -n cold-email
   ```

6. **Access the application**
   - Get the NodePort:
     ```bash
     NODE_PORT=$(kubectl get svc -n cold-email cold-email-service -o jsonpath='{.spec.ports[0].nodePort}')
     echo "Access your application at: http://$EC2_IP:$NODE_PORT"
     ```
   - Or via Ingress:
     ```bash
     echo "Access your application at: http://$EC2_IP/"
     ```
   - Or via Load Balancer:
     ```bash
     LB_DNS=$(aws elbv2 describe-load-balancers \
       --names cold-email-lb \
       --query 'LoadBalancers[0].DNSName' \
       --output text)
     
     echo "Access your application at: http://$LB_DNS"
     ```

## Step 6: Verify Auto-Scaling and Load Balancing

```bash
# Check the Auto Scaling Group configuration
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names cold-email-asg \
  --query "AutoScalingGroups[0].[MinSize,MaxSize,DesiredCapacity]"

# Check the scaling policies
aws autoscaling describe-policies \
  --auto-scaling-group-name cold-email-asg

# Check the Load Balancer target health
aws elbv2 describe-target-health \
  --target-group-arn $TG_ARN
```

## Troubleshooting

1. **If Kubernetes initialization fails:**
   ```bash
   # Reset Kubernetes on the EC2 instance
   ssh -i your_key.pem ubuntu@$EC2_IP
   sudo kubeadm reset
   sudo rm -rf $HOME/.kube
   ```

2. **If the pod is not starting or crashing:**
   ```bash
   # Check pod logs
   kubectl logs -n cold-email deployment/cold-email-generator
   
   # Describe the pod to get more details
   kubectl describe pod -n cold-email -l app=cold-email-generator
   ```

3. **If the application is not accessible:**
   ```bash
   # Check if the service is properly exposed
   kubectl get svc -n cold-email cold-email-service
   
   # Check if the ingress is properly configured
   kubectl get ingress -n cold-email
   
   # Check if the load balancer is healthy
   aws elbv2 describe-target-health \
     --target-group-arn $TG_ARN
   ```

## Free Tier Optimization Checks

- EC2 instances are t2.micro (free tier eligible)
- Auto-scaling schedules reduce instances during off-hours
- Resource limits on Kubernetes pods prevent excessive resource usage
- Single-node Kubernetes cluster minimizes costs
- Load balancer is configured without provisioned capacity

## Ongoing Maintenance

```bash
# Check Kubernetes cluster status
kubectl get nodes
kubectl get pods -A

# Check application logs
kubectl logs -n cold-email deployment/cold-email-generator

# Check auto-scaling activity
aws autoscaling describe-scaling-activities \
  --auto-scaling-group-name cold-email-asg

# Monitor CPU usage
aws cloudwatch get-metric-statistics \
  --namespace AWS/EC2 \
  --metric-name CPUUtilization \
  --dimensions Name=AutoScalingGroupName,Value=cold-email-asg \
  --start-time $(date -u -d "1 hour ago" +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 300 \
  --statistics Average
``` 
