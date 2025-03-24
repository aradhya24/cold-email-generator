# AWS Deployment Guide for Cold Email Generator
## A Free Tier-Optimized Step-by-Step Guide

---

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Phase 1: Infrastructure Setup](#phase-1-infrastructure-setup)
3. [Phase 2: Container Registry and GitHub Repository](#phase-2-container-registry-and-github-repository)
4. [Phase 3: Store Secrets and Set Up IAM Roles](#phase-3-store-secrets-and-set-up-iam-roles)
5. [Phase 4: Set Up ECS Cluster and Load Balancer](#phase-4-set-up-ecs-cluster-and-load-balancer)
6. [Phase 5: CI/CD Pipeline Configuration](#phase-5-cicd-pipeline-configuration)
7. [Phase 6: ECS Service Creation and Final Setup](#phase-6-ecs-service-creation-and-final-setup)
8. [Phase 7: Monitoring and Maintenance](#phase-7-monitoring-and-maintenance)
9. [Phase 8: Additional Optimizations and Enhancements](#phase-8-additional-optimizations-and-enhancements)
10. [Phase 9: Final Verification and Documentation](#phase-9-final-verification-and-documentation)
11. [Phase 10: Documentation and Maintenance Schedule](#phase-10-documentation-and-maintenance-schedule)
12. [Free Tier Optimization Checklist](#free-tier-optimization-checklist)
13. [Troubleshooting Common Issues](#troubleshooting-common-issues)

---

## Free Tier Optimization Strategy

This deployment guide is specifically designed to keep your costs within the AWS Free Tier limits while providing a robust and scalable infrastructure. The key free tier optimizations include:

- Using t2.micro EC2 instances (750 hours per month free)
- Scheduled scaling to shut down instances during off-hours to stay within free hours
- Optimizing S3 storage to stay under 5GB limit
- Configuring CloudWatch alarms within the 10 free alarm limit
- Using basic monitoring instead of detailed monitoring
- Setting budget alerts to notify you before exceeding Free Tier limits
- Leveraging EC2 auto-scaling to maintain minimal resource usage

---

## Prerequisites

Before beginning this deployment, ensure you have:

1. AWS Account with access key and secret key
2. GitHub account
3. Docker installed locally
4. Git for version control
5. AWS CLI installed and configured

---

## Phase 1: Infrastructure Setup

### Step 1: Set Up AWS CLI and Configuration

```bash
# Install AWS CLI (if not already installed)
# For Windows: Download and install from AWS website
# For macOS:
brew install awscli
# For Linux:
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install

# Configure AWS CLI with your credentials
aws configure
# Enter your AWS Access Key ID, Secret Key, preferred region (e.g., us-east-1), and output format (json)
```

### Step 2: Create a VPC and Subnets

```bash
# Create a VPC
aws ec2 create-vpc --cidr-block 10.0.0.0/16 --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=cold-email-vpc}]"
# Note the VpcId in the output (e.g., vpc-0a1b2c3d4e)

# Enable DNS hostnames for the VPC
aws ec2 modify-vpc-attribute --vpc-id vpc-0a1b2c3d4e --enable-dns-hostnames

# Create public subnets in two availability zones
aws ec2 create-subnet --vpc-id vpc-0a1b2c3d4e --cidr-block 10.0.1.0/24 --availability-zone us-east-1a --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=public-subnet-1}]"
aws ec2 create-subnet --vpc-id vpc-0a1b2c3d4e --cidr-block 10.0.2.0/24 --availability-zone us-east-1b --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=public-subnet-2}]"

# Create private subnets in two availability zones
aws ec2 create-subnet --vpc-id vpc-0a1b2c3d4e --cidr-block 10.0.3.0/24 --availability-zone us-east-1a --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=private-subnet-1}]"
aws ec2 create-subnet --vpc-id vpc-0a1b2c3d4e --cidr-block 10.0.4.0/24 --availability-zone us-east-1b --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=private-subnet-2}]"

# Note the SubnetIds in the output (e.g., subnet-0a1b2c3d4e, subnet-0e4d3c2b1a, etc.)
```

### Step 3: Create Internet Gateway and NAT Gateway

```bash
# Create an Internet Gateway
aws ec2 create-internet-gateway --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=cold-email-igw}]"
# Note the InternetGatewayId in the output (e.g., igw-0a1b2c3d4e)

# Attach the Internet Gateway to the VPC
aws ec2 attach-internet-gateway --internet-gateway-id igw-0a1b2c3d4e --vpc-id vpc-0a1b2c3d4e

# Allocate an Elastic IP for the NAT Gateway
aws ec2 allocate-address --domain vpc
# Note the AllocationId in the output (e.g., eipalloc-0a1b2c3d4e)

# Create a NAT Gateway in the first public subnet
aws ec2 create-nat-gateway --subnet-id subnet-0a1b2c3d4e --allocation-id eipalloc-0a1b2c3d4e --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=cold-email-nat}]"
# Note the NatGatewayId in the output (e.g., nat-0a1b2c3d4e)
```

### Step 4: Create and Configure Route Tables

```bash
# Create a route table for public subnets
aws ec2 create-route-table --vpc-id vpc-0a1b2c3d4e --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=public-rt}]"
# Note the RouteTableId in the output (e.g., rtb-0a1b2c3d4e)

# Create a route for Internet Gateway
aws ec2 create-route --route-table-id rtb-0a1b2c3d4e --destination-cidr-block 0.0.0.0/0 --gateway-id igw-0a1b2c3d4e

# Associate public subnets with the route table
aws ec2 associate-route-table --route-table-id rtb-0a1b2c3d4e --subnet-id subnet-0a1b2c3d4e  # public-subnet-1
aws ec2 associate-route-table --route-table-id rtb-0a1b2c3d4e --subnet-id subnet-0e4d3c2b1a  # public-subnet-2

# Create a route table for private subnets
aws ec2 create-route-table --vpc-id vpc-0a1b2c3d4e --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=private-rt}]"
# Note the RouteTableId in the output (e.g., rtb-0e4d3c2b1a)

# Create a route for NAT Gateway
aws ec2 create-route --route-table-id rtb-0e4d3c2b1a --destination-cidr-block 0.0.0.0/0 --nat-gateway-id nat-0a1b2c3d4e

# Associate private subnets with the route table
aws ec2 associate-route-table --route-table-id rtb-0e4d3c2b1a --subnet-id subnet-0f5e4d3c2b  # private-subnet-1
aws ec2 associate-route-table --route-table-id rtb-0e4d3c2b1a --subnet-id subnet-0b1a2c3d4e  # private-subnet-2
```

### Step 5: Create Security Groups

```bash
# Create a security group for the Application Load Balancer
aws ec2 create-security-group \
  --group-name cold-email-alb-sg \
  --description "Security group for ALB" \
  --vpc-id vpc-0a1b2c3d4e \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=cold-email-alb-sg}]"
# Note the GroupId in the output (e.g., sg-0a1b2c3d4e)

# Allow HTTP traffic on port 80 from anywhere
aws ec2 authorize-security-group-ingress \
  --group-id sg-0a1b2c3d4e \
  --protocol tcp \
  --port 80 \
  --cidr 0.0.0.0/0

# Create a security group for ECS instances
aws ec2 create-security-group \
  --group-name cold-email-ecs-sg \
  --description "Security group for ECS instances" \
  --vpc-id vpc-0a1b2c3d4e \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=cold-email-ecs-sg}]"
# Note the GroupId in the output (e.g., sg-0e4d3c2b1a)

# Allow traffic on port 8501 from the ALB security group
aws ec2 authorize-security-group-ingress \
  --group-id sg-0e4d3c2b1a \
  --protocol tcp \
  --port 8501 \
  --source-group sg-0a1b2c3d4e

# Allow SSH access (optional, for troubleshooting)
aws ec2 authorize-security-group-ingress \
  --group-id sg-0e4d3c2b1a \
  --protocol tcp \
  --port 22 \
  --cidr YOUR_IP_ADDRESS/32  # Replace with your IP
```

## Phase 2: Container Registry and GitHub Repository

### Step 6: Create an ECR Repository

```bash
# Create an ECR repository for your Docker images
aws ecr create-repository \
  --repository-name cold-email-generator \
  --image-scanning-configuration scanOnPush=true
# Note the repositoryUri in the output (e.g., 975050280075.dkr.ecr.us-east-1.amazonaws.com/cold-email-generator)
```

### Step 7: Set Up GitHub Repository

1. Create a new GitHub repository:
   - Go to GitHub.com and sign in to your account
   - Click the "+" icon in the top right and select "New repository"
   - Name it "cold-email-generator"
   - Choose public or private visibility as needed
   - Initialize with a README if starting from scratch
   - Click "Create repository"

2. Clone the repository to your local machine:
```bash
git clone https://github.com/your-username/cold-email-generator.git
cd cold-email-generator
```

3. Add your project files to the repository:
```bash
# Copy your project files to this directory
cp -r /path/to/your/project/* .

# Make sure to include Dockerfile, docker-compose.yml, and .dockerignore
git add .
git commit -m "Initial project setup with Docker configuration"
git push origin main
```

### Step 8: Create GitHub Connection in AWS CodeStar

AWS CodeStar Connections allows CodePipeline to connect to GitHub repositories.

```bash
# Create a connection to GitHub
aws codestar-connections create-connection \
  --provider-type GitHub \
  --connection-name GitHub-Connection
```

After running this command, you'll need to:
1. Note the ARN of the connection (e.g., arn:aws:codestar-connections:region:975050280075:connection/connection-id)
2. Go to the AWS Management Console
3. Navigate to Developer Tools > Settings > Connections
4. Find your connection and click "Update pending connection"
5. Follow the prompts to authorize AWS to access your GitHub account
6. Complete the OAuth flow

### Step 9: Create buildspec.yml File for CodeBuild

Create a file named `buildspec.yml` in your repository root with the following content:

```yaml
version: 0.2

phases:
  pre_build:
    commands:
      - echo Logging in to Amazon ECR...
      - aws ecr get-login-password --region $AWS_DEFAULT_REGION | docker login --username AWS --password-stdin 975050280075.dkr.ecr.$AWS_DEFAULT_REGION.amazonaws.com
      - REPOSITORY_URI=975050280075.dkr.ecr.$AWS_DEFAULT_REGION.amazonaws.com/cold-email-generator
      - COMMIT_HASH=$(echo $CODEBUILD_RESOLVED_SOURCE_VERSION | cut -c 1-7)
      - IMAGE_TAG=${COMMIT_HASH:=latest}
  build:
    commands:
      - echo Build started on `date`
      - echo Building the Docker image...
      - docker build -t $REPOSITORY_URI:latest .
      - docker tag $REPOSITORY_URI:latest $REPOSITORY_URI:$IMAGE_TAG
  post_build:
    commands:
      - echo Build completed on `date`
      - echo Pushing the Docker images...
      - docker push $REPOSITORY_URI:latest
      - docker push $REPOSITORY_URI:$IMAGE_TAG
      - echo Writing image definitions file...
      - echo "{\"ImageURI\":\"$REPOSITORY_URI:$IMAGE_TAG\"}" > imageDefinition.json
artifacts:
  files:
    - imageDefinition.json
    - taskdef.json
    - appspec.yaml
```

### Step 10: Create Task Definition Files

Create a file named `taskdef.json` in your repository root:

```json
{
  "family": "cold-email-generator",
  "executionRoleArn": "arn:aws:iam::975050280075:role/ecsTaskExecutionRole",
  "networkMode": "awsvpc",
  "containerDefinitions": [
    {
      "name": "app",
      "image": "<IMAGE_NAME>",
      "essential": true,
      "portMappings": [
        {
          "containerPort": 8501,
          "hostPort": 8501,
          "protocol": "tcp"
        }
      ],
      "environment": [
        {
          "name": "USER_AGENT",
          "value": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
        }
      ],
      "secrets": [
        {
          "name": "GROQ_API_KEY",
          "valueFrom": "arn:aws:ssm:us-east-1:975050280075:parameter/cold-email-generator/groq-api-key"
        }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/cold-email-generator",
          "awslogs-region": "us-east-1",
          "awslogs-stream-prefix": "ecs"
        }
      },
      "memory": 512,
      "cpu": 256
    }
  ],
  "requiresCompatibilities": ["EC2"],
  "cpu": "256",
  "memory": "512"
}
```

Create a file named `appspec.yaml` in your repository root:

```yaml
version: 0.0
Resources:
  - TargetService:
      Type: AWS::ECS::Service
      Properties:
        TaskDefinition: <TASK_DEFINITION>
        LoadBalancerInfo:
          ContainerName: "app"
          ContainerPort: 8501
```

### Step 11: Commit and Push Task Definition Files

```bash
git add buildspec.yml taskdef.json appspec.yaml
git commit -m "Add AWS CI/CD configuration files"
git push origin main
```

## Phase 3: Store Secrets and Set Up IAM Roles

### Step 12: Store API Key in Parameter Store

```bash
# Store your GROQ API key securely
aws ssm put-parameter \
  --name "/cold-email-generator/groq-api-key" \
  --value "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" \
  --type "SecureString" \
  --description "GROQ API Key for Cold Email Generator"
```

### Step 13: Create Required IAM Roles

```bash
# Create ECS task execution role
aws iam create-role \
  --role-name ecsTaskExecutionRole \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Principal": {
          "Service": "ecs-tasks.amazonaws.com"
        },
        "Action": "sts:AssumeRole"
      }
    ]
  }'

# Attach policies to the role
aws iam attach-role-policy \
  --role-name ecsTaskExecutionRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy

aws iam attach-role-policy \
  --role-name ecsTaskExecutionRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMReadOnlyAccess

# Create ECS instance role
aws iam create-role \
  --role-name ecsInstanceRole \
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
  }'

# Attach policies to the role
aws iam attach-role-policy \
  --role-name ecsInstanceRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role

# Create instance profile for the role
aws iam create-instance-profile \
  --instance-profile-name ecsInstanceProfile

aws iam add-role-to-instance-profile \
  --instance-profile-name ecsInstanceProfile \
  --role-name ecsInstanceRole

# Create CodeBuild service role
aws iam create-role \
  --role-name codeBuildServiceRole \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Principal": {
          "Service": "codebuild.amazonaws.com"
        },
        "Action": "sts:AssumeRole"
      }
    ]
  }'

# Attach policies to the role
aws iam attach-role-policy \
  --role-name codeBuildServiceRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonECR-FullAccess

aws iam attach-role-policy \
  --role-name codeBuildServiceRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess

# Create CodePipeline service role
aws iam create-role \
  --role-name codePipelineServiceRole \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Principal": {
          "Service": "codepipeline.amazonaws.com"
        },
        "Action": "sts:AssumeRole"
      }
    ]
  }'

# Attach policies to the role
aws iam attach-role-policy \
  --role-name codePipelineServiceRole \
  --policy-arn arn:aws:iam::aws:policy/AWSCodeBuildAdminAccess

aws iam attach-role-policy \
  --role-name codePipelineServiceRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess

aws iam attach-role-policy \
  --role-name codePipelineServiceRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonECS-FullAccess

aws iam attach-role-policy \
  --role-name codePipelineServiceRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonCodeDeployFullAccess
```

## Phase 4: Set Up ECS Cluster and Load Balancer

### Step 14: Create ECS Cluster

```bash
# Create an ECS cluster
aws ecs create-cluster --cluster-name cold-email-cluster

# Create CloudWatch log group for the container logs
aws logs create-log-group --log-group-name /ecs/cold-email-generator
```

### Step 15: Create the Application Load Balancer

```bash
# Create a target group
aws elbv2 create-target-group \
  --name cold-email-tg \
  --protocol HTTP \
  --port 8501 \
  --vpc-id vpc-0a1b2c3d4e \
  --target-type ip \
  --health-check-path "/" \
  --health-check-port 8501 \
  --health-check-interval-seconds 30 \
  --health-check-timeout-seconds 5 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 3
# Note the TargetGroupArn in the output

# Create the load balancer
aws elbv2 create-load-balancer \
  --name cold-email-lb \
  --subnets subnet-0a1b2c3d4e subnet-0e4d3c2b1a \
  --security-groups sg-0a1b2c3d4e \
  --type application
# Note the LoadBalancerArn in the output

# Create listener
aws elbv2 create-listener \
  --load-balancer-arn arn:aws:elasticloadbalancing:us-east-1:975050280075:loadbalancer/app/cold-email-lb/abc123 \
  --protocol HTTP \
  --port 80 \
  --default-actions Type=forward,TargetGroupArn=arn:aws:elasticloadbalancing:us-east-1:975050280075:targetgroup/cold-email-tg/def456
```

### Step 16: Set Up Auto Scaling (Free Tier Optimized)

```bash
# Get the latest ECS-optimized AMI ID
aws ssm get-parameters \
  --names /aws/service/ecs/optimized-ami/amazon-linux-2/recommended \
  --query "Parameters[0].Value" \
  --output text | jq -r '.image_id'
# Note the AMI ID (e.g., ami-0a1b2c3d4e)

# Create a launch template using t2.micro (Free Tier eligible)
aws ec2 create-launch-template \
  --launch-template-name cold-email-lt \
  --version-description v1 \
  --launch-template-data '{
    "ImageId": "ami-0a1b2c3d4e",
    "InstanceType": "t2.micro",
    "SecurityGroupIds": ["sg-0e4d3c2b1a"],
    "IamInstanceProfile": {
      "Name": "ecsInstanceProfile"
    },
    "UserData": "'"$(echo -n '#!/bin/bash
echo ECS_CLUSTER=cold-email-cluster >> /etc/ecs/ecs.config' | base64)"'"
  }'
# Note the LaunchTemplateId in the output

# Create the auto scaling group with Free Tier optimized settings
aws autoscaling create-auto-scaling-group \
  --auto-scaling-group-name cold-email-asg \
  --launch-template LaunchTemplateId=lt-0a1b2c3d4e,Version='$Latest' \
  --min-size 1 \
  --max-size 3 \
  --desired-capacity 1 \
  --vpc-zone-identifier "subnet-0f5e4d3c2b,subnet-0b1a2c3d4e" \
  --target-group-arns "arn:aws:elasticloadbalancing:us-east-1:975050280075:targetgroup/cold-email-tg/def456" \
  --health-check-type ELB \
  --health-check-grace-period 300

# Create CPU-based scaling policy to optimize resource usage
aws autoscaling put-scaling-policy \
  --auto-scaling-group-name cold-email-asg \
  --policy-name cpu-tracking-policy \
  --policy-type TargetTrackingScaling \
  --target-tracking-configuration '{
    "PredefinedMetricSpecification": {
      "PredefinedMetricType": "ASGAverageCPUUtilization"
    },
    "TargetValue": 70.0
  }'
```

## Phase 5: CI/CD Pipeline Configuration

### Step 17: Create S3 Bucket for CodePipeline Artifacts (Free Tier Optimized)

```bash
# Create an S3 bucket for CodePipeline artifacts
aws s3 mb s3://cold-email-pipeline-artifacts-975050280075

# Enable versioning on the bucket
aws s3api put-bucket-versioning \
  --bucket cold-email-pipeline-artifacts-975050280075 \
  --versioning-configuration Status=Enabled

# Set up lifecycle policy to delete old artifacts (to stay within Free Tier storage limits)
aws s3api put-bucket-lifecycle-configuration \
  --bucket cold-email-pipeline-artifacts-975050280075 \
  --lifecycle-configuration '{
    "Rules": [
      {
        "ID": "Delete old artifacts",
        "Status": "Enabled",
        "Expiration": {
          "Days": 7
        },
        "Prefix": ""
      }
    ]
  }'
```

### Step 18: Create CodeBuild Project

```bash
# Create a CodeBuild project
aws codebuild create-project \
  --name cold-email-build \
  --source '{
    "type": "GITHUB",
    "location": "https://github.com/your-username/cold-email-generator.git",
    "gitCloneDepth": 1,
    "buildspec": "buildspec.yml",
    "reportBuildStatus": true
  }' \
  --artifacts '{
    "type": "S3",
    "location": "cold-email-pipeline-artifacts-975050280075",
    "packaging": "ZIP",
    "name": "BuildArtifact.zip"
  }' \
  --environment '{
    "type": "LINUX_CONTAINER",
    "image": "aws/codebuild/amazonlinux2-x86_64-standard:3.0",
    "computeType": "BUILD_GENERAL1_SMALL",
    "privilegedMode": true,
    "environmentVariables": [
      {"name": "AWS_DEFAULT_REGION", "value": "us-east-1"},
      {"name": "AWS_ACCOUNT_ID", "value": "975050280075"}
    ]
  }' \
  --service-role "arn:aws:iam::975050280075:role/codeBuildServiceRole"
```

### Step 19: Create CodeDeploy Application and Deployment Group

```bash
# Create a CodeDeploy application
aws deploy create-application \
  --application-name cold-email-deploy \
  --compute-platform ECS

# Create a deployment group
aws deploy create-deployment-group \
  --application-name cold-email-deploy \
  --deployment-group-name cold-email-deploy-group \
  --deployment-config-name CodeDeployDefault.ECSAllAtOnce \
  --service-role-arn arn:aws:iam::975050280075:role/codePipelineServiceRole \
  --ecs-services "{\"clusterName\": \"cold-email-cluster\", \"serviceName\": \"cold-email-service\"}" \
  --load-balancer-info "{\"targetGroupPairInfoList\": [{\"targetGroups\": [{\"name\": \"cold-email-tg\"}], \"prodTrafficRoute\": {\"listenerArns\": [\"arn:aws:elasticloadbalancing:us-east-1:975050280075:listener/app/cold-email-lb/abc123/def456\"]}}]}"
```

### Step 20: Create CodePipeline

```bash
# Create a pipeline
aws codepipeline create-pipeline \
  --pipeline '{
    "name": "cold-email-pipeline",
    "roleArn": "arn:aws:iam::975050280075:role/codePipelineServiceRole",
    "artifactStore": {
      "type": "S3",
      "location": "cold-email-pipeline-artifacts-975050280075"
    },
    "stages": [
      {
        "name": "Source",
        "actions": [
          {
            "name": "Source",
            "actionTypeId": {
              "category": "Source",
              "owner": "AWS",
              "provider": "CodeStarSourceConnection",
              "version": "1"
            },
            "configuration": {
              "ConnectionArn": "arn:aws:codestar-connections:us-east-1:975050280075:connection/your-connection-id",
              "FullRepositoryId": "your-username/cold-email-generator",
              "BranchName": "main"
            },
            "outputArtifacts": [
              {
                "name": "SourceCode"
              }
            ]
          }
        ]
      },
      {
        "name": "Build",
        "actions": [
          {
            "name": "BuildAndPush",
            "actionTypeId": {
              "category": "Build",
              "owner": "AWS",
              "provider": "CodeBuild",
              "version": "1"
            },
            "configuration": {
              "ProjectName": "cold-email-build"
            },
            "inputArtifacts": [
              {
                "name": "SourceCode"
              }
            ],
            "outputArtifacts": [
              {
                "name": "BuildOutput"
              }
            ]
          }
        ]
      },
      {
        "name": "Deploy",
        "actions": [
          {
            "name": "Deploy",
            "actionTypeId": {
              "category": "Deploy",
              "owner": "AWS",
              "provider": "CodeDeployToECS",
              "version": "1"
            },
            "configuration": {
              "ApplicationName": "cold-email-deploy",
              "DeploymentGroupName": "cold-email-deploy-group",
              "TaskDefinitionTemplateArtifact": "BuildOutput",
              "AppSpecTemplateArtifact": "BuildOutput",
              "Image1ArtifactName": "BuildOutput",
              "Image1ContainerName": "IMAGE_NAME"
            },
            "inputArtifacts": [
              {
                "name": "BuildOutput"
              }
            ]
          }
        ]
      }
    ]
  }'
```

## Phase 6: ECS Service Creation and Final Setup

### Step 21: Register the Task Definition

```bash
# Register the task definition (with placeholders replaced)
aws ecs register-task-definition \
  --cli-input-json "$(cat taskdef.json | sed 's/<IMAGE_NAME>/975050280075.dkr.ecr.us-east-1.amazonaws.com\/cold-email-generator:latest/g')"
```

### Step 22: Create ECS Service

```bash
# Create an ECS service
aws ecs create-service \
  --cluster cold-email-cluster \
  --service-name cold-email-service \
  --task-definition cold-email-generator:1 \
  --desired-count 1 \
  --launch-type EC2 \
  --network-configuration "awsvpcConfiguration={subnets=[subnet-0f5e4d3c2b,subnet-0b1a2c3d4e],securityGroups=[sg-0e4d3c2b1a],assignPublicIp=DISABLED}" \
  --load-balancers "targetGroupArn=arn:aws:elasticloadbalancing:us-east-1:975050280075:targetgroup/cold-email-tg/def456,containerName=app,containerPort=8501" \
  --health-check-grace-period-seconds 300 \
  --deployment-controller type=CODE_DEPLOY \
  --scheduling-strategy REPLICA
```

### Step 23: Verify and Test the Deployment

```bash
# Trigger the pipeline
aws codepipeline start-pipeline-execution --name cold-email-pipeline

# Get the DNS name of your load balancer
aws elbv2 describe-load-balancers \
  --names cold-email-lb \
  --query "LoadBalancers[0].DNSName" \
  --output text
```

## Phase 7: Monitoring and Maintenance (Free Tier Optimized)

### Step 24: Set Up CloudWatch Alarms (Limited to Free Tier)

```bash
# Create CPU utilization alarm (stays within 10 free alarms)
aws cloudwatch put-metric-alarm \
  --alarm-name cold-email-cpu-alarm \
  --alarm-description "Alarm when CPU exceeds 80%" \
  --metric-name CPUUtilization \
  --namespace AWS/EC2 \
  --statistic Average \
  --period 300 \
  --threshold 80 \
  --comparison-operator GreaterThanThreshold \
  --dimensions "Name=AutoScalingGroupName,Value=cold-email-asg" \
  --evaluation-periods 2 \
  --alarm-actions "arn:aws:autoscaling:us-east-1:975050280075:scalingPolicy:policy-id:autoScalingGroupName/cold-email-asg:policyName/cpu-tracking-policy"

# Create memory utilization alarm
aws cloudwatch put-metric-alarm \
  --alarm-name cold-email-memory-alarm \
  --alarm-description "Alarm when memory exceeds 80%" \
  --metric-name MemoryUtilization \
  --namespace AWS/ECS \
  --statistic Average \
  --period 300 \
  --threshold 80 \
  --comparison-operator GreaterThanThreshold \
  --dimensions "Name=ClusterName,Value=cold-email-cluster Name=ServiceName,Value=cold-email-service" \
  --evaluation-periods 2 \
  --alarm-actions "arn:aws:autoscaling:us-east-1:975050280075:scalingPolicy:policy-id:autoScalingGroupName/cold-email-asg:policyName/cpu-tracking-policy"

# Create billing alarm to ensure you stay within Free Tier limits
aws cloudwatch put-metric-alarm \
  --alarm-name cold-email-billing-alarm \
  --alarm-description "Alarm when estimated charges exceed $5 USD" \
  --metric-name EstimatedCharges \
  --namespace AWS/Billing \
  --statistic Maximum \
  --period 21600 \
  --threshold 5 \
  --comparison-operator GreaterThanThreshold \
  --dimensions "Name=Currency,Value=USD" \
  --evaluation-periods 1 \
  --alarm-actions "arn:aws:sns:us-east-1:975050280075:billing-alarm-topic"
```

### Step 25: Set Up a Budget Alert (for Free Tier Management)

```bash
# Create a budget to track AWS Free Tier usage
aws budgets create-budget \
  --account-id 975050280075 \
  --budget '{
    "BudgetName": "FreeHoursTracking",
    "BudgetLimit": {
      "Amount": "0",
      "Unit": "USD"
    },
    "BudgetType": "COST",
    "CostFilters": {
      "Service": ["Amazon Elastic Compute Cloud - Compute"]
    },
    "CostTypes": {
      "IncludeTax": true,
      "IncludeSubscription": true,
      "UseBlended": false,
      "IncludeRefund": false,
      "IncludeCredit": false,
      "IncludeDiscount": true,
      "UseAmortized": false
    },
    "TimeUnit": "MONTHLY"
  }'

# Create a notification for the budget
aws budgets create-notification \
  --account-id 975050280075 \
  --budget-name FreeHoursTracking \
  --notification '{
    "NotificationType": "ACTUAL",
    "ComparisonOperator": "GREATER_THAN",
    "Threshold": 80,
    "ThresholdType": "PERCENTAGE",
    "NotificationState": "ALARM"
  }' \
  --subscribers '[
    {
      "SubscriptionType": "EMAIL",
      "Address": "your-email@example.com"
    }
  ]'
```

### Step 26: Set Up Scheduled Auto Scaling (Critical for Free Tier Optimization)

```bash
# Create a scheduled action to scale down during off-hours
aws autoscaling put-scheduled-update-group-action \
  --auto-scaling-group-name cold-email-asg \
  --scheduled-action-name scale-down-night \
  --min-size 0 \
  --max-size 1 \
  --desired-capacity 0 \
  --recurrence "0 20 * * *"  # 8 PM UTC every day

# Create a scheduled action to scale up during business hours
aws autoscaling put-scheduled-update-group-action \
  --auto-scaling-group-name cold-email-asg \
  --scheduled-action-name scale-up-morning \
  --min-size 1 \
  --max-size 3 \
  --desired-capacity 1 \
  --recurrence "0 8 * * 1-5"  # 8 AM UTC Monday-Friday
```

## Phase 8: Additional Optimizations and Enhancements (Free Tier Friendly)

### Step 27: Set Up Route 53 for Custom Domain (Optional)

```bash
# Create a hosted zone (if you don't already have one)
aws route53 create-hosted-zone \
  --name yourdomain.com \
  --caller-reference "$(date +%s)"

# Create a record set for your application
aws route53 change-resource-record-sets \
  --hosted-zone-id YOUR_HOSTED_ZONE_ID \
  --change-batch '{
    "Changes": [
      {
        "Action": "CREATE",
        "ResourceRecordSet": {
          "Name": "email-generator.yourdomain.com",
          "Type": "A",
          "AliasTarget": {
            "HostedZoneId": "Z35SXDOTRQ7X7K",
            "DNSName": "YOUR_ALB_DNS_NAME",
            "EvaluateTargetHealth": true
          }
        }
      }
    ]
  }'
```

### Step 28: Set Up AWS Backup for Persistent Data (Optional, Minimal Configuration)

```bash
# Create a backup plan with minimal retention to stay within Free Tier
aws backup create-backup-plan \
  --backup-plan '{
    "BackupPlanName": "cold-email-daily-backup",
    "Rules": [
      {
        "RuleName": "daily-backup-rule",
        "TargetBackupVaultName": "Default",
        "ScheduleExpression": "cron(0 0 * * ? *)",
        "StartWindowMinutes": 60,
        "CompletionWindowMinutes": 120,
        "Lifecycle": {
          "DeleteAfterDays": 7
        }
      }
    ]
  }'

# Create a selection of resources to backup
aws backup create-backup-selection \
  --backup-plan-id $(aws backup list-backup-plans --query "BackupPlansList[?BackupPlanName=='cold-email-daily-backup'].BackupPlanId" --output text) \
  --backup-selection '{
    "SelectionName": "cold-email-resources",
    "IamRoleArn": "arn:aws:iam::975050280075:role/AWSBackupDefaultServiceRole",
    "Resources": [
      "arn:aws:s3:::cold-email-generator-data"
    ]
  }'
```

## Phase 9: Final Verification and Documentation

### Step 29: Test End-to-End Pipeline

```bash
# Make a change to your code
cd cold-email-generator
echo "# Updated on $(date)" >> README.md

# Commit and push the change
git add README.md
git commit -m "Test pipeline with a simple update"
git push origin main

# Check the pipeline status
aws codepipeline get-pipeline-state --name cold-email-pipeline
```

### Step 30: Create CloudWatch Dashboard for Monitoring (Free Tier Optimized)

```bash
# Create a simple CloudWatch dashboard with essential metrics
aws cloudwatch put-dashboard \
  --dashboard-name cold-email-dashboard \
  --dashboard-body '{
    "widgets": [
        {
            "type": "metric",
            "x": 0,
            "y": 0,
            "width": 12,
            "height": 6,
            "properties": {
                "metrics": [
                    [ "AWS/EC2", "CPUUtilization", "AutoScalingGroupName", "cold-email-asg" ]
                ],
                "period": 300,
                "stat": "Average",
                "region": "us-east-1",
                "title": "EC2 CPU Utilization"
            }
        },
        {
            "type": "metric",
            "x": 0,
            "y": 6,
            "width": 12,
            "height": 6,
            "properties": {
                "metrics": [
                    [ "AWS/ECS", "MemoryUtilization", "ClusterName", "cold-email-cluster", "ServiceName", "cold-email-service" ]
                ],
                "period": 300,
                "stat": "Average",
                "region": "us-east-1",
                "title": "ECS Memory Utilization"
            }
        },
        {
            "type": "metric",
            "x": 12,
            "y": 0,
            "width": 12,
            "height": 6,
            "properties": {
                "metrics": [
                    [ "AWS/ApplicationELB", "RequestCount", "LoadBalancer", "YOUR_ALB_NAME" ]
                ],
                "period": 60,
                "stat": "Sum",
                "region": "us-east-1",
                "title": "ALB Request Count"
            }
        }
    ]
  }'
```

## Phase 10: Documentation and Maintenance Schedule

### Step 31: Document Infrastructure and Processes

Create a comprehensive README.md file in your GitHub repository with the following sections:

#### 1. Architecture Overview

```markdown
# Cold Email Generator AWS Infrastructure

## Architecture Overview

This application is deployed on AWS with the following components:

- **Compute**: Amazon ECS on EC2 (t2.micro instances for Free Tier eligibility)
- **Container Registry**: Amazon ECR
- **Load Balancing**: Application Load Balancer
- **Auto Scaling**: EC2 Auto Scaling Group with scheduled scaling to minimize Free Tier usage
- **CI/CD**: GitHub + CodeBuild + CodeDeploy + CodePipeline
- **Storage**: S3 for artifacts with lifecycle policies to minimize storage
- **Monitoring**: CloudWatch (basic monitoring to stay within Free Tier)
- **Secret Management**: Systems Manager Parameter Store

![Architecture Diagram](path/to/diagram.png)
```

#### 2. Deployment Process

```markdown
## Deployment Process

The deployment process follows these steps:

1. Code is committed to the GitHub repository
2. CodePipeline detects changes and triggers a new pipeline execution
3. CodeBuild builds a Docker image and pushes it to ECR
4. CodeDeploy performs a blue/green deployment to ECS
5. Traffic is automatically shifted to the new version

### Manual Deployment

To manually trigger a deployment:

```bash
aws codepipeline start-pipeline-execution --name cold-email-pipeline
```
```

#### 3. Free Tier Maintenance Tasks

```markdown
## Maintenance Schedule for Free Tier Optimization

| Task | Frequency | Description |
|------|-----------|-------------|
| Security Updates | Monthly | Check for security updates in dependencies |
| Cost Review | Weekly | Review AWS costs and optimize resources to stay within Free Tier |
| EC2 Hours Check | Weekly | Ensure you're not approaching the 750 hours/month limit |
| S3 Storage Check | Weekly | Ensure you're not exceeding 5GB of storage |
| Backup Testing | Quarterly | Test restoration from backups |
| Performance Review | Quarterly | Analyze CloudWatch metrics for performance issues |
```

### Step 32: Set Up a Free Tier Usage Calendar Reminder

Create calendar reminders for:

1. **Daily Check** (5 minutes):
   - Verify application health
   - Check CloudWatch alarms
   - Verify EC2 instances are scaling down during off-hours

2. **Weekly Check** (15 minutes):
   - Review CloudWatch metrics
   - Check auto-scaling activity
   - Verify backup success
   - **Check Free Tier usage** for EC2 hours, S3 storage, and data transfer

3. **Monthly Check** (30 minutes):
   - Review AWS billing and costs
   - Check free tier usage in detail
   - Identify optimization opportunities
   - Run security scans
   - Adjust scheduled scaling if needed based on usage patterns

## Free Tier Optimization Checklist

To ensure you're maximizing AWS Free Tier benefits:

1. **EC2 Usage** (750 hours per month free):
   - Auto scaling group configured to use only t2.micro instances
   - Scheduled scaling to shut down instances during off-hours
   - Budget alert set to notify when approaching 750 hours/month
   - Consider running just 1 instance (744 hours in a 31-day month)
   - Track usage with the AWS Cost Explorer

2. **S3 Storage** (5GB free):
   - Monitor usage to stay below 5GB
   - Set up lifecycle policies to delete old artifacts after 7 days
   - Use versioning selectively to avoid multiplying storage needs
   - Consider compressing artifacts to reduce storage needs

3. **Load Balancer** (not covered by Free Tier):
   - Consider using a single EC2 instance with an Elastic IP during development
   - Switch to ALB only for production or peak usage periods
   - If cost is a primary concern, you can modify the architecture to use a single EC2 instance with an Elastic IP instead of ALB

4. **CloudWatch** (10 metrics, 10 alarms, 1 million API requests free):
   - Stay within 10 free alarms
   - Use basic monitoring (5-minute intervals) instead of detailed monitoring
   - Be selective with custom metrics

5. **CodePipeline/CodeBuild** (limited Free Tier):
   - Stay within 1 active pipeline
   - Monitor build minutes to stay below 100 minutes/month
   - Consider manual deployments if you exceed Free Tier build minutes

6. **Data Transfer** (1 GB free outbound):
   - Monitor outbound traffic carefully
   - Set up CloudWatch alarms for data transfer
   - Consider caching to reduce data transfer

7. **NAT Gateway** (not covered by Free Tier):
   - For development, consider removing the NAT Gateway and using an EC2 Bastion Host instead
   - If your workload allows, schedule tasks to run during business hours when instances are up

8. **ECS** (free, but underlying EC2 instances are counted toward EC2 Free Tier):
   - Optimize task definitions to ensure minimal resource usage
   - Use efficient Docker images to reduce memory and CPU requirements

## Troubleshooting Common Issues

### EC2 Instance Not Joining ECS Cluster

Check the following:
- User data script is correctly configured
- IAM role has proper permissions
- Security groups allow necessary traffic
- View instance logs: `aws ec2 get-console-output --instance-id i-1234567890abcdef0`

### Container Health Check Failures

Check the following:
- CloudWatch logs for container errors
- Container port mappings are correct
- Application is running properly inside container
- Health check path is accessible

### CodePipeline Failures

Check the following:
- IAM roles have proper permissions
- S3 bucket is accessible
- GitHub connection is active
- Check CodeBuild logs for build errors

### Load Balancer Not Routing Traffic

Check the following:
- Target group health checks are passing
- Security groups allow traffic on port 8501
- ECS service is running successfully
- Check ALB access logs for any issues

### Free Tier Limits Exceeded

Check the following:
- Review AWS Cost Explorer to identify resources exceeding Free Tier
- Check EC2 instance running hours (should stay under 750 hours/month)
- Ensure scheduled scaling actions are working correctly
- Verify S3 storage is under 5GB and lifecycle policies are working
- Consider switching to more cost-effective architecture if consistently exceeding Free Tier

## Free Tier Alternative Architecture

If you find yourself consistently exceeding Free Tier limits, consider this simplified architecture:

1. **Single t2.micro EC2 instance** with Elastic IP instead of ALB + Auto Scaling Group
2. **Docker** running directly on the EC2 instance instead of ECS
3. **GitHub Actions** for CI/CD instead of CodePipeline + CodeBuild
4. **Manual scaling** during peak times instead of auto scaling

Commands for this simplified setup:

```bash
# Launch a single t2.micro instance with user data to install Docker
aws ec2 run-instances \
  --image-id ami-0a1b2c3d4e \
  --instance-type t2.micro \
  --key-name YourKeyPair \
  --security-group-ids sg-0e4d3c2b1a \
  --subnet-id subnet-0a1b2c3d4e \
  --user-data "$(cat <<EOF
#!/bin/bash
yum update -y
amazon-linux-extras install docker -y
service docker start
systemctl enable docker
EOF
)"

# Allocate and associate an Elastic IP
aws ec2 allocate-address --domain vpc
aws ec2 associate-address --instance-id i-1234567890abcdef0 --allocation-id eipalloc-0a1b2c3d4e
```

## Conclusion

By following this comprehensive guide, you've set up a production-ready deployment pipeline for your Cold Email Generator application on AWS, optimized to stay within Free Tier limits. The infrastructure includes:

1. **A robust CI/CD pipeline** that automatically builds and deploys your application whenever you push changes to GitHub
2. **Auto-scaling capabilities** that adjust capacity based on demand, with scheduled scaling to minimize costs
3. **High availability** through multiple Availability Zones when needed
4. **Monitoring and alerting** to ensure you're notified of any issues
5. **Cost optimization features** to help you stay within AWS Free Tier limits

This deployment architecture follows AWS best practices for security, reliability, and performance while being mindful of costs for a side project or small business application.

Remember to regularly review and update your infrastructure as your application's needs evolve and as AWS introduces new features and services that might better suit your requirements.

---

## Additional Resources

- [AWS Free Tier Documentation](https://aws.amazon.com/free/)
- [AWS Cost Management Tools](https://aws.amazon.com/aws-cost-management/)
- [ECS Documentation](https://docs.aws.amazon.com/ecs/index.html)
- [CodePipeline Documentation](https://docs.aws.amazon.com/codepipeline/index.html)
- [Docker Documentation](https://docs.docker.com/)
- [GitHub Actions as an Alternative to CodePipeline](https://docs.github.com/en/actions)

---

**Note**: Replace placeholder values (like subnet IDs, security group IDs, etc.) with your actual resource IDs. This guide assumes you're deploying in the us-east-1 region; modify region references if deploying elsewhere. 