#!/bin/bash
# AWS Infrastructure Setup Script for Cold Email Generator

# Exit on error, but allow debugging
set -e
set -o pipefail

# Define variables
AWS_REGION=${AWS_REGION:-"us-east-1"}
VPC_CIDR="10.0.0.0/16"
PUBLIC_SUBNET_1_CIDR="10.0.1.0/24"
PUBLIC_SUBNET_2_CIDR="10.0.2.0/24"
EC2_TYPE="t2.micro"
KEY_NAME=${KEY_NAME:-"cold-email-generator"}  # Replace with your SSH key name
APP_NAME="cold-email"

echo "Setting up AWS infrastructure for Cold Email Generator..."

# Check AWS CLI installation and configuration
if ! command -v aws &> /dev/null; then
  echo "ERROR: AWS CLI is not installed. Please install it first."
  exit 1
fi

# Verify AWS credentials
echo "Verifying AWS credentials..."
aws sts get-caller-identity || {
  echo "ERROR: AWS credentials are invalid or not configured properly."
  exit 1
}

# Get a more recent AMI ID for Ubuntu 22.04
echo "Finding latest Ubuntu 22.04 AMI..."
AMI_ID=$(aws ec2 describe-images \
  --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
  --query "sort_by(Images, &CreationDate)[-1].ImageId" \
  --output text)

if [ -z "$AMI_ID" ] || [ "$AMI_ID" == "None" ]; then
  echo "WARNING: Failed to get latest Ubuntu AMI, using fallback AMI..."
  AMI_ID="ami-0c7217cdde317cfec"  # Fallback to a known working AMI
else
  echo "Found latest Ubuntu AMI: $AMI_ID"
fi

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
# Allow SSH from anywhere for GitHub Actions to connect
aws ec2 authorize-security-group-ingress --group-id $EC2_SG --protocol tcp --port 22 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $EC2_SG --protocol tcp --port 80 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $EC2_SG --protocol tcp --port 443 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $EC2_SG --protocol tcp --port 8501 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $EC2_SG --protocol tcp --port 6443 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --group-id $EC2_SG --protocol all --source-group $EC2_SG

# Step 3: Create IAM role for SSM access
echo "Creating IAM role for EC2 instances to use SSM..."

# Create SSM IAM Role
ROLE_NAME="${APP_NAME}-ssm-role"

# Check if role already exists
ROLE_EXISTS=$(aws iam get-role --role-name $ROLE_NAME 2>/dev/null && echo "true" || echo "false")
if [ "$ROLE_EXISTS" == "true" ]; then
  echo "IAM role $ROLE_NAME already exists, checking permissions..."
  
  # Check if the role has the necessary policies
  SSM_POLICY_ATTACHED=$(aws iam list-attached-role-policies \
    --role-name $ROLE_NAME \
    --query "AttachedPolicies[?PolicyName=='AmazonSSMManagedInstanceCore'].PolicyName" \
    --output text)
  
  if [ -z "$SSM_POLICY_ATTACHED" ]; then
    echo "Attaching SSM policy to existing role..."
    aws iam attach-role-policy \
      --role-name $ROLE_NAME \
      --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
  fi
  
  EC2_POLICY_ATTACHED=$(aws iam list-attached-role-policies \
    --role-name $ROLE_NAME \
    --query "AttachedPolicies[?PolicyName=='AmazonEC2FullAccess'].PolicyName" \
    --output text)
  
  if [ -z "$EC2_POLICY_ATTACHED" ]; then
    echo "Attaching EC2 policy to existing role..."
    aws iam attach-role-policy \
      --role-name $ROLE_NAME \
      --policy-arn arn:aws:iam::aws:policy/AmazonEC2FullAccess
  fi
  
  # Check if instance profile exists
  PROFILE_EXISTS=$(aws iam get-instance-profile --instance-profile-name $ROLE_NAME 2>/dev/null && echo "true" || echo "false")
  
  if [ "$PROFILE_EXISTS" == "false" ]; then
    echo "Creating instance profile..."
    aws iam create-instance-profile --instance-profile-name $ROLE_NAME > /dev/null
    
    echo "Adding role to instance profile..."
    aws iam add-role-to-instance-profile \
      --instance-profile-name $ROLE_NAME \
      --role-name $ROLE_NAME
    
    # Wait for the instance profile to be fully available
    echo "Waiting for instance profile to be available..."
    sleep 10
  fi
else
  # Create the role
  echo "Creating IAM role..."
  aws iam create-role \
    --role-name $ROLE_NAME \
    --assume-role-policy-document '{
      "Version": "2012-10-17",
      "Statement": [
        {
          "Effect": "Allow",
          "Principal": {
            "Service": "ec2.amazonaws.com"
          },
          "Action": "sts:AssumeRole"
        }
      ]
    }' > /dev/null || {
      echo "ERROR: Failed to create IAM role"
      exit 1
    }
  
  # Attach SSM policy to the role
  echo "Attaching SSM policy to role..."
  aws iam attach-role-policy \
    --role-name $ROLE_NAME \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore || {
      echo "ERROR: Failed to attach SSM policy"
      aws iam delete-role --role-name $ROLE_NAME
      exit 1
    }
  
  # Attach EC2 policy to the role
  echo "Attaching EC2 policy to role..."
  aws iam attach-role-policy \
    --role-name $ROLE_NAME \
    --policy-arn arn:aws:iam::aws:policy/AmazonEC2FullAccess || {
      echo "WARNING: Failed to attach EC2 policy, continuing anyway"
    }
  
  # Create instance profile
  echo "Creating instance profile..."
  aws iam create-instance-profile \
    --instance-profile-name $ROLE_NAME > /dev/null || {
      echo "ERROR: Failed to create instance profile"
      aws iam detach-role-policy --role-name $ROLE_NAME --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
      aws iam delete-role --role-name $ROLE_NAME
      exit 1
    }
  
  # Add role to instance profile
  echo "Adding role to instance profile..."
  aws iam add-role-to-instance-profile \
    --instance-profile-name $ROLE_NAME \
    --role-name $ROLE_NAME || {
      echo "ERROR: Failed to add role to instance profile"
      aws iam delete-instance-profile --instance-profile-name $ROLE_NAME
      aws iam detach-role-policy --role-name $ROLE_NAME --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
      aws iam delete-role --role-name $ROLE_NAME
      exit 1
    }
  
  # Wait for the instance profile to be fully available
  echo "Waiting for instance profile to be available..."
  sleep 20
fi

# Get instance profile ARN
INSTANCE_PROFILE_ARN=$(aws iam get-instance-profile \
  --instance-profile-name $ROLE_NAME \
  --query "InstanceProfile.Arn" \
  --output text)

echo "Using instance profile: $INSTANCE_PROFILE_ARN"

# Step 4: Create EC2 launch template with Kubernetes pre-installed
echo "Creating launch template..."
ENCODED_USER_DATA=$(cat << 'EOF' | base64 -w 0
#!/bin/bash
# Update system and install Docker
apt-get update && apt-get upgrade -y
apt-get install -y apt-transport-https ca-certificates curl software-properties-common

# Ensure SSH is properly installed and configured first
echo "Setting up SSH server..."
apt-get install -y openssh-server

# Create SSH directory structure if needed
mkdir -p /root/.ssh /home/ubuntu/.ssh
chmod 700 /root/.ssh /home/ubuntu/.ssh

# Make sure the SSH service is enabled and started
systemctl enable ssh
systemctl start ssh

# Configure SSH securely
cat > /etc/ssh/sshd_config.d/secure-ssh.conf << 'EOSSH'
# SSH Secure Configuration
Port 22
Protocol 2
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_ed25519_key
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication no
PermitEmptyPasswords no
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding no
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
LogLevel VERBOSE
EOSSH

# Generate SSH host keys if they don't exist
ssh-keygen -A

# Restart SSH to apply changes
systemctl restart ssh

# Install AWS SSM Agent
echo "Installing AWS SSM Agent..."
mkdir -p /tmp/ssm
cd /tmp/ssm
wget https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/debian_amd64/amazon-ssm-agent.deb
dpkg -i amazon-ssm-agent.deb
systemctl enable amazon-ssm-agent
systemctl start amazon-ssm-agent

# Verify SSM Agent is running
if systemctl is-active --quiet amazon-ssm-agent; then
  echo "SSM Agent is running"
else
  echo "SSM Agent is not running, attempting to fix..."
  systemctl restart amazon-ssm-agent
  sleep 5
  if ! systemctl is-active --quiet amazon-ssm-agent; then
    echo "Failed to start SSM Agent, reinstalling..."
    apt-get remove --purge -y amazon-ssm-agent
    mkdir -p /tmp/ssm-reinstall
    cd /tmp/ssm-reinstall
    wget https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/debian_amd64/amazon-ssm-agent.deb
    dpkg -i amazon-ssm-agent.deb
    systemctl enable amazon-ssm-agent
    systemctl start amazon-ssm-agent
  fi
fi

# Ensure instance has proper IAM profile for SSM
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region || curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone | sed 's/[a-z]$//')
echo "Instance ID: $INSTANCE_ID in region $REGION"

# Verify SSH is running
if ! systemctl is-active --quiet ssh; then
  echo "SSH failed to start properly after configuration. Attempting to fix..."
  apt-get remove --purge -y openssh-server
  apt-get install -y openssh-server
  systemctl enable ssh
  systemctl start ssh
fi

# Set up SSH verification loop
echo "Verifying SSH service is running properly..."
MAX_RETRIES=5
SSH_OK=false

for i in $(seq 1 $MAX_RETRIES); do
  if systemctl is-active --quiet ssh; then
    echo "SSH service is running (attempt $i/$MAX_RETRIES)"
    # Test SSH connection locally to verify it's accepting connections
    if nc -z -w5 localhost 22; then
      echo "SSH port is open and accepting connections"
      SSH_OK=true
      break
    else
      echo "SSH port is not responding despite service running"
    fi
  else
    echo "SSH service is not running (attempt $i/$MAX_RETRIES)"
    systemctl restart ssh
  fi
  sleep 10
done

if [ "$SSH_OK" = false ]; then
  echo "WARNING: SSH verification failed after $MAX_RETRIES attempts"
  # Continue anyway as this is just the user data script
fi

# Install Docker
echo "Installing Docker..."
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
apt-get update && apt-get install -y docker-ce docker-ce-cli containerd.io
systemctl enable docker && systemctl start docker

# Install Kubernetes components
echo "Installing Kubernetes components..."
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

# Set appropriate permissions for ubuntu user
echo "ubuntu ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ubuntu
chmod 440 /etc/sudoers.d/ubuntu

# Copy the ubuntu user authorized_keys from the AWS launch
if [ -f /home/ubuntu/.ssh/authorized_keys ]; then
  cp /home/ubuntu/.ssh/authorized_keys /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
  chown ubuntu:ubuntu /home/ubuntu/.ssh/authorized_keys
  chmod 600 /home/ubuntu/.ssh/authorized_keys
fi

# Make sure the ubuntu user can access Docker without sudo
newgrp docker << ENDGROUP
su - ubuntu -c "docker version"
ENDGROUP

# Signal that user-data script has completed
echo "User data script completed at $(date)" > /tmp/user-data-complete
chmod 644 /tmp/user-data-complete

# Final checks
echo "====== FINAL ENVIRONMENT STATUS ======"
systemctl status ssh --no-pager || true
ss -tlnp | grep :22 || true
ls -la /home/ubuntu/.ssh/
echo "Ubuntu user in groups: $(groups ubuntu)"
echo "======================================"
EOF
)

aws ec2 create-launch-template \
  --launch-template-name ${APP_NAME}-launch-template \
  --version-description "Initial version with K8s pre-installed" \
  --launch-template-data "{
    \"ImageId\": \"$AMI_ID\",
    \"InstanceType\": \"$EC2_TYPE\",
    \"KeyName\": \"$KEY_NAME\",
    \"IamInstanceProfile\": {
      \"Arn\": \"$INSTANCE_PROFILE_ARN\"
    },
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

# Step 5: Create a load balancer and target group
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

# Step 6: Create auto scaling group
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

# Step 7: Create scaling policies
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