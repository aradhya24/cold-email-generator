#!/bin/bash

# Exit on error
set -e

# Check if AWS region is set
if [ -z "$AWS_DEFAULT_REGION" ]; then
    echo "AWS_DEFAULT_REGION is not set. Setting to us-east-1"
    export AWS_DEFAULT_REGION=us-east-1
fi

# Get the Auto Scaling Group name
ASG_NAME="cold-email-asg"

# Get instance IDs from the ASG
INSTANCE_IDS=$(aws autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-name "$ASG_NAME" \
    --query 'AutoScalingGroups[0].Instances[*].InstanceId' \
    --output text)

if [ -z "$INSTANCE_IDS" ]; then
    echo "No instances found in ASG $ASG_NAME"
    exit 1
fi

# Get the public IP of the first healthy instance
for INSTANCE_ID in $INSTANCE_IDS; do
    INSTANCE_STATE=$(aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text)
    
    if [ "$INSTANCE_STATE" = "running" ]; then
        PUBLIC_IP=$(aws ec2 describe-instances \
            --instance-ids "$INSTANCE_ID" \
            --query 'Reservations[0].Instances[0].PublicIpAddress' \
            --output text)
        
        if [ ! -z "$PUBLIC_IP" ]; then
            echo "$PUBLIC_IP"
            exit 0
        fi
    fi
done

echo "No healthy instances found"
exit 1