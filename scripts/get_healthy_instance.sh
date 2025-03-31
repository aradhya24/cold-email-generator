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
    echo "No instances found in ASG $ASG_NAME" >&2
    
    # Fallback to EC2 instances with a tag
    echo "Falling back to EC2 instances with tag Name=cold-email-instance" >&2
    INSTANCE_IDS=$(aws ec2 describe-instances \
        --filters "Name=tag:Name,Values=cold-email-instance" "Name=instance-state-name,Values=running" \
        --query 'Reservations[*].Instances[*].InstanceId' \
        --output text)
    
    if [ -z "$INSTANCE_IDS" ]; then
        echo "No tagged instances found either. Exiting." >&2
        exit 1
    fi
fi

# Get the public IP of the first healthy instance
for INSTANCE_ID in $INSTANCE_IDS; do
    echo "Checking instance $INSTANCE_ID" >&2
    
    INSTANCE_STATE=$(aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text)
    
    echo "Instance state: $INSTANCE_STATE" >&2
    
    if [ "$INSTANCE_STATE" = "running" ]; then
        PUBLIC_IP=$(aws ec2 describe-instances \
            --instance-ids "$INSTANCE_ID" \
            --query 'Reservations[0].Instances[0].PublicIpAddress' \
            --output text)
        
        if [ ! -z "$PUBLIC_IP" ] && [ "$PUBLIC_IP" != "None" ] && [ "$PUBLIC_IP" != "null" ]; then
            echo "$PUBLIC_IP"
            exit 0
        else
            echo "No public IP found for instance $INSTANCE_ID" >&2
        fi
    fi
done

# If we reach here, we couldn't find a suitable instance
echo "No healthy instances found with public IPs" >&2

# Last resort - use the AWS_EC2_IP variable if it exists
if [ ! -z "$AWS_EC2_IP" ]; then
    echo "Using AWS_EC2_IP environment variable: $AWS_EC2_IP" >&2
    echo "$AWS_EC2_IP"
    exit 0
fi

exit 1