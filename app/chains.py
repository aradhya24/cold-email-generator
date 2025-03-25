"""Chain definitions for the application."""

import os
import time
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
    }
}


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
            max_tokens=8192
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
            start_time = time.time()
            print("Starting email generation...")
            
            # Generate email
            result = self.chain.invoke({
                "recipient_info": recipient_info,
                "sender_info": sender_info,
                "purpose": purpose
            })
            
            print(f"Email generation completed in {time.time() - start_time:.2f} seconds")
            
            # Extract content from result
            email_content = result.content if hasattr(result, 'content') else str(result)
            
            # Validate email content
            if not email_content or len(email_content.strip()) < 50:
                print("Warning: Generated email is too short or empty")
                return "Error: Failed to generate a proper email. Please try again."
            
            return email_content
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
            max_tokens=8192
        )
        
        # Create the job extraction prompt with improved instructions
        self.job_prompt = ChatPromptTemplate.from_messages([
            ("system", """You are an expert job information extractor. Your task is to carefully extract key details from job postings.
            
            Return the information in a structured JSON format with these fields:
            - title: The exact job title
            - company: Company name
            - location: Job location or remote status
            - experience: Required years of experience
            - skills: A comprehensive list of required skills and technologies
            - description: A concise summary of the job description
            
            Be thorough and extract as many relevant skills as possible. If information is not found, use null or an empty list.
            Ensure your response is valid JSON that can be parsed."""),
            ("human", "{text}")
        ])
        
        # Create the email generation prompt with improved instructions based on reference repo
        self.email_prompt = ChatPromptTemplate.from_messages([
            ("system", """You are Mohan, a business development executive at AtliQ.
            AtliQ is an AI & Software Consulting company dedicated to facilitating
            the seamless integration of business processes through automated tools.
            Over our experience, we have empowered numerous enterprises with
            tailored solutions, fostering scalability, process optimization,
            cost reduction, and heightened overall efficiency.
            
            Write a professional cold email to the hiring manager regarding the job description provided.
            The email should:
            1. Introduce yourself professionally as Mohan from AtliQ
            2. Reference the specific job posting by title and company
            3. Explain how AtliQ can provide excellent candidates or services for this position
            4. Highlight how AtliQ's expertise matches their requirements
            5. Include the portfolio links provided to showcase AtliQ's relevant work
            6. Include a clear call to action (like scheduling a meeting)
            7. End with a professional closing
            
            Keep the email concise (3-4 paragraphs) and focused on how AtliQ can help them fill their needs.
            Format the email as a proper business email with appropriate greeting and signature."""),
            ("human", """Job Description:
            {job_details}
            
            AtliQ Portfolio Links:
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
            
            # Process a reasonable length of text
            if len(text) > 8000:
                print(f"Truncating text from {len(text)} to 8000 characters")
                text = text[:8000]
            
            start_time = time.time()
            print("Starting job extraction...")
            
            # Invoke the job chain
            result = self.job_chain.invoke({"text": text})
            
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
            
            start_time = time.time()
            print("Starting email generation...")
            
            # Generate email
            result = self.email_chain.invoke({
                "job_details": job_details,
                "portfolio_links": portfolio_links
            })
            
            print(f"Email generation completed in {time.time() - start_time:.2f} seconds")
            
            # Extract content from result
            email_content = result.content if hasattr(result, 'content') else str(result)
            
            # Validate email content
            if not email_content or len(email_content.strip()) < 50:
                print("Warning: Generated email is too short or empty")
                return "Error: Failed to generate a proper email. Please try again."
            
            return email_content
        except Exception as e:
            print(f"Error generating email: {e}")
            return "Error generating email. Please try again."


if __name__ == "__main__":
    print(os.getenv("GROQ_API_KEY"))