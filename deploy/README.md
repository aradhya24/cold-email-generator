# Cold Email Generator Deployment

This directory contains all the scripts and configuration needed to deploy the Cold Email Generator application on AWS using Kubernetes with auto-scaling and load balancing.

## Deployment Architecture

The deployment architecture consists of:

1. **AWS Infrastructure**:
   - VPC with public subnets across availability zones
   - Auto Scaling Group with EC2 instances (t2.micro for Free Tier)
   - Application Load Balancer for traffic distribution
   - Security Groups for network access control

2. **Kubernetes Cluster**:
   - Self-managed Kubernetes on EC2 instances
   - Multiple pods with auto-scaling
   - Ingress controller for routing
   - Services for load balancing

3. **GitHub Actions Pipeline**:
   - Automated build and deployment
   - Infrastructure setup via workflow_dispatch
   - Continuous deployment for application changes

## Getting Started

### Prerequisites

- AWS account with appropriate permissions
- GitHub repository with the Cold Email Generator code
- SSH key pair for EC2 access
- Groq API key for application functionality

### GitHub Actions Setup

1. Configure GitHub Secrets in your repository's settings:
   - `AWS_ACCESS_KEY_ID`: Your AWS access key
   - `AWS_SECRET_ACCESS_KEY`: Your AWS secret key
   - `AWS_REGION`: Your AWS region (e.g., us-east-1)
   - `AWS_SSH_KEY`: Your private SSH key for EC2 access
   - `GROQ_API_KEY`: Your Groq API key for LLM functionality

2. Ensure the repository has the `.github/workflows/deploy.yml` file

3. Deploy the infrastructure:
   - Go to the Actions tab in your GitHub repository
   - Select the "Deploy Cold Email Generator" workflow
   - Click "Run workflow" and select "Run workflow" from the dropdown
   - This will trigger the entire pipeline including infrastructure setup

4. For subsequent deployments (after infrastructure is set up):
   - Push your changes to the main branch
   - The workflow will automatically build and deploy the updated application

## Manual Deployment

If you prefer to deploy manually without GitHub Actions:

1. Set up AWS infrastructure:
   ```bash
   chmod +x aws-k8s/aws-infrastructure.sh
   cd aws-k8s
   ./aws-infrastructure.sh
   ```

2. Find a healthy EC2 instance:
   ```bash
   chmod +x aws-k8s/get-healthy-instance.sh
   EC2_IP=$(./aws-k8s/get-healthy-instance.sh)
   ```

3. Set up Kubernetes on the instance:
   ```bash
   scp aws-k8s/k8s-setup.sh ubuntu@$EC2_IP:~/
   ssh ubuntu@$EC2_IP "chmod +x ~/k8s-setup.sh && GROQ_API_KEY=your-api-key ~/k8s-setup.sh"
   ```

4. Build and push the Docker image:
   ```bash
   docker build -t ghcr.io/yourusername/cold-email:latest .
   docker push ghcr.io/yourusername/cold-email:latest
   ```

5. Deploy the application:
   ```bash
   scp aws-k8s/k8s-deploy.sh ubuntu@$EC2_IP:~/
   ssh ubuntu@$EC2_IP "chmod +x ~/k8s-deploy.sh && DOCKER_IMAGE=ghcr.io/yourusername/cold-email:latest LB_DNS=your-lb-dns ~/k8s-deploy.sh"
   ```

## Directory Structure

```
aws-k8s/
├── aws-infrastructure.sh   # Script to set up AWS resources
├── get-healthy-instance.sh # Script to find a healthy EC2 instance
├── k8s-setup.sh           # Script to set up Kubernetes
└── k8s-deploy.sh          # Script to deploy the application
```

## Accessing the Application

After deployment, the application will be accessible via:

1. Load Balancer URL: `http://<LB_DNS>/`
2. Direct EC2 Node Port: `http://<EC2_IP>:<NODE_PORT>/`

## Cost Optimization

This setup is optimized for AWS Free Tier to minimize costs:

- Uses t2.micro EC2 instances within free tier limits
- Self-manages Kubernetes to avoid EKS costs
- Sets reasonable resource requests and limits for Kubernetes pods

## Troubleshooting

Common issues and their solutions:

1. **AWS Access Issues**:
   - Verify AWS credentials have sufficient permissions
   - Check that the region is specified correctly

2. **Kubernetes Setup Failures**:
   - Ensure instance has enough resources
   - Check system requirements for Kubernetes

3. **Application Deployment Issues**:
   - Verify Docker image is pushed correctly
   - Check Kubernetes pod logs for application errors 