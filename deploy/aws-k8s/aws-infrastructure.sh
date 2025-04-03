#!/bin/bash
# AWS Infrastructure Setup Script for Cold Email Generator

# Exit on error
set -e

# Define variables
AWS_REGION=${AWS_REGION:-"us-east-1"}
VPC_CIDR="10.0.0.0/16"
PUBLIC_SUBNET_1_CIDR="10.0.1.0/24"
PUBLIC_SUBNET_2_CIDR="10.0.2.0/24"
EC2_TYPE="t2.micro"
KEY_NAME=${KEY_NAME:-"cold-email-generator"}  # Replace with your SSH key name
APP_NAME="cold-email"

echo "Setting up AWS infrastructure for Cold Email Generator..."

# Step 1: Create VPC and networking components
echo "Creating VPC..."
VPC_ID=$(aws ec2 create-vpc --cidr-block $VPC_CIDR \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${APP_NAME}-vpc}]" \
  --query 'Vpc.VpcId' --output text)
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames

echo "Creating public subnets..."
PUBLIC_SUBNET_1=$(aws ec2 create-subnet --vpc-id $VPC_ID \
  --cidr-block $PUBLIC_SUBNET_1_CIDR --availability-zone ${AWS_REGION}a \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${APP_NAME}-public-1}]" \
  --query 'Subnet.SubnetId' --output text)
PUBLIC_SUBNET_2=$(aws ec2 create-subnet --vpc-id $VPC_ID \
  --cidr-block $PUBLIC_SUBNET_2_CIDR --availability-zone ${AWS_REGION}b \
  --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${APP_NAME}-public-2}]" \
  --query 'Subnet.SubnetId' --output text)

echo "Setting up internet access..."
IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${APP_NAME}-igw}]" \
  --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID

PUBLIC_RTB=$(aws ec2 create-route-table --vpc-id $VPC_ID \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${APP_NAME}-public-rtb}]" \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id $PUBLIC_RTB --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID
aws ec2 associate-route-table --route-table-id $PUBLIC_RTB --subnet-id $PUBLIC_SUBNET_1
aws ec2 associate-route-table --route-table-id $PUBLIC_RTB --subnet-id $PUBLIC_SUBNET_2

# Step 2: Create security group
echo "Creating security group..."
EC2_SG=$(aws ec2 create-security-group \
  --group-name ${APP_NAME}-ec2-sg \
  --description "Security group for EC2 instances running K8s" \
  --vpc-id $VPC_ID \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${APP_NAME}-ec2-sg}]" \
  --query 'GroupId' --output text)

echo "Configuring security group rules..."
aws ec2 authorize-security-group-ingress --group-id $EC2_SG --protocol tcp --port 22 --cidr $(curl -s https://checkip.amazonaws.com)/32
aws ec2 authorize-security-group-ingress --group-id $EC2_SG --protocol tcp --port 80 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $EC2_SG --protocol tcp --port 443 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $EC2_SG --protocol tcp --port 8501 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $EC2_SG --protocol tcp --port 6443 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $EC2_SG --protocol all --source-group $EC2_SG

# Step 3: Create EC2 launch template with Kubernetes pre-installed
echo "Creating launch template..."
ENCODED_USER_DATA=$(cat << 'EOF' | base64 -w 0
#!/bin/bash
# Update system and install Docker
apt-get update && apt-get upgrade -y
apt-get install -y apt-transport-https ca-certificates curl software-properties-common
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
apt-get update && apt-get install -y docker-ce docker-ce-cli containerd.io
systemctl enable docker && systemctl start docker

# Install Kubernetes components
curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
cat << EOK > /etc/apt/sources.list.d/kubernetes.list
deb https://apt.kubernetes.io/ kubernetes-xenial main
EOK
apt-get update && apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

# Set hostname based on instance ID for uniqueness
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
hostnamectl set-hostname k8s-node-$INSTANCE_ID

# Disable swap (required for Kubernetes)
swapoff -a
sed -i '/swap/s/^/#/' /etc/fstab

# Create required directories
mkdir -p /home/ubuntu/k8s /home/ubuntu/scripts
chown -R ubuntu:ubuntu /home/ubuntu/k8s /home/ubuntu/scripts

# Add user to docker group
usermod -aG docker ubuntu
EOF
)

aws ec2 create-launch-template \
  --launch-template-name ${APP_NAME}-launch-template \
  --version-description "Initial version with K8s pre-installed" \
  --launch-template-data "{
    \"ImageId\": \"ami-0c7217cdde317cfec\",
    \"InstanceType\": \"$EC2_TYPE\",
    \"KeyName\": \"$KEY_NAME\",
    \"NetworkInterfaces\": [
      {
        \"DeviceIndex\": 0,
        \"AssociatePublicIpAddress\": true,
        \"Groups\": [\"$EC2_SG\"],
        \"DeleteOnTermination\": true
      }
    ],
    \"BlockDeviceMappings\": [
      {
        \"DeviceName\": \"/dev/sda1\",
        \"Ebs\": {
          \"VolumeSize\": 8,
          \"VolumeType\": \"gp2\",
          \"DeleteOnTermination\": true
        }
      }
    ],
    \"UserData\": \"$ENCODED_USER_DATA\",
    \"TagSpecifications\": [
      {
        \"ResourceType\": \"instance\",
        \"Tags\": [
          {
            \"Key\": \"Name\",
            \"Value\": \"${APP_NAME}-k8s-node\"
          }
        ]
      }
    ]
  }"

# Step 4: Create a load balancer and target group
echo "Creating target group..."
TG_ARN=$(aws elbv2 create-target-group \
  --name ${APP_NAME}-tg \
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

echo "Creating application load balancer..."
LB_ARN=$(aws elbv2 create-load-balancer \
  --name ${APP_NAME}-lb \
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

echo "Creating ALB listener..."
LISTENER_ARN=$(aws elbv2 create-listener \
  --load-balancer-arn $LB_ARN \
  --protocol HTTP \
  --port 80 \
  --default-actions Type=forward,TargetGroupArn=$TG_ARN \
  --query 'Listeners[0].ListenerArn' \
  --output text)

# Step 5: Create auto scaling group
echo "Creating auto scaling group..."
aws autoscaling create-auto-scaling-group \
  --auto-scaling-group-name ${APP_NAME}-asg \
  --launch-template LaunchTemplateName=${APP_NAME}-launch-template,Version='$Latest' \
  --min-size 1 \
  --max-size 2 \
  --desired-capacity 1 \
  --vpc-zone-identifier "$PUBLIC_SUBNET_1,$PUBLIC_SUBNET_2" \
  --target-group-arns $TG_ARN \
  --health-check-type ELB \
  --health-check-grace-period 300

# Step 6: Create scaling policies
echo "Setting up auto scaling policies..."
aws autoscaling put-scaling-policy \
  --auto-scaling-group-name ${APP_NAME}-asg \
  --policy-name cpu-scaling-policy \
  --policy-type TargetTrackingScaling \
  --target-tracking-configuration '{
    "PredefinedMetricSpecification": {
      "PredefinedMetricType": "ASGAverageCPUUtilization"
    },
    "TargetValue": 70.0
  }'

# Output important information
echo ""
echo "======== AWS Infrastructure Setup Complete ========"
echo "VPC ID: $VPC_ID"
echo "Security Group ID: $EC2_SG"
echo "Load Balancer DNS: $LB_DNS"
echo "Target Group ARN: $TG_ARN"
echo "Auto Scaling Group: ${APP_NAME}-asg"
echo ""
echo "Use this Load Balancer DNS for your application: http://$LB_DNS"
echo "=================================================="

# Save important values for later scripts
cat > ./infrastructure-output.env << EOL
export VPC_ID=$VPC_ID
export PUBLIC_SUBNET_1=$PUBLIC_SUBNET_1
export PUBLIC_SUBNET_2=$PUBLIC_SUBNET_2
export EC2_SG=$EC2_SG
export LB_DNS=$LB_DNS
export TG_ARN=$TG_ARN
EOL 