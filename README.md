# 📧 Cold Mail Generator
Cold email generator for services company using groq, langchain and streamlit. It allows users to input the URL of a company's careers page. The tool then extracts job listings from that page and generates personalized cold emails. These emails include relevant portfolio links sourced from a vector database, based on the specific job descriptions. 

**Imagine a scenario:**

- Nike needs a Principal Software Engineer and is spending time and resources in the hiring process, on boarding, training etc
- Atliq is Software Development company can provide a dedicated software development engineer to Nike. So, the business development executive (Mohan) from Atliq is going to reach out to Nike via a cold email.

![img.png](imgs/img.png)

## Architecture Diagram
![img.png](imgs/architecture.png)

## Set-up
1. To get started we first need to get an API_KEY from here: https://console.groq.com/keys. Inside `app/.env` update the value of `GROQ_API_KEY` with the API_KEY you created. 


2. To get started, first install the dependencies using:
    ```commandline
     pip install -r requirements.txt
    ```
   
3. Run the streamlit app:
   ```commandline
   streamlit run app/main.py
   ```
   

Copyright (C) Codebasics Inc. All rights reserved.

**Additional Terms:**
This software is licensed under the MIT License. However, commercial use of this software is strictly prohibited without prior written permission from the author. Attribution must be given in all copies or substantial portions of the software.

## Cold Email Generator

This application leverages AI to create personalized cold emails for your job applications. It helps automate the process of crafting tailored messages based on your portfolio and the job description.

### Features

- **Personalized Email Generation**: Creates customized emails using AI
- **Portfolio Integration**: References your portfolio items that are relevant to the job
- **User-friendly Interface**: Simple Streamlit web interface

### Deployment Options

This project can be deployed in multiple ways:

1. **Local Development**:
   ```
   pip install -r requirements.txt
   streamlit run app/main.py
   ```

2. **Docker**:
   ```
   docker build -t cold-email-generator .
   docker run -p 8501:8501 cold-email-generator
   ```

3. **AWS with Kubernetes**:
   For production deployment with autoscaling and load balancing, see the [deployment instructions](deploy/README.md).

### GitHub Actions CI/CD

This project includes a GitHub Actions workflow for automated deployment to AWS with Kubernetes. The workflow:

1. Validates the application
2. Builds and pushes a Docker image to GitHub Container Registry
3. Sets up AWS infrastructure (VPC, subnets, load balancer, auto-scaling group)
4. Deploys the application to Kubernetes
5. Monitors the deployment

See the [deployment directory](deploy/) for detailed instructions.

### Environment Variables

- `GROQ_API_KEY`: Your Groq API key for accessing the LLM

### Technologies Used

- **Python/Streamlit**: For the web application
- **Groq API**: For LLM-based email generation
- **Docker**: For containerization
- **Kubernetes**: For orchestration
- **AWS**: For infrastructure (EC2, ASG, ALB)
- **GitHub Actions**: For CI/CD

### License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
