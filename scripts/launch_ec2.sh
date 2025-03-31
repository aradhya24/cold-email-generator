#!/bin/bash

# Exit on error
set -e

# Check for AWS CLI
if ! command -v aws &> /dev/null; then
    echo "AWS CLI not found. Please install it first."
    exit 1
fi

# Set region
export AWS_DEFAULT_REGION=us-east-1

# Create security group
echo "Creating security group for Cold Email Generator..."
SG_ID=$(aws ec2 create-security-group \
    --group-name cold-email-sg-$(date +%s) \
    --description "Security group for Cold Email Generator" \
    --query "GroupId" \
    --output text)

# Allow SSH from anywhere
echo "Adding SSH ingress rule..."
aws ec2 authorize-security-group-ingress \
    --group-id $SG_ID \
    --protocol tcp \
    --port 22 \
    --cidr 0.0.0.0/0

# Allow HTTP access (port 80)
echo "Adding HTTP ingress rule..."
aws ec2 authorize-security-group-ingress \
    --group-id $SG_ID \
    --protocol tcp \
    --port 80 \
    --cidr 0.0.0.0/0

# Allow HTTPS access (port 443)
echo "Adding HTTPS ingress rule..."
aws ec2 authorize-security-group-ingress \
    --group-id $SG_ID \
    --protocol tcp \
    --port 443 \
    --cidr 0.0.0.0/0

# Allow K8s ports
echo "Adding Kubernetes ports..."
aws ec2 authorize-security-group-ingress \
    --group-id $SG_ID \
    --protocol tcp \
    --port 6443 \
    --cidr 0.0.0.0/0

# Tag the security group
aws ec2 create-tags \
    --resources $SG_ID \
    --tags Key=Name,Value=cold-email-sg

# Create a temporary key pair for this deployment
KEY_NAME="cold-email-key-$(date +%s)"
echo "Creating new key pair: $KEY_NAME..."

# Import the GitLab CI/CD SSH key directly into AWS
PUB_KEY=$(ssh-keygen -y -f ~/.ssh/id_rsa)
echo "Importing SSH public key into AWS..."
aws ec2 import-key-pair \
    --key-name $KEY_NAME \
    --public-key-material "$(echo $PUB_KEY | base64)"

# Launch EC2 instance
echo "Launching EC2 instance..."
INSTANCE_ID=$(aws ec2 run-instances \
    --image-id ami-080e1f13689e07408 \
    --instance-type t2.micro \
    --key-name $KEY_NAME \
    --security-group-ids $SG_ID \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=cold-email-instance}]' \
    --user-data '#!/bin/bash
apt-get update
apt-get install -y docker.io
systemctl enable docker
systemctl start docker
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
mv kubectl /usr/local/bin/
' \
    --query "Instances[0].InstanceId" \
    --output text)

echo "Instance $INSTANCE_ID launching..."

# Wait for instance to be running
echo "Waiting for instance to be in running state..."
aws ec2 wait instance-running --instance-ids $INSTANCE_ID

# Get instance public IP
PUBLIC_IP=$(aws ec2 describe-instances \
    --instance-ids $INSTANCE_ID \
    --query "Reservations[0].Instances[0].PublicIpAddress" \
    --output text)

echo "========================================================"
echo "Instance ready with public IP: $PUBLIC_IP"
echo "========================================================"
echo "The public key used to create this instance is:"
echo "$PUB_KEY"
echo "========================================================"
echo "Testing SSH connection to new instance..."
# Give the instance a bit more time to initialize SSH
sleep 30
ssh -o ConnectTimeout=30 -o BatchMode=yes -o StrictHostKeyChecking=no ubuntu@$PUBLIC_IP "echo SSH connection successful" || echo "SSH still not ready, but instance is launched"
echo "=========================================================" 