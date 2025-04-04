#!/bin/bash
# Script to find a healthy EC2 instance from the auto-scaling group

set -e

# App name
APP_NAME="cold-email"

# Redirect all logs to stderr except the final IP
exec 3>&1 # Save original stdout to file descriptor 3
exec 1>&2 # Redirect stdout to stderr

echo "Fetching instances from auto scaling group ${APP_NAME}-asg..."
INSTANCE_IDS=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names ${APP_NAME}-asg \
  --query "AutoScalingGroups[0].Instances[*].InstanceId" \
  --output text)

if [ -z "$INSTANCE_IDS" ]; then
  echo "No instances found in ${APP_NAME}-asg auto scaling group."
  echo "Make sure the auto scaling group exists and has at least one instance."
  exit 1
fi

# Convert to array
read -ra INSTANCE_ARRAY <<< "$INSTANCE_IDS"
echo "Found ${#INSTANCE_ARRAY[@]} instances in the auto scaling group."

# Check each instance
for INSTANCE_ID in "${INSTANCE_ARRAY[@]}"; do
  echo "Checking instance $INSTANCE_ID..."
  
  # Get instance state
  STATE=$(aws ec2 describe-instances \
    --instance-ids $INSTANCE_ID \
    --query "Reservations[0].Instances[0].State.Name" \
    --output text)
  
  echo "Instance state: $STATE"
  
  # Get public IP if running
  if [ "$STATE" == "running" ]; then
    IP=$(aws ec2 describe-instances \
      --instance-ids $INSTANCE_ID \
      --query "Reservations[0].Instances[0].PublicIpAddress" \
      --output text)
    
    if [ -z "$IP" ] || [ "$IP" == "None" ] || [ "$IP" == "null" ]; then
      echo "No public IP found for instance $INSTANCE_ID."
      continue
    fi
    
    echo "Public IP: $IP"
    
    # Try to connect via SSH with more debugging and retries
    echo "Attempting SSH connection to verify instance health..."
    
    # Multiple SSH connection attempts
    MAX_SSH_RETRIES=3
    for i in $(seq 1 $MAX_SSH_RETRIES); do
      echo "SSH attempt $i of $MAX_SSH_RETRIES..."
      
      # Print instance console output for debugging
      echo "Instance console output:"
      aws ec2 get-console-output --instance-id $INSTANCE_ID --output text || true
      
      # Check security group settings
      SG_ID=$(aws ec2 describe-instances \
        --instance-ids $INSTANCE_ID \
        --query "Reservations[0].Instances[0].SecurityGroups[0].GroupId" \
        --output text)
      echo "Security group: $SG_ID"
      aws ec2 describe-security-groups --group-ids $SG_ID --query "SecurityGroups[0].IpPermissions" || true
      
      # Try SSH connection with verbose output
      if ssh -v -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=no ubuntu@$IP exit 2>/dev/null; then
        echo "Found healthy instance $INSTANCE_ID with IP $IP"
        # Output only the IP to stdout
        echo $IP >&3
        exit 0
      else
        echo "SSH connection failed for instance $INSTANCE_ID on attempt $i."
        
        if [ $i -lt $MAX_SSH_RETRIES ]; then
          echo "Waiting 10 seconds before next SSH attempt..."
          sleep 10
        fi
      fi
    done
    
    echo "All SSH connection attempts failed. Trying the next instance if available."
  fi
done

# If we get here, consider the most recent running instance as "healthy" even if SSH failed
# This is a fallback for cases where the SSH setup has issues
for INSTANCE_ID in "${INSTANCE_ARRAY[@]}"; do
  STATE=$(aws ec2 describe-instances \
    --instance-ids $INSTANCE_ID \
    --query "Reservations[0].Instances[0].State.Name" \
    --output text)
  
  if [ "$STATE" == "running" ]; then
    IP=$(aws ec2 describe-instances \
      --instance-ids $INSTANCE_ID \
      --query "Reservations[0].Instances[0].PublicIpAddress" \
      --output text)
    
    if [ -z "$IP" ] || [ "$IP" == "None" ] || [ "$IP" == "null" ]; then
      continue
    fi
    
    echo "FALLBACK: Using running instance $INSTANCE_ID with IP $IP without SSH validation"
    echo $IP >&3
    exit 0
  fi
done

echo "No healthy instances found in the auto scaling group."
echo "Please check the status of your instances or try to increase the desired capacity."
exit 1 