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
FORCE_RECREATE="${FORCE_RECREATE:-false}"

echo "======================================================"
echo "       Setting up AWS Infrastructure for $APP_NAME"
echo "======================================================"
echo "Region: $AWS_REGION"
echo "EC2 Instance Type: $EC2_TYPE"
echo "SSH Key Name: $KEY_NAME"
echo "Force Recreation: $FORCE_RECREATE"
echo "======================================================"

# Force delete resources if requested
if [ "$FORCE_RECREATE" == "true" ]; then
  echo "Force delete enabled - removing existing resources"
  
  # Delete Auto Scaling Group if it exists
  if aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names ${APP_NAME}-asg --query "length(AutoScalingGroups)" --output text 2>/dev/null | grep -q "1"; then
    echo "Deleting Auto Scaling Group ${APP_NAME}-asg..."
    aws autoscaling update-auto-scaling-group \
      --auto-scaling-group-name ${APP_NAME}-asg \
      --min-size 0 \
      --max-size 0 \
      --desired-capacity 0
    
    echo "Waiting for instances to terminate..."
    sleep 60
    
    aws autoscaling delete-auto-scaling-group \
      --auto-scaling-group-name ${APP_NAME}-asg \
      --force-delete
  else
    echo "No Auto Scaling Group found to delete"
  fi
  
  # Delete Load Balancer if it exists
  if aws elbv2 describe-load-balancers --names ${APP_NAME}-lb --query "length(LoadBalancers)" --output text 2>/dev/null | grep -q "1"; then
    echo "Deleting Load Balancer ${APP_NAME}-lb..."
    LB_ARN=$(aws elbv2 describe-load-balancers --names ${APP_NAME}-lb --query "LoadBalancers[0].LoadBalancerArn" --output text)
    
    # Delete listeners first
    LISTENERS=$(aws elbv2 describe-listeners --load-balancer-arn $LB_ARN --query "Listeners[*].ListenerArn" --output text 2>/dev/null || echo "")
    for LISTENER in $LISTENERS; do
      echo "Deleting listener $LISTENER..."
      aws elbv2 delete-listener --listener-arn $LISTENER
    done
    
    # Delete the load balancer
    aws elbv2 delete-load-balancer --load-balancer-arn $LB_ARN
    
    echo "Waiting for load balancer to be deleted..."
    sleep 30
  else
    echo "No Load Balancer found to delete"
  fi
  
  # Delete Target Group if it exists
  if aws elbv2 describe-target-groups --names ${APP_NAME}-tg --query "length(TargetGroups)" --output text 2>/dev/null | grep -q "1"; then
    echo "Deleting Target Group ${APP_NAME}-tg..."
    TG_ARN=$(aws elbv2 describe-target-groups --names ${APP_NAME}-tg --query "TargetGroups[0].TargetGroupArn" --output text)
    aws elbv2 delete-target-group --target-group-arn $TG_ARN
  else
    echo "No Target Group found to delete"
  fi
  
  # Delete Launch Template if it exists
  if aws ec2 describe-launch-templates --launch-template-names ${APP_NAME}-launch-template --query "length(LaunchTemplates)" --output text 2>/dev/null | grep -q "1"; then
    echo "Deleting Launch Template ${APP_NAME}-launch-template..."
    aws ec2 delete-launch-template --launch-template-name ${APP_NAME}-launch-template
  else
    echo "No Launch Template found to delete"
  fi
  
  echo "Resource cleanup completed"
fi

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

# Check if VPC with the same name tag already exists
EXISTING_VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=${APP_NAME}-vpc" \
  --query "Vpcs[0].VpcId" \
  --output text 2>/dev/null || echo "")

if [ -z "$EXISTING_VPC_ID" ] || [ "$EXISTING_VPC_ID" == "None" ]; then
  echo "Creating new VPC..."
  VPC_ID=$(aws ec2 create-vpc --cidr-block $VPC_CIDR \
    --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${APP_NAME}-vpc}]" \
    --query 'Vpc.VpcId' --output text)
  aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames
else
  echo "Using existing VPC: $EXISTING_VPC_ID"
  VPC_ID=$EXISTING_VPC_ID
fi

echo "Creating public subnets..."

# Check if subnets already exist
EXISTING_SUBNET_1=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=${APP_NAME}-public-1" \
  --query "Subnets[0].SubnetId" \
  --output text 2>/dev/null || echo "")

EXISTING_SUBNET_2=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=${APP_NAME}-public-2" \
  --query "Subnets[0].SubnetId" \
  --output text 2>/dev/null || echo "")

if [ -z "$EXISTING_SUBNET_1" ] || [ "$EXISTING_SUBNET_1" == "None" ]; then
  echo "Creating subnet 1..."
  PUBLIC_SUBNET_1=$(aws ec2 create-subnet --vpc-id $VPC_ID \
    --cidr-block $PUBLIC_SUBNET_1_CIDR --availability-zone ${AWS_REGION}a \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${APP_NAME}-public-1}]" \
    --query 'Subnet.SubnetId' --output text)
else
  echo "Using existing subnet 1: $EXISTING_SUBNET_1"
  PUBLIC_SUBNET_1=$EXISTING_SUBNET_1
fi

if [ -z "$EXISTING_SUBNET_2" ] || [ "$EXISTING_SUBNET_2" == "None" ]; then
  echo "Creating subnet 2..."
  PUBLIC_SUBNET_2=$(aws ec2 create-subnet --vpc-id $VPC_ID \
    --cidr-block $PUBLIC_SUBNET_2_CIDR --availability-zone ${AWS_REGION}b \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${APP_NAME}-public-2}]" \
    --query 'Subnet.SubnetId' --output text)
else
  echo "Using existing subnet 2: $EXISTING_SUBNET_2"
  PUBLIC_SUBNET_2=$EXISTING_SUBNET_2
fi

echo "Setting up internet access..."

# Check if internet gateway exists
EXISTING_IGW=$(aws ec2 describe-internet-gateways \
  --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
  --query "InternetGateways[0].InternetGatewayId" \
  --output text 2>/dev/null || echo "")

if [ -z "$EXISTING_IGW" ] || [ "$EXISTING_IGW" == "None" ]; then
  echo "Creating internet gateway..."
  IGW_ID=$(aws ec2 create-internet-gateway \
    --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${APP_NAME}-igw}]" \
    --query 'InternetGateway.InternetGatewayId' --output text)
  
  echo "Attaching internet gateway to VPC..."
  aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID
else
  echo "Using existing internet gateway: $EXISTING_IGW"
  IGW_ID=$EXISTING_IGW
fi

# Check if route table exists
EXISTING_RTB=$(aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=${APP_NAME}-public-rtb" \
  --query "RouteTables[0].RouteTableId" \
  --output text 2>/dev/null || echo "")

if [ -z "$EXISTING_RTB" ] || [ "$EXISTING_RTB" == "None" ]; then
  echo "Creating route table..."
  PUBLIC_RTB=$(aws ec2 create-route-table --vpc-id $VPC_ID \
    --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${APP_NAME}-public-rtb}]" \
    --query 'RouteTable.RouteTableId' --output text)
  
  echo "Creating route to internet gateway..."
  aws ec2 create-route --route-table-id $PUBLIC_RTB --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID || \
    echo "Route already exists or couldn't be created"
else
  echo "Using existing route table: $EXISTING_RTB"
  PUBLIC_RTB=$EXISTING_RTB
  
  # Check if route to internet gateway exists
  ROUTE_EXISTS=$(aws ec2 describe-route-tables \
    --route-table-ids $PUBLIC_RTB \
    --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].GatewayId" \
    --output text 2>/dev/null || echo "")
  
  if [ -z "$ROUTE_EXISTS" ] || [ "$ROUTE_EXISTS" == "None" ]; then
    echo "Creating route to internet gateway..."
    aws ec2 create-route --route-table-id $PUBLIC_RTB --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID || \
      echo "Route couldn't be created"
  else
    echo "Route to internet gateway already exists"
  fi
fi

# Check subnet 1 route table association
SUBNET1_ASSOCIATED=$(aws ec2 describe-route-tables \
  --route-table-ids $PUBLIC_RTB \
  --query "RouteTables[0].Associations[?SubnetId=='$PUBLIC_SUBNET_1'].RouteTableAssociationId" \
  --output text 2>/dev/null || echo "")

if [ -z "$SUBNET1_ASSOCIATED" ] || [ "$SUBNET1_ASSOCIATED" == "None" ]; then
  echo "Associating subnet 1 with route table..."
  aws ec2 associate-route-table --route-table-id $PUBLIC_RTB --subnet-id $PUBLIC_SUBNET_1 || \
    echo "Subnet 1 association failed or already exists"
else
  echo "Subnet 1 already associated with route table"
fi

# Check subnet 2 route table association
SUBNET2_ASSOCIATED=$(aws ec2 describe-route-tables \
  --route-table-ids $PUBLIC_RTB \
  --query "RouteTables[0].Associations[?SubnetId=='$PUBLIC_SUBNET_2'].RouteTableAssociationId" \
  --output text 2>/dev/null || echo "")

if [ -z "$SUBNET2_ASSOCIATED" ] || [ "$SUBNET2_ASSOCIATED" == "None" ]; then
  echo "Associating subnet 2 with route table..."
  aws ec2 associate-route-table --route-table-id $PUBLIC_RTB --subnet-id $PUBLIC_SUBNET_2 || \
    echo "Subnet 2 association failed or already exists"
else
  echo "Subnet 2 already associated with route table"
fi

# Step 2: Create security group
echo "Creating security group..."

# Check if security group already exists
EXISTING_SG=$(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=${APP_NAME}-ec2-sg" \
  --query "SecurityGroups[0].GroupId" \
  --output text 2>/dev/null || echo "")

if [ -z "$EXISTING_SG" ] || [ "$EXISTING_SG" == "None" ]; then
  echo "Creating new security group..."
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
else
  echo "Using existing security group: $EXISTING_SG"
  EC2_SG=$EXISTING_SG
  
  # Ensure security group has the necessary rules
  echo "Ensuring security group has necessary rules..."
  
  # Function to check if rule exists and add if not
  ensure_sg_rule() {
    local port=$1
    local cidr=$2
    local proto=$3
    
    # Check if rule exists
    RULE_EXISTS=$(aws ec2 describe-security-groups \
      --group-ids $EC2_SG \
      --filters "Name=ip-permission.from-port,Values=$port" \
              "Name=ip-permission.to-port,Values=$port" \
              "Name=ip-permission.cidr,Values=$cidr" \
              "Name=ip-permission.protocol,Values=$proto" \
      --query "SecurityGroups[0].IpPermissions[?FromPort==\`$port\` && ToPort==\`$port\`].IpRanges[?CidrIp==\`$cidr\`].CidrIp" \
      --output text 2>/dev/null || echo "")
    
    if [ -z "$RULE_EXISTS" ] || [ "$RULE_EXISTS" == "None" ]; then
      echo "Adding $proto rule for port $port from $cidr..."
      aws ec2 authorize-security-group-ingress \
        --group-id $EC2_SG \
        --protocol $proto \
        --port $port \
        --cidr $cidr 2>/dev/null || echo "Rule already exists or couldn't be added"
    else
      echo "Rule for port $port from $cidr already exists"
    fi
  }
  
  # Add required rules
  ensure_sg_rule 22 "0.0.0.0/0" "tcp"
  ensure_sg_rule 80 "0.0.0.0/0" "tcp"
  ensure_sg_rule 443 "0.0.0.0/0" "tcp"
  ensure_sg_rule 8501 "0.0.0.0/0" "tcp"
  ensure_sg_rule 6443 "0.0.0.0/0" "tcp"
  
  # Check for self-referencing rule (allowing all traffic within the security group)
  SELF_RULE_EXISTS=$(aws ec2 describe-security-groups \
    --group-ids $EC2_SG \
    --query "SecurityGroups[0].IpPermissions[?UserIdGroupPairs[?GroupId==\`$EC2_SG\`]].UserIdGroupPairs[?GroupId==\`$EC2_SG\`].GroupId" \
    --output text 2>/dev/null || echo "")
  
  if [ -z "$SELF_RULE_EXISTS" ] || [ "$SELF_RULE_EXISTS" == "None" ]; then
    echo "Adding self-referencing rule..."
    aws ec2 authorize-security-group-ingress \
      --group-id $EC2_SG \
      --protocol all \
      --source-group $EC2_SG 2>/dev/null || echo "Self-referencing rule already exists or couldn't be added"
  else
    echo "Self-referencing rule already exists"
  fi
fi

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
    --output text 2>/dev/null || echo "")
  
  if [ -z "$SSM_POLICY_ATTACHED" ] || [ "$SSM_POLICY_ATTACHED" == "None" ]; then
    echo "Attaching SSM policy to existing role..."
    aws iam attach-role-policy \
      --role-name $ROLE_NAME \
      --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore || echo "Failed to attach SSM policy, but continuing"
  else
    echo "SSM policy already attached"
  fi
  
  EC2_POLICY_ATTACHED=$(aws iam list-attached-role-policies \
    --role-name $ROLE_NAME \
    --query "AttachedPolicies[?PolicyName=='AmazonEC2FullAccess'].PolicyName" \
    --output text 2>/dev/null || echo "")
  
  if [ -z "$EC2_POLICY_ATTACHED" ] || [ "$EC2_POLICY_ATTACHED" == "None" ]; then
    echo "Attaching EC2 policy to existing role..."
    aws iam attach-role-policy \
      --role-name $ROLE_NAME \
      --policy-arn arn:aws:iam::aws:policy/AmazonEC2FullAccess || echo "Failed to attach EC2 policy, but continuing"
  else
    echo "EC2 policy already attached"
  fi
  
  # Check if instance profile exists
  PROFILE_EXISTS=$(aws iam list-instance-profiles-for-role \
    --role-name $ROLE_NAME \
    --query "InstanceProfiles[0].InstanceProfileName" \
    --output text 2>/dev/null || echo "")
  
  if [ -z "$PROFILE_EXISTS" ] || [ "$PROFILE_EXISTS" == "None" ]; then
    echo "No instance profile found for role, creating one..."
    aws iam create-instance-profile --instance-profile-name $ROLE_NAME > /dev/null || echo "Failed to create instance profile, but continuing"
    
    echo "Adding role to instance profile..."
    aws iam add-role-to-instance-profile \
      --instance-profile-name $ROLE_NAME \
      --role-name $ROLE_NAME || echo "Failed to add role to instance profile, but continuing"
    
    # Wait for the instance profile to be fully available
    echo "Waiting for instance profile to be available..."
    sleep 10
  else
    echo "Instance profile '$PROFILE_EXISTS' already exists and has the role attached"
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
      echo "Failed to create IAM role, checking if it already exists..."
      # Double-check if role exists anyway
      ROLE_CHECK=$(aws iam get-role --role-name $ROLE_NAME 2>/dev/null && echo "true" || echo "false")
      if [ "$ROLE_CHECK" == "false" ]; then
        echo "ERROR: Role does not exist and failed to create it"
        exit 1
      else
        echo "Role exists despite error, continuing..."
      fi
    }
  
  # Attach SSM policy to the role
  echo "Attaching SSM policy to role..."
  aws iam attach-role-policy \
    --role-name $ROLE_NAME \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore || echo "Failed to attach SSM policy, but continuing"
  
  # Attach EC2 policy to the role
  echo "Attaching EC2 policy to role..."
  aws iam attach-role-policy \
    --role-name $ROLE_NAME \
    --policy-arn arn:aws:iam::aws:policy/AmazonEC2FullAccess || echo "Failed to attach EC2 policy, but continuing"
  
  # Check if instance profile exists
  PROFILE_EXISTS=$(aws iam get-instance-profile \
    --instance-profile-name $ROLE_NAME 2>/dev/null && echo "true" || echo "false")
  
  if [ "$PROFILE_EXISTS" == "false" ]; then
    # Create instance profile
    echo "Creating instance profile..."
    aws iam create-instance-profile --instance-profile-name $ROLE_NAME > /dev/null || echo "Failed to create instance profile, but continuing"
    
    # Add role to instance profile
    echo "Adding role to instance profile..."
    aws iam add-role-to-instance-profile \
      --instance-profile-name $ROLE_NAME \
      --role-name $ROLE_NAME || echo "Failed to add role to instance profile, but continuing"
  else
    echo "Instance profile already exists, checking if role is attached..."
    
    # Check if the role is already attached to the instance profile
    ROLE_ATTACHED=$(aws iam list-instance-profiles-for-role \
      --role-name $ROLE_NAME \
      --query "length(InstanceProfiles)" \
      --output text 2>/dev/null || echo "0")
    
    if [ "$ROLE_ATTACHED" == "0" ]; then
      echo "Role is not attached to instance profile, attaching now..."
      aws iam add-role-to-instance-profile \
        --instance-profile-name $ROLE_NAME \
        --role-name $ROLE_NAME 2>/dev/null || echo "Failed to add role to instance profile, likely already at limit"
    else
      echo "Role is already attached to instance profile"
    fi
  fi
fi

# Wait for the instance profile to be fully available
echo "Waiting for instance profile to be available..."
sleep 5

# Get instance profile ARN with retry and fallback
echo "Getting instance profile ARN..."
MAX_RETRIES=3
for i in $(seq 1 $MAX_RETRIES); do
  INSTANCE_PROFILE_ARN=$(aws iam get-instance-profile \
    --instance-profile-name $ROLE_NAME \
    --query "InstanceProfile.Arn" \
    --output text 2>/dev/null || echo "")
  
  if [ -n "$INSTANCE_PROFILE_ARN" ] && [ "$INSTANCE_PROFILE_ARN" != "None" ]; then
    echo "Using instance profile: $INSTANCE_PROFILE_ARN"
    break
  else
    echo "Failed to get instance profile ARN on attempt $i, waiting and retrying..."
    sleep 10
    
    if [ $i -eq $MAX_RETRIES ]; then
      echo "WARNING: Could not get instance profile ARN after $MAX_RETRIES attempts."
      echo "Will use a placeholder ARN and try to continue."
      # Use a placeholder ARN hoping it won't be needed
      INSTANCE_PROFILE_ARN="arn:aws:iam::000000000000:instance-profile/${APP_NAME}-ssm-role"
    fi
  fi
done

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

# Check if launch template already exists
LAUNCH_TEMPLATE_EXISTS=$(aws ec2 describe-launch-templates \
  --launch-template-names ${APP_NAME}-launch-template 2>/dev/null && echo "true" || echo "false")

if [ "$LAUNCH_TEMPLATE_EXISTS" == "true" ]; then
  echo "Launch template already exists, creating a new version..."
  
  # Create a new version of the existing launch template
  VERSION_RESULT=$(aws ec2 create-launch-template-version \
    --launch-template-name ${APP_NAME}-launch-template \
    --version-description "Updated version with K8s pre-installed" \
    --source-version '$Latest' \
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
    }" 2>/dev/null)
  
  if [ $? -ne 0 ]; then
    echo "Failed to create launch template version, but continuing"
  else
    echo "Launch template version created successfully"
    
    # Set the new version as default
    aws ec2 modify-launch-template \
      --launch-template-name ${APP_NAME}-launch-template \
      --default-version '$Latest' 2>/dev/null || echo "Failed to set default version, but continuing"
  fi
  
  echo "Launch template updated to new version."
else
  # Create new launch template
  echo "Creating new launch template..."
  TEMPLATE_RESULT=$(aws ec2 create-launch-template \
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
    }" 2>/dev/null)
  
  if [ $? -ne 0 ]; then
    echo "Failed to create launch template, checking if it exists anyway..."
    TEMPLATE_CHECK=$(aws ec2 describe-launch-templates \
      --launch-template-names ${APP_NAME}-launch-template \
      --query "LaunchTemplates[0].LaunchTemplateId" \
      --output text 2>/dev/null || echo "")
    
    if [ -z "$TEMPLATE_CHECK" ] || [ "$TEMPLATE_CHECK" == "None" ]; then
      echo "ERROR: Launch template does not exist and failed to create it"
      # Don't exit, continue with the script
    else
      echo "Launch template exists despite error, continuing..."
    fi
  else
    echo "Launch template created successfully"
  fi
fi

# Step 5: Create a load balancer and target group
echo "Creating target group..."

# Check if target group already exists
TG_ARN=$(aws elbv2 describe-target-groups \
  --names ${APP_NAME}-tg \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text 2>/dev/null || echo "")

if [ -z "$TG_ARN" ] || [ "$TG_ARN" == "None" ]; then
  echo "Creating new target group..."
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
    --output text 2>/dev/null)
  
  if [ -z "$TG_ARN" ] || [ "$TG_ARN" == "None" ]; then
    echo "Failed to create target group. Trying again with error handling..."
    
    # Try again to see if it exists despite the error
    TG_ARN=$(aws elbv2 describe-target-groups \
      --names ${APP_NAME}-tg \
      --query 'TargetGroups[0].TargetGroupArn' \
      --output text 2>/dev/null || echo "")
    
    if [ -z "$TG_ARN" ] || [ "$TG_ARN" == "None" ]; then
      echo "WARNING: Could not create or find target group. Using a placeholder ARN."
      TG_ARN="arn:aws:elasticloadbalancing:${AWS_REGION}:000000000000:targetgroup/${APP_NAME}-tg/0000000000000000"
    else
      echo "Found existing target group despite previous error: $TG_ARN"
    fi
  else
    echo "Target group created: $TG_ARN"
  fi
else
  echo "Target group already exists, using existing one: $TG_ARN"
fi

echo "Creating application load balancer..."

# Check if load balancer already exists
LB_ARN=$(aws elbv2 describe-load-balancers \
  --names ${APP_NAME}-lb \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text 2>/dev/null || echo "")

if [ -z "$LB_ARN" ] || [ "$LB_ARN" == "None" ]; then
  echo "Creating new load balancer..."
  LB_ARN=$(aws elbv2 create-load-balancer \
    --name ${APP_NAME}-lb \
    --subnets $PUBLIC_SUBNET_1 $PUBLIC_SUBNET_2 \
    --security-groups $EC2_SG \
    --query 'LoadBalancers[0].LoadBalancerArn' \
    --output text 2>/dev/null)
  
  if [ -z "$LB_ARN" ] || [ "$LB_ARN" == "None" ]; then
    echo "Failed to create load balancer. Trying again with error handling..."
    
    # Try again to see if it exists despite the error
    LB_ARN=$(aws elbv2 describe-load-balancers \
      --names ${APP_NAME}-lb \
      --query 'LoadBalancers[0].LoadBalancerArn' \
      --output text 2>/dev/null || echo "")
    
    if [ -z "$LB_ARN" ] || [ "$LB_ARN" == "None" ]; then
      echo "WARNING: Could not create or find load balancer. Using a placeholder ARN and DNS."
      LB_ARN="arn:aws:elasticloadbalancing:${AWS_REGION}:000000000000:loadbalancer/app/${APP_NAME}-lb/0000000000000000"
      LB_DNS="${APP_NAME}-lb.${AWS_REGION}.elb.amazonaws.com"
    else
      echo "Found existing load balancer despite previous error: $LB_ARN"
      
      # Get the load balancer DNS name
      LB_DNS=$(aws elbv2 describe-load-balancers \
        --load-balancer-arns $LB_ARN \
        --query 'LoadBalancers[0].DNSName' \
        --output text 2>/dev/null || echo "${APP_NAME}-lb.${AWS_REGION}.elb.amazonaws.com")
    fi
  else
    echo "Load balancer created: $LB_ARN"
    
    # Get the load balancer DNS name
    LB_DNS=$(aws elbv2 describe-load-balancers \
      --load-balancer-arns $LB_ARN \
      --query 'LoadBalancers[0].DNSName' \
      --output text)
  fi
  
  echo "Creating ALB listener..."
  LISTENER_ARN=$(aws elbv2 create-listener \
    --load-balancer-arn $LB_ARN \
    --protocol HTTP \
    --port 80 \
    --default-actions Type=forward,TargetGroupArn=$TG_ARN \
    --query 'Listeners[0].ListenerArn' \
    --output text 2>/dev/null || echo "")
  
  if [ -z "$LISTENER_ARN" ] || [ "$LISTENER_ARN" == "None" ]; then
    echo "WARNING: Failed to create listener. Will continue with deployment anyway."
  fi
else
  echo "Load balancer already exists, using existing one: $LB_ARN"
  
  # Get the load balancer DNS name
  LB_DNS=$(aws elbv2 describe-load-balancers \
    --load-balancer-arns $LB_ARN \
    --query 'LoadBalancers[0].DNSName' \
    --output text 2>/dev/null || echo "${APP_NAME}-lb.${AWS_REGION}.elb.amazonaws.com")
  
  # Check if listener already exists
  LISTENER_ARN=$(aws elbv2 describe-listeners \
    --load-balancer-arn $LB_ARN \
    --query 'Listeners[0].ListenerArn' \
    --output text 2>/dev/null || echo "")
  
  if [ -z "$LISTENER_ARN" ] || [ "$LISTENER_ARN" == "None" ]; then
    echo "Creating ALB listener..."
    LISTENER_ARN=$(aws elbv2 create-listener \
      --load-balancer-arn $LB_ARN \
      --protocol HTTP \
      --port 80 \
      --default-actions Type=forward,TargetGroupArn=$TG_ARN \
      --query 'Listeners[0].ListenerArn' \
      --output text 2>/dev/null || echo "")
    
    if [ -z "$LISTENER_ARN" ] || [ "$LISTENER_ARN" == "None" ]; then
      echo "WARNING: Failed to create listener. Will continue with deployment anyway."
    fi
  else
    echo "Listener already exists, updating default actions..."
    aws elbv2 modify-listener \
      --listener-arn $LISTENER_ARN \
      --default-actions Type=forward,TargetGroupArn=$TG_ARN > /dev/null 2>&1 || \
      echo "WARNING: Failed to update listener default actions."
  fi
fi

echo "Load balancer DNS: $LB_DNS"

# Step 6: Create auto scaling group
echo "Creating auto scaling group..."

# Check if auto scaling group already exists
ASG_EXISTS=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names ${APP_NAME}-asg \
  --query "length(AutoScalingGroups)" \
  --output text 2>/dev/null || echo "0")

if [ "$ASG_EXISTS" != "0" ]; then
  echo "Auto scaling group already exists, updating configuration..."
  
  # Update auto scaling group
  aws autoscaling update-auto-scaling-group \
    --auto-scaling-group-name ${APP_NAME}-asg \
    --launch-template LaunchTemplateName=${APP_NAME}-launch-template,Version='$Latest' \
    --min-size 1 \
    --max-size 2 \
    --desired-capacity 1 \
    --vpc-zone-identifier "$PUBLIC_SUBNET_1,$PUBLIC_SUBNET_2" \
    --target-group-arns $TG_ARN \
    --health-check-type ELB \
    --health-check-grace-period 300
  
  echo "Auto scaling group updated."
else
  # Create new auto scaling group
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
fi

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

# Save important values without using a heredoc
echo "export VPC_ID=$VPC_ID" > ./infrastructure-output.env
echo "export PUBLIC_SUBNET_1=$PUBLIC_SUBNET_1" >> ./infrastructure-output.env
echo "export PUBLIC_SUBNET_2=$PUBLIC_SUBNET_2" >> ./infrastructure-output.env
echo "export EC2_SG=$EC2_SG" >> ./infrastructure-output.env
echo "export LB_DNS=$LB_DNS" >> ./infrastructure-output.env
echo "export TG_ARN=$TG_ARN" >> ./infrastructure-output.env 