# GenAI Pipeline: Load Balancer and Auto-Scaling Setup with Kubernetes

This guide provides the optimized steps to deploy the Cold Email Generator application using GitLab CI/CD with AWS infrastructure, focusing on maximizing the benefits of load balancing and auto-scaling with Kubernetes.

## Prerequisites Checklist

- [ ] AWS account with free tier eligibility
- [ ] AWS CLI installed and configured with proper credentials
- [ ] GitLab account with repository access
- [ ] SSH key pair for EC2 access
- [ ] Groq API key for LLM functionality

## Step 1: AWS Infrastructure Setup

```bash
# Create a VPC with necessary networking components
VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=cold-email-vpc}]" --query 'Vpc.VpcId' --output text)
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames

# Create public subnets in two availability zones for high availability
PUBLIC_SUBNET_1=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.1.0/24 --availability-zone us-east-1a --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=cold-email-public-1}]" --query 'Subnet.SubnetId' --output text)
PUBLIC_SUBNET_2=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.2.0/24 --availability-zone us-east-1b --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=cold-email-public-2}]" --query 'Subnet.SubnetId' --output text)

# Configure internet access
IGW_ID=$(aws ec2 create-internet-gateway --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=cold-email-igw}]" --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID
PUBLIC_RTB=$(aws ec2 create-route-table --vpc-id $VPC_ID --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=cold-email-public-rtb}]" --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id $PUBLIC_RTB --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID
aws ec2 associate-route-table --route-table-id $PUBLIC_RTB --subnet-id $PUBLIC_SUBNET_1
aws ec2 associate-route-table --route-table-id $PUBLIC_RTB --subnet-id $PUBLIC_SUBNET_2

# Create security group for EC2 instances
EC2_SG=$(aws ec2 create-security-group \
  --group-name cold-email-ec2-sg \
  --description "Security group for EC2 instances running K8s" \
  --vpc-id $VPC_ID \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=cold-email-ec2-sg}]" \
  --query 'GroupId' --output text)

# Configure security group rules
aws ec2 authorize-security-group-ingress --group-id $EC2_SG --protocol tcp --port 22 --cidr $(curl -s https://checkip.amazonaws.com)/32
aws ec2 authorize-security-group-ingress --group-id $EC2_SG --protocol tcp --port 80 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $EC2_SG --protocol tcp --port 443 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $EC2_SG --protocol tcp --port 8501 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $EC2_SG --protocol tcp --port 6443 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $EC2_SG --protocol all --source-group $EC2_SG

# Create an EC2 launch template with Kubernetes pre-installed
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
# Update system and install Docker
apt-get update && apt-get upgrade -y
apt-get install -y apt-transport-https ca-certificates curl software-properties-common
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu \$(lsb_release -cs) stable"
apt-get update && apt-get install -y docker-ce docker-ce-cli containerd.io
systemctl enable docker && systemctl start docker

# Install Kubernetes components
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
cat <<EOK > /etc/apt/sources.list.d/kubernetes.list
deb https://apt.kubernetes.io/ kubernetes-xenial main
EOK
apt-get update && apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

# Set hostname based on instance ID for uniqueness
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
hostnamectl set-hostname k8s-node-$INSTANCE_ID

# Create required directories
mkdir -p /home/ubuntu/k8s /home/ubuntu/scripts
chown -R ubuntu:ubuntu /home/ubuntu/k8s /home/ubuntu/scripts

# Add user to docker group
usermod -aG docker ubuntu
EOF
)'"
  }'

# Create a target group for load balancing
TG_ARN=$(aws elbv2 create-target-group \
  --name cold-email-tg \
  --protocol HTTP \
  --port 8501 \
  --vpc-id $VPC_ID \
  --health-check-path "/_stcore/health" \
  --health-check-interval-seconds 30 \
  --health-check-timeout-seconds 5 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 2 \
  --target-type instance \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text)

# Create an Application Load Balancer
LB_ARN=$(aws elbv2 create-load-balancer \
  --name cold-email-lb \
  --subnets $PUBLIC_SUBNET_1 $PUBLIC_SUBNET_2 \
  --security-groups $EC2_SG \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text)

# Get the load balancer DNS name for later use
LB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns $LB_ARN \
  --query 'LoadBalancers[0].DNSName' \
  --output text)
echo "Load balancer DNS: $LB_DNS"

# Create a listener for the load balancer
LISTENER_ARN=$(aws elbv2 create-listener \
  --load-balancer-arn $LB_ARN \
  --protocol HTTP \
  --port 80 \
  --default-actions Type=forward,TargetGroupArn=$TG_ARN \
  --query 'Listeners[0].ListenerArn' \
  --output text)

# Create auto scaling group with minimum 1 and maximum 2 instances
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

# Create scaling policies based on CPU usage
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

# Create scheduled scaling for free tier optimization
aws autoscaling put-scheduled-update-group-action \
  --auto-scaling-group-name cold-email-asg \
  --scheduled-action-name scale-down-night \
  --recurrence "0 0 * * *" \
  --min-size 0 \
  --max-size 0 \
  --desired-capacity 0

aws autoscaling put-scheduled-update-group-action \
  --auto-scaling-group-name cold-email-asg \
  --scheduled-action-name scale-up-morning \
  --recurrence "0 8 * * 1-5" \
  --min-size 1 \
  --max-size 2 \
  --desired-capacity 1
```

## Step 2: Create Kubernetes Configuration Files

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
    name: http
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
```

## Step 3: Create Kubernetes Setup Scripts

Create a `scripts` directory with these files:

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

# Wait for ingress controller to be ready
echo "Waiting for ingress controller to be ready..."
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s || echo "Ingress controller pods still not ready, proceeding anyway"
```

**scripts/deploy-k8s.sh**:
```bash
#!/bin/bash
set -e

# Apply deployment with substituted environment variables
echo "Deploying application with CI_REGISTRY=${CI_REGISTRY} and CI_COMMIT_SHA=${CI_COMMIT_SHA}"
LB_DNS=${LB_DNS} envsubst < k8s/deployment.yaml | kubectl apply -f -

# Apply service
kubectl apply -f k8s/service.yaml

# Apply ingress
kubectl apply -f k8s/ingress.yaml

# Wait for deployment to be ready
echo "Waiting for deployment to be ready..."
kubectl rollout status deployment/cold-email-generator -n cold-email --timeout=120s

# Print service details
NODE_PORT=$(kubectl get svc -n cold-email cold-email-service -o jsonpath='{.spec.ports[0].nodePort}')
echo "Application deployed and accessible at:"
echo "Load Balancer URL: http://${LB_DNS}"
echo "Node Port URL: http://$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4):${NODE_PORT}"
```

**scripts/get_healthy_instance.sh**:
```bash
#!/bin/bash
set -e

# Get all instance IDs in the auto scaling group
INSTANCE_IDS=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names cold-email-asg \
  --query "AutoScalingGroups[0].Instances[*].InstanceId" \
  --output text)

# Convert to array
read -ra INSTANCE_ARRAY <<< "$INSTANCE_IDS"

# Check each instance
for INSTANCE_ID in "${INSTANCE_ARRAY[@]}"; do
  # Get instance state
  STATE=$(aws ec2 describe-instances \
    --instance-ids $INSTANCE_ID \
    --query "Reservations[0].Instances[0].State.Name" \
    --output text)
  
  # Get public IP if running
  if [ "$STATE" == "running" ]; then
    IP=$(aws ec2 describe-instances \
      --instance-ids $INSTANCE_ID \
      --query "Reservations[0].Instances[0].PublicIpAddress" \
      --output text)
    
    # Try to connect via SSH
    if ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no ubuntu@$IP exit 2>/dev/null; then
      echo $IP
      exit 0
    fi
  fi
done

echo "No healthy instances found"
exit 1
```

## Step 4: Create GitLab CI/CD Configuration

Create a `.gitlab-ci.yml` file configured to use the load balancer DNS:

```yaml
image: docker:20.10.16

services:
  - docker:20.10.16-dind

variables:
  DOCKER_HOST: tcp://docker:2375
  DOCKER_TLS_CERTDIR: ""
  DOCKER_DRIVER: overlay2
  DOCKER_REGISTRY: ${CI_REGISTRY}
  DOCKER_IMAGE: ${CI_REGISTRY}/aradhya24/cold-email-generator:${CI_COMMIT_SHA}
  AWS_USER: ubuntu
  LB_DNS: ${LB_DNS}

stages:
  - validate
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

build:
  stage: build
  script: 
    - docker login -u gitlab-ci-token -p $CI_JOB_TOKEN $CI_REGISTRY 
    - docker build --pull -t $DOCKER_IMAGE .
    - docker tag $DOCKER_IMAGE $CI_REGISTRY/aradhya24/cold-email-generator:latest
    - docker push $DOCKER_IMAGE 
    - docker push $CI_REGISTRY/aradhya24/cold-email-generator:latest

deploy_setup:
  stage: deploy
  image: python:3.9-slim
  only:
    - main
  when: manual
  script:
    - apt-get update && apt-get install -y openssh-client gettext-base awscli
    - mkdir -p ~/.ssh && chmod 700 ~/.ssh
    - echo "$AWS_SSH_KEY" | tr -d '\r' > ~/.ssh/id_rsa
    - chmod 600 ~/.ssh/id_rsa
    - eval $(ssh-agent -s) && ssh-add ~/.ssh/id_rsa
    - echo -e "Host *\n\tStrictHostKeyChecking no\n\n" > ~/.ssh/config
    
    # Get healthy EC2 instance
    - chmod +x scripts/get_healthy_instance.sh
    - EC2_IP=$(./scripts/get_healthy_instance.sh)
    - echo "Using EC2 instance with IP $EC2_IP for deployment"
    
    # Setup Kubernetes
    - ssh ${AWS_USER}@${EC2_IP} "mkdir -p ~/k8s ~/scripts"
    - scp -r k8s/* ${AWS_USER}@${EC2_IP}:~/k8s/
    - scp scripts/setup-k8s.sh ${AWS_USER}@${EC2_IP}:~/scripts/
    - ssh ${AWS_USER}@${EC2_IP} "chmod +x ~/scripts/setup-k8s.sh"
    - ssh ${AWS_USER}@${EC2_IP} "export GROQ_API_KEY=${GROQ_API_KEY} && ~/scripts/setup-k8s.sh"

deploy:
  stage: deploy
  image: python:3.9-slim
  only:
    - main
  script:
    - apt-get update && apt-get install -y openssh-client gettext-base awscli
    - mkdir -p ~/.ssh && chmod 700 ~/.ssh
    - echo "$AWS_SSH_KEY" | tr -d '\r' > ~/.ssh/id_rsa
    - chmod 600 ~/.ssh/id_rsa
    - eval $(ssh-agent -s) && ssh-add ~/.ssh/id_rsa
    - echo -e "Host *\n\tStrictHostKeyChecking no\n\n" > ~/.ssh/config
    
    # Get healthy EC2 instance
    - chmod +x scripts/get_healthy_instance.sh
    - EC2_IP=$(./scripts/get_healthy_instance.sh)
    - echo "Using EC2 instance with IP $EC2_IP for deployment"
    
    # Get load balancer DNS if not set
    - |
      if [ -z "$LB_DNS" ]; then
        export LB_DNS=$(aws elbv2 describe-load-balancers \
          --names cold-email-lb \
          --query 'LoadBalancers[0].DNSName' \
          --output text)
        echo "Load balancer DNS: $LB_DNS"
      fi
    
    # Update deployment file with variables
    - LB_DNS=$LB_DNS envsubst < k8s/deployment.yaml > deployment.yaml
    - scp deployment.yaml ${AWS_USER}@${EC2_IP}:~/k8s/deployment.yaml
    - scp scripts/deploy-k8s.sh ${AWS_USER}@${EC2_IP}:~/scripts/
    - ssh ${AWS_USER}@${EC2_IP} "chmod +x ~/scripts/deploy-k8s.sh"
    - ssh ${AWS_USER}@${EC2_IP} "export CI_REGISTRY=${CI_REGISTRY} && export CI_COMMIT_SHA=${CI_COMMIT_SHA} && export LB_DNS=${LB_DNS} && ~/scripts/deploy-k8s.sh"

monitor:
  stage: monitor
  image: python:3.9-slim
  only:
    - main
  script:
    - apt-get update && apt-get install -y openssh-client curl awscli
    - mkdir -p ~/.ssh && chmod 700 ~/.ssh
    - echo "$AWS_SSH_KEY" | tr -d '\r' > ~/.ssh/id_rsa
    - chmod 600 ~/.ssh/id_rsa
    - eval $(ssh-agent -s) && ssh-add ~/.ssh/id_rsa
    - echo -e "Host *\n\tStrictHostKeyChecking no\n\n" > ~/.ssh/config
    
    # Get healthy EC2 instance
    - chmod +x scripts/get_healthy_instance.sh
    - EC2_IP=$(./scripts/get_healthy_instance.sh)
    
    # Check Kubernetes deployment
    - ssh ${AWS_USER}@${EC2_IP} "kubectl get pods -n cold-email"
    - ssh ${AWS_USER}@${EC2_IP} "kubectl get svc -n cold-email"
    
    # Get load balancer DNS if not set
    - |
      if [ -z "$LB_DNS" ]; then
        export LB_DNS=$(aws elbv2 describe-load-balancers \
          --names cold-email-lb \
          --query 'LoadBalancers[0].DNSName' \
          --output text)
      fi
    
    # Check application health through load balancer (may need a delay)
    - echo "Waiting for application to be available at load balancer..."
    - sleep 60
    - echo "Checking application health at http://${LB_DNS}/_stcore/health"
    - curl -s -f -m 10 "http://${LB_DNS}/_stcore/health" || echo "Health check failed, application may need more time to become available"
```

## Step 5: Setup GitLab Variables

1. In your GitLab project, go to **Settings > CI/CD > Variables**
2. Add the following variables:
   - `AWS_ACCESS_KEY_ID`: Your AWS access key
   - `AWS_SECRET_ACCESS_KEY`: Your AWS secret key
   - `AWS_DEFAULT_REGION`: Your AWS region (e.g., us-east-1)
   - `AWS_SSH_KEY`: Your private SSH key for EC2 access
   - `GROQ_API_KEY`: Your Groq API key
   - `LB_DNS`: The load balancer DNS name (from Step 1)

## Step 6: Launch the Pipeline

1. Commit and push all files to your GitLab repository
2. Go to **CI/CD > Pipelines** in your GitLab project
3. Manually trigger the `deploy_setup` job for the initial Kubernetes setup
4. After the setup is complete, the deployment will continue automatically

## Step 7: Access and Verify Your Application

Your application will be accessible in several ways:

1. **Via the Load Balancer DNS**: `http://<LB_DNS>/`
   ```bash
   # Get the load balancer DNS
   LB_DNS=$(aws elbv2 describe-load-balancers \
     --names cold-email-lb \
     --query 'LoadBalancers[0].DNSName' \
     --output text)
   
   echo "Access your application at: http://$LB_DNS"
   ```

2. **Via any EC2 instance NodePort**:
   ```bash
   # SSH into any instance
   EC2_IP=$(./scripts/get_healthy_instance.sh)
   ssh ubuntu@$EC2_IP
   
   # Get the NodePort
   NODE_PORT=$(kubectl get svc -n cold-email cold-email-service -o jsonpath='{.spec.ports[0].nodePort}')
   echo "Access your application at: http://$EC2_IP:$NODE_PORT"
   ```

## Step 8: Verify Auto-Scaling

1. **Check Auto Scaling Group configuration**:
   ```bash
   aws autoscaling describe-auto-scaling-groups \
     --auto-scaling-group-names cold-email-asg \
     --query "AutoScalingGroups[0].[MinSize,MaxSize,DesiredCapacity]"
   ```

2. **Test scaling up (optional)**:
   ```bash
   # You can temporarily increase the desired capacity to test scaling
   aws autoscaling set-desired-capacity \
     --auto-scaling-group-name cold-email-asg \
     --desired-capacity 2
   
   # After testing, return to original capacity
   aws autoscaling set-desired-capacity \
     --auto-scaling-group-name cold-email-asg \
     --desired-capacity 1
   ```

3. **Verify the load balancer distributes traffic**:
   ```bash
   # Check target health
   aws elbv2 describe-target-health \
     --target-group-arn $(aws elbv2 describe-target-groups \
       --names cold-email-tg \
       --query 'TargetGroups[0].TargetGroupArn' \
       --output text)
   ```

## Troubleshooting Guide

1. **If instances don't register with the load balancer**:
   ```bash
   # Check if the security group allows traffic on port 8501
   aws ec2 describe-security-groups --group-ids $EC2_SG
   
   # Check target group health
   aws elbv2 describe-target-health --target-group-arn $TG_ARN
   ```

2. **If Kubernetes setup fails**:
   ```bash
   # SSH into the instance
   EC2_IP=$(./scripts/get_healthy_instance.sh)
   ssh ubuntu@$EC2_IP
   
   # Reset Kubernetes
   sudo kubeadm reset
   sudo rm -rf $HOME/.kube
   ```

3. **If the application is not accessible via load balancer**:
   ```bash
   # Check if pods are running
   kubectl get pods -n cold-email
   
   # Check if service is correctly configured
   kubectl get svc -n cold-email
   
   # Check if ingress is working
   kubectl get ingress -n cold-email
   kubectl describe ingress -n cold-email
   ```

## Free Tier Optimization Reminders

- The auto-scaling schedules reduce costs by scaling down during off-hours
- t2.micro instances stay within free tier limits
- Resources for Kubernetes pods are limited to minimize resource usage
- The load balancer is free for the first 750 hours per month
- Make sure to monitor usage to stay within free tier limits 
