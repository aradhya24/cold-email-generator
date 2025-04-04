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

# Wait for instances to reach running state
MAX_WAIT_TIME=300  # 5 minutes
START_TIME=$(date +%s)
HAVE_RUNNING_INSTANCE=false

echo "Waiting for instances to reach 'running' state (max wait: $MAX_WAIT_TIME seconds)..."
while [ $(($(date +%s) - START_TIME)) -lt $MAX_WAIT_TIME ]; do
  for INSTANCE_ID in "${INSTANCE_ARRAY[@]}"; do
    STATE=$(aws ec2 describe-instances \
      --instance-ids $INSTANCE_ID \
      --query "Reservations[0].Instances[0].State.Name" \
      --output text)
    
    if [ "$STATE" == "running" ]; then
      HAVE_RUNNING_INSTANCE=true
      break 2  # Break out of both loops
    fi
  done
  
  if [ "$HAVE_RUNNING_INSTANCE" = true ]; then
    break
  fi
  
  echo "No running instances yet. Waiting 15 seconds..."
  sleep 15
done

if [ "$HAVE_RUNNING_INSTANCE" = false ]; then
  echo "No instances reached 'running' state within $MAX_WAIT_TIME seconds."
  echo "Proceeding with instance search anyway..."
fi

# Store all running instances and their IPs
declare -A RUNNING_INSTANCES
RUNNING_INSTANCE_COUNT=0

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
    RUNNING_INSTANCES[$INSTANCE_ID]=$IP
    RUNNING_INSTANCE_COUNT=$((RUNNING_INSTANCE_COUNT + 1))
    
    # Try ping first to see if network connectivity exists
    echo "Testing network connectivity to $IP..."
    if ping -c 1 -W 5 $IP > /dev/null 2>&1; then
      echo "Network connectivity confirmed to $IP"
    else
      echo "Warning: Cannot ping $IP, but this might be due to firewall rules."
    fi
    
    # Try to connect via SSH with multiple tries
    echo "Attempting SSH connection to verify instance health..."
    
    # Multiple SSH connection attempts with different options
    MAX_SSH_RETRIES=3
    SSH_SUCCESS=false
    
    for i in $(seq 1 $MAX_SSH_RETRIES); do
      echo "SSH attempt $i of $MAX_SSH_RETRIES..."
      
      if [ $i -eq 1 ]; then
        # First attempt - normal connection
        ssh -v -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no ubuntu@$IP echo "SSH connection successful" 2>/dev/null && SSH_SUCCESS=true
      elif [ $i -eq 2 ]; then
        # Second attempt - try with different user (ec2-user)
        ssh -v -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no ec2-user@$IP echo "SSH connection successful" 2>/dev/null && SSH_SUCCESS=true
      else
        # Third attempt - try with root and longer timeout
        ssh -v -o BatchMode=yes -o ConnectTimeout=20 -o StrictHostKeyChecking=no root@$IP echo "SSH connection successful" 2>/dev/null && SSH_SUCCESS=true
      fi
      
      if [ "$SSH_SUCCESS" = true ]; then
        echo "Found healthy instance $INSTANCE_ID with IP $IP (SSH verified)"
        # Output only the IP to stdout
        echo $IP >&3
        
        # Store instance ID and IP for the workflow
        echo "INSTANCE_ID=$INSTANCE_ID" >> $GITHUB_ENV
        echo "EC2_IP=$IP" >> $GITHUB_ENV
        exit 0
      else
        echo "SSH connection failed for instance $INSTANCE_ID on attempt $i."
        
        if [ $i -lt $MAX_SSH_RETRIES ]; then
          echo "Waiting 10 seconds before next SSH attempt..."
          sleep 10
        fi
      fi
    done
    
    echo "All SSH connection attempts failed for $INSTANCE_ID. Instance may not be ready for SSH yet."
  fi
done

# If we get here, no instances successfully connected via SSH
echo "No instances verified via SSH. Selecting best available instance..."

if [ $RUNNING_INSTANCE_COUNT -gt 0 ]; then
  # Select the first running instance
  for INSTANCE_ID in "${!RUNNING_INSTANCES[@]}"; do
    IP=${RUNNING_INSTANCES[$INSTANCE_ID]}
    echo "FALLBACK: Using running instance $INSTANCE_ID with IP $IP without SSH validation"
    
    # Store instance ID and IP for the workflow
    echo "INSTANCE_ID=$INSTANCE_ID" >> $GITHUB_ENV
    echo "EC2_IP=$IP" >> $GITHUB_ENV
    
    # Output the IP to stdout
    echo $IP >&3
    exit 0
  done
fi

# If we get here, no running instances found
echo "ERROR: No running instances found with public IPs."
echo "Please check the AWS console and verify that instances are launching correctly."
exit 1 