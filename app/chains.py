"""Chain definitions for the application."""

import os
import time
import signal
from typing import List, Dict, Any
from dotenv import load_dotenv
from langchain_groq import ChatGroq
from langchain_core.prompts import ChatPromptTemplate
from langchain_core.output_parsers import JsonOutputParser
from langchain_community.document_loaders import WebBaseLoader

load_dotenv()

# Configure WebBaseLoader with user agent
WebBaseLoader.requests_kwargs = {
    'headers': {
        'User-Agent': (
            os.getenv('USER_AGENT',
                      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
                      'AppleWebKit/537.36 (KHTML, like Gecko) '
                      'Chrome/122.0.0.0 Safari/537.36')
        )
    },
    'timeout': 30  # Add global timeout
}

# Timeout handler
class TimeoutError(Exception):
    pass

def timeout_handler(signum, frame):
    raise TimeoutError("Operation timed out")


class EmailChain:
    """Chain for generating cold emails."""

    def __init__(self, groq_api_key: str):
        """Initialize the email chain.

        Args:
            groq_api_key: The GROQ API key for authentication
        """
        self.llm = ChatGroq(
            groq_api_key=groq_api_key,
            model_name="mixtral-8x7b-32768",
            temperature=0.7,
            max_tokens=4096,  # Reduced to prevent hanging
            timeout=60  # 60 second timeout
        )

        # Create the email prompt
        self.prompt = ChatPromptTemplate.from_messages([
            ("system", """You are an expert at writing cold emails for job applications.
            Write a professional, personalized cold email based on the provided information.
            The email should:
            1. Be concise and engaging (max 3-4 paragraphs)
            2. Start with a strong opening that grabs attention
            3. Highlight relevant skills and experience
            4. Show enthusiasm for the role and company
            5. Include a clear call to action
            6. Be professional but conversational in tone
            7. End with a polite closing
            
            Format the email in markdown with proper paragraphs and line breaks."""),
            ("human", """Recipient Information:
            {recipient_info}
            
            Sender Information:
            {sender_info}
            
            Purpose:
            {purpose}""")
        ])
        
        # Create the chain using RunnableSequence pattern
        self.chain = self.prompt | self.llm

    def generate_email(
        self,
        recipient_info: str,
        sender_info: str,
        purpose: str
    ) -> str:
        """Generate a cold email.

        Args:
            recipient_info: Information about the recipient
            sender_info: Information about the sender
            purpose: The purpose of the email

        Returns:
            The generated email text
        """
        try:
            # Set timeout
            signal.signal(signal.SIGALRM, timeout_handler)
            signal.alarm(60)  # 60 second timeout
            
            start_time = time.time()
            print("Starting email generation...")
            
            # Generate email
            result = self.chain.invoke({
                "recipient_info": recipient_info,
                "sender_info": sender_info,
                "purpose": purpose
            })
            
            # Cancel timeout
            signal.alarm(0)
            
            print(f"Email generation completed in {time.time() - start_time:.2f} seconds")
            
            # Extract content from result
            email_content = result.content if hasattr(result, 'content') else str(result)
            
            # Validate email content
            if not email_content or len(email_content.strip()) < 50:
                print("Warning: Generated email is too short or empty")
                return "Error: Failed to generate a proper email. Please try again."
            
            return email_content
        except TimeoutError:
            print("Email generation timed out after 60 seconds")
            return "Email generation timed out. Please try again with a simpler request."
        except Exception as e:
            print(f"Error generating email: {e}")
            return f"Error generating email: {str(e)}. Please try again."


class Chain:
    """Chain for extracting job information and generating emails."""
    
    def __init__(self):
        """Initialize the chain with Groq LLM."""
        self.llm = ChatGroq(
            api_key=os.getenv("GROQ_API_KEY"),
            model_name="mixtral-8x7b-32768",
            temperature=0.7,
            max_tokens=4096,  # Reduced to prevent hanging
            top_p=1,
            verbose=True,
            timeout=60  # 60 second timeout
        )
        
        # Create the job extraction prompt
        self.job_prompt = ChatPromptTemplate.from_messages([
            ("system", """You are a job information extractor. Extract key details from job postings.
            Return the information in a structured JSON format with the following fields:
            - title: Job title
            - company: Company name
            - location: Job location
            - experience: Required experience
            - skills: List of required skills
            - description: Brief job description
            
            If any field is not found, use null or an empty list.
            Make sure to extract all relevant information from the job posting."""),
            ("human", "{text}")
        ])
        
        # Create the email generation prompt
        self.email_prompt = ChatPromptTemplate.from_messages([
            ("system", """You are an expert at writing cold emails for job applications.
            Write a professional, personalized cold email based on the job details and portfolio links.
            The email should:
            1. Be concise and engaging (max 3-4 paragraphs)
            2. Start with a strong opening that grabs attention
            3. Highlight relevant skills and experience that match the job requirements
            4. Show enthusiasm for the role and company
            5. Include a clear call to action
            6. Be professional but conversational in tone
            7. End with a polite closing
            
            Format the email in markdown with proper paragraphs and line breaks."""),
            ("human", """Job Details:
            {job_details}
            
            Portfolio Links:
            {portfolio_links}""")
        ])
        
        # Create the chains
        self.job_chain = self.job_prompt | self.llm | JsonOutputParser()
        self.email_chain = self.email_prompt | self.llm
    
    def extract_jobs(self, text: str) -> List[Dict[str, Any]]:
        """Extract job information from text."""
        try:
            # Print debugging info
            print(f"Text length for job extraction: {len(text)}")
            
            # Limit text length if too long
            if len(text) > 5000:  # Reduced further to prevent hanging
                print(f"Truncating text from {len(text)} to 5000 characters")
                text = text[:5000]
            
            # Set timeout
            signal.signal(signal.SIGALRM, timeout_handler)
            signal.alarm(60)  # 60 second timeout
            
            # Add a timeout to prevent hanging
            start_time = time.time()
            print("Starting job extraction...")
            
            # Invoke the job chain
            result = self.job_chain.invoke({"text": text})
            
            # Cancel timeout
            signal.alarm(0)
            
            # Log completion time
            print(f"Job extraction completed in {time.time() - start_time:.2f} seconds")
            
            if not result:
                print("No job details extracted from text")
                return []
            
            # Ensure result is a list
            jobs = [result] if isinstance(result, dict) else result
            
            # Validate and clean job data
            for job in jobs:
                if not job.get('title'):
                    print("Warning: Job title missing")
                    # Try to set a default title based on the text
                    job['title'] = "Untitled Position"
                    
                if not job.get('company'):
                    print("Warning: Company name missing")
                    job['company'] = "Unknown Company"
                    
                if not job.get('skills'):
                    print("Warning: No skills extracted")
                    # Extract potential skills using simple keyword matching
                    common_skills = ["python", "java", "javascript", "sql", "aws", "azure", 
                                   "communication", "leadership", "react", "node", "html", 
                                   "css", "data analysis", "machine learning", "ai"]
                    extracted_skills = []
                    for skill in common_skills:
                        if skill.lower() in text.lower():
                            extracted_skills.append(skill)
                    
                    job['skills'] = extracted_skills or ["Not specified"]
            
            print(f"Extracted {len(jobs)} job(s)")
            return jobs
        except TimeoutError:
            print("Job extraction timed out after 60 seconds")
            return [{
                'title': 'Job Information Extraction Timed Out',
                'company': 'Unknown',
                'location': 'Unknown',
                'experience': 'Not specified',
                'skills': ['Not available due to timeout'],
                'description': 'The job extraction process timed out. Try again with a simpler job posting.'
            }]
        except Exception as e:
            print(f"Error extracting jobs: {e}")
            # Create a minimal job record to allow the process to continue
            return [{
                'title': 'Information Not Available',
                'company': 'Company Not Found',
                'location': 'Unknown',
                'experience': 'Not specified',
                'skills': ['Not available'],
                'description': 'Could not extract job details. Please check the URL or try a different job posting.'
            }]
    
    def write_mail(self, job: Dict[str, Any], links: List[str]) -> str:
        """Generate a cold email based on job details and portfolio links."""
        try:
            # Format job details for the prompt
            job_details = f"""
            Title: {job.get('title', 'N/A')}
            Company: {job.get('company', 'N/A')}
            Location: {job.get('location', 'N/A')}
            Experience: {job.get('experience', 'N/A')}
            Skills Required: {', '.join(job.get('skills', []))}
            Description: {job.get('description', 'N/A')}
            """
            
            # Format portfolio links
            portfolio_links = "\n".join(links) if links else "No portfolio links available"
            
            # Set timeout
            signal.signal(signal.SIGALRM, timeout_handler)
            signal.alarm(60)  # 60 second timeout
            
            start_time = time.time()
            print("Starting email generation...")
            
            # Generate email
            result = self.email_chain.invoke({
                "job_details": job_details,
                "portfolio_links": portfolio_links
            })
            
            # Cancel timeout
            signal.alarm(0)
            
            print(f"Email generation completed in {time.time() - start_time:.2f} seconds")
            
            # Extract content from result
            email_content = result.content if hasattr(result, 'content') else str(result)
            
            # Validate email content
            if not email_content or len(email_content.strip()) < 50:
                print("Warning: Generated email is too short or empty")
                return "Error: Failed to generate a proper email. Please try again."
            
            return email_content
        except TimeoutError:
            print("Email generation timed out after 60 seconds")
            return "Email generation timed out. Please try again with a simpler request."
        except Exception as e:
            print(f"Error generating email: {e}")
            return "Error generating email. Please try again."


if __name__ == "__main__":
    print(os.getenv("GROQ_API_KEY"))