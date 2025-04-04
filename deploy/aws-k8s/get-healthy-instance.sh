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

# Show the SSH config and key permissions
echo "SSH configuration:"
echo "SSH key permissions:"
ls -la ~/.ssh/id_rsa || echo "SSH key not found at ~/.ssh/id_rsa"
cat ~/.ssh/config || echo "SSH config not found"

# Try to fix SSH known hosts issues
echo "Clearing any SSH known hosts entries that might cause issues..."
> ~/.ssh/known_hosts
echo "Adding GitHub to known hosts..."
ssh-keyscan -t rsa github.com >> ~/.ssh/known_hosts 2>/dev/null

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
    
    # Get console output for debugging
    echo "Getting console output for instance $INSTANCE_ID..."
    aws ec2 get-console-output --instance-id $INSTANCE_ID | grep -A 20 "user-data" || echo "No relevant console output found"
    
    # Try to check if the instance has finished initializing
    echo "Checking if user-data script has completed..."
    if aws ssm get-command-invocation --command-id "$(aws ssm send-command \
      --instance-ids $INSTANCE_ID \
      --document-name "AWS-RunShellScript" \
      --parameters '{"commands":["ls -la /tmp/user-data-complete"]}' \
      --query "Command.CommandId" --output text 2>/dev/null)" \
      --query "Status" --output text 2>/dev/null | grep -q "Success"; then
      echo "Instance initialization complete! (verified through SSM)"
    else
      echo "Could not verify initialization through SSM (this is normal if SSM agent is not installed)"
    fi
    
    # Try direct port connectivity check
    echo "Testing TCP connectivity to port 22 on $IP..."
    if nc -z -v -w10 $IP 22; then
      echo "Port 22 is open and reachable on $IP"
    else
      echo "Port 22 is not reachable on $IP. SSH will likely fail."
    fi
    
    # Try traceroute to the host to diagnose network issues
    echo "Traceroute to $IP (max 10 hops):"
    traceroute -m 10 -w 1 $IP || echo "Traceroute not available or failed"
    
    # Try ping before ssh
    echo "Testing network connectivity to $IP..."
    if ping -c 3 -W 5 $IP > /dev/null 2>&1; then
      echo "Network connectivity confirmed to $IP"
    else
      echo "Warning: Cannot ping $IP, but this might be due to firewall rules."
    fi
    
    # Try SSH with very verbose output for debugging
    echo "Attempting connection with SSH debug output:"
    ssh -v -v -v -o ConnectTimeout=20 -o BatchMode=yes -o StrictHostKeyChecking=no ubuntu@$IP echo "Debug connection test" || echo "Debug SSH connection failed"
    
    # Try different SSH connection methods
    echo "Attempting SSH connection with multiple methods..."
    
    # First try with all users at once to save time
    if timeout 20 ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=no ubuntu@$IP echo "SSH connection successful as ubuntu" 2>/dev/null ||
       timeout 20 ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=no ec2-user@$IP echo "SSH connection successful as ec2-user" 2>/dev/null ||
       timeout 20 ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=no admin@$IP echo "SSH connection successful as admin" 2>/dev/null; then
      
      echo "Found healthy instance $INSTANCE_ID with IP $IP (SSH verified)"
      # Output only the IP to stdout
      echo $IP >&3
      
      # Store instance ID and IP for the workflow
      echo "INSTANCE_ID=$INSTANCE_ID" >> $GITHUB_ENV
      echo "EC2_IP=$IP" >> $GITHUB_ENV
      exit 0
    else
      echo "All quick SSH connections failed. Attempting detailed troubleshooting..."
      
      # Check SSH key is correctly formatted
      echo "Checking SSH key format:"
      ssh-keygen -l -f ~/.ssh/id_rsa || echo "SSH key verification failed"
      
      # Try telnet connection to port 22
      echo "Attempting telnet connection to port 22:"
      timeout 5 telnet $IP 22 || echo "Telnet connection failed"
      
      # Try curl to port 22
      echo "Testing port 22 with curl:"
      curl --connect-timeout 5 telnet://$IP:22 || echo "Curl connection test failed"
    fi
    
    echo "All SSH connection methods failed for $INSTANCE_ID."
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