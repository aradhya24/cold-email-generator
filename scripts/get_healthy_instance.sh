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