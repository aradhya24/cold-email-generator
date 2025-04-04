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

# Find any running instance first (we'll use this as a fallback)
FALLBACK_IP=""
FALLBACK_ID=""

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
    
    # Save as fallback
    if [ -z "$FALLBACK_IP" ]; then
      FALLBACK_IP=$IP
      FALLBACK_ID=$INSTANCE_ID
      echo "Saved instance $FALLBACK_ID with IP $FALLBACK_IP as fallback"
    fi
    
    # Try to connect via SSH with multiple tries
    echo "Attempting SSH connection to verify instance health..."
    
    # Multiple SSH connection attempts
    MAX_SSH_RETRIES=2
    for i in $(seq 1 $MAX_SSH_RETRIES); do
      echo "SSH attempt $i of $MAX_SSH_RETRIES..."
      
      if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no ubuntu@$IP echo "SSH connection successful" 2>/dev/null; then
        echo "Found healthy instance $INSTANCE_ID with IP $IP"
        # Output only the IP to stdout
        echo $IP >&3
        exit 0
      else
        echo "SSH connection failed for instance $INSTANCE_ID on attempt $i."
        
        if [ $i -lt $MAX_SSH_RETRIES ]; then
          echo "Waiting 5 seconds before next SSH attempt..."
          sleep 5
        fi
      fi
    done
    
    echo "All SSH connection attempts failed. Trying the next instance if available."
  fi
done

# If we get here and have a fallback, use it
if [ ! -z "$FALLBACK_IP" ]; then
  echo "FALLBACK: Using running instance $FALLBACK_ID with IP $FALLBACK_IP without SSH validation"
  echo $FALLBACK_IP >&3
  exit 0
fi

echo "No healthy instances found in the auto scaling group."
echo "Please check the status of your instances or try to increase the desired capacity."
exit 1 