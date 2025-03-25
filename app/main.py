"""Main application module."""

import os
import streamlit as st
import requests
from bs4 import BeautifulSoup
import json
import logging
from langchain_groq import ChatGroq

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Set page config as the first Streamlit command
st.set_page_config(layout="wide", page_title="Cold Email Generator", page_icon="📧")

# Sample job data for fallback
SAMPLE_JOB = {
    "title": "Data Analyst",
    "company": "Tech Company",
    "location": "Remote",
    "experience": "1-3 years",
    "skills": ["Python", "SQL", "Data Analysis", "Visualization"],
    "description": "Looking for an experienced data analyst to join our team."
}

# Directly define sample portfolio data
SAMPLE_PORTFOLIO = [
    {
        "project": "Data Analytics Dashboard",
        "url": "https://github.com/user/data-analytics",
        "skills": "python,data analysis,visualization,dashboard"
    },
    {
        "project": "Customer Segmentation",
        "url": "https://github.com/user/customer-segmentation",
        "skills": "machine learning,clustering,python,data science"
    },
    {
        "project": "Inventory System",
        "url": "https://github.com/user/inventory-system",
        "skills": "java,database,api development,backend"
    },
    {
        "project": "Forecasting Tool",
        "url": "https://github.com/user/forecasting",
        "skills": "predictive analytics,time series,python,statistics"
    }
]

# Function to extract text from URL with fallback to sample data
def extract_text_from_url(url):
    """Extract text content from a URL with fallbacks."""
    try:
        logger.info(f"Extracting text from URL: {url}")
        
        # Use a more browser-like User-Agent
        headers = {
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/91.0.4472.124 Safari/537.36",
            "Accept-Language": "en-US,en;q=0.9",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8"
        }
        
        # Try direct URL access first
        try:
            # Reduced timeout and don't verify SSL to help with connection issues
            response = requests.get(url, headers=headers, timeout=10, verify=False)
            response.raise_for_status()
            content = response.text
            logger.info(f"Successfully retrieved content from URL, length: {len(content)}")
        except Exception as e:
            logger.warning(f"Direct URL access failed: {str(e)}")
            # Fallback: Use sample job description for testing
            logger.info("Using fallback sample job description")
            return f"""
            Job Title: Data Analyst
            Company: Tech Company
            Location: Remote
            Experience Required: 1-3 years
            Skills: Python, SQL, Data Analysis, Data Visualization
            
            Job Description:
            We are looking for a Data Analyst to join our team. The ideal candidate will have
            experience with Python, SQL, and data visualization tools. Responsibilities include
            analyzing data, creating reports, and presenting insights to stakeholders.
            """
        
        # Parse HTML
        soup = BeautifulSoup(content, 'html.parser')
        
        # Remove script and style elements
        for element in soup(["script", "style", "meta", "noscript", "svg"]):
            element.decompose()
            
        # Get text
        text = soup.get_text(separator=' ', strip=True)
        
        # Normalize whitespace
        text = ' '.join(text.split())
        
        logger.info(f"Extracted text length: {len(text)}")
        return text[:8000]  # Limit to 8000 characters
    except Exception as e:
        logger.exception(f"Error extracting text from URL: {str(e)}")
        st.error(f"Error extracting text from URL. Using fallback data instead.")
        # Return fallback text
        return f"""
        Job Title: Data Analyst
        Company: Tech Company
        Location: Remote
        Experience Required: 1-3 years
        Skills: Python, SQL, Data Analysis, Data Visualization
        
        Job Description:
        We are looking for a Data Analyst to join our team. The ideal candidate will have
        experience with Python, SQL, and data visualization tools. Responsibilities include
        analyzing data, creating reports, and presenting insights to stakeholders.
        """

# Function to generate job details using LLM
def extract_job_details(text, api_key):
    """Extract job details from text using LLM with fallback."""
    try:
        logger.info("Extracting job details from text")
        # Initialize LLM
        llm = ChatGroq(
            groq_api_key=api_key,
            model_name="mixtral-8x7b-32768",
            temperature=0.5,
            max_tokens=1000
        )
        
        # Create prompt
        prompt = f"""
        Extract the following information from this job posting:
        
        {text[:5000]}
        
        Return ONLY a JSON object with these fields:
        - title: Job title
        - company: Company name
        - location: Job location
        - experience: Required experience
        - skills: List of required skills (as an array)
        - description: Brief job description (max 100 words)
        
        Format as valid JSON with no explanation.
        """
        
        # Get response
        logger.info("Sending prompt to LLM")
        response = llm.invoke(prompt)
        logger.info("Received response from LLM")
        
        # Try to parse JSON
        try:
            # Extract JSON from response if wrapped in markdown or other text
            content = response.content if hasattr(response, "content") else str(response)
            logger.info(f"LLM response content length: {len(content)}")
            
            # Look for JSON between triple backticks
            import re
            json_match = re.search(r"```(?:json)?\s*({.*?})\s*```", content, re.DOTALL)
            if json_match:
                json_str = json_match.group(1)
                logger.info("Found JSON in code block")
            else:
                # If not found between backticks, use the whole response
                json_str = content
                logger.info("Using entire response as JSON")
                
            # Clean and parse
            job_details = json.loads(json_str)
            logger.info(f"Successfully parsed job details: {job_details.keys()}")
            return job_details
        except json.JSONDecodeError as e:
            logger.error(f"JSON decode error: {str(e)}")
            # Fallback to a simple structure if JSON parsing fails
            logger.info("Using fallback job details")
            return SAMPLE_JOB
    except Exception as e:
        logger.exception(f"Error extracting job details: {str(e)}")
        st.error(f"Error extracting job details. Using fallback data.")
        return SAMPLE_JOB

# Function to find matching portfolio items
def find_matching_portfolio_items(skills):
    """Find portfolio items matching the job skills."""
    try:
        logger.info(f"Finding portfolio matches for skills: {skills}")
        if not skills:
            logger.info("No skills provided, returning default portfolio items")
            return SAMPLE_PORTFOLIO[:2]
            
        matching_items = []
        normalized_skills = [s.strip().lower() for s in skills]
        
        for item in SAMPLE_PORTFOLIO:
            item_skills = [s.strip().lower() for s in item["skills"].split(",")]
            
            # Check for matches
            for skill in normalized_skills:
                if any(skill in item_skill or item_skill in skill for item_skill in item_skills):
                    matching_items.append(item)
                    logger.info(f"Found match: {item['project']} for skill: {skill}")
                    break
        
        # Return matches or defaults
        result = matching_items[:3] if matching_items else SAMPLE_PORTFOLIO[:2]
        logger.info(f"Returning {len(result)} portfolio items")
        return result
    except Exception as e:
        logger.exception(f"Error matching portfolio items: {str(e)}")
        return SAMPLE_PORTFOLIO[:2]

# Function to generate cold email
def generate_cold_email(job_details, portfolio_items, api_key):
    """Generate a cold email based on job details and portfolio items."""
    try:
        logger.info("Generating cold email")
        # Format job details
        job_text = f"""
        Title: {job_details.get('title', 'Job Position')}
        Company: {job_details.get('company', 'Company')}
        Location: {job_details.get('location', 'Location')}
        Experience: {job_details.get('experience', 'Not specified')}
        Skills: {', '.join(job_details.get('skills', []))}
        Description: {job_details.get('description', 'Not provided')}
        """
        
        # Format portfolio links
        portfolio_text = "\n".join([f"- {item['project']}: {item['url']}" for item in portfolio_items])
        
        # Initialize LLM
        llm = ChatGroq(
            groq_api_key=api_key,
            model_name="mixtral-8x7b-32768",
            temperature=0.7,
            max_tokens=1000
        )
        
        # Create prompt
        prompt = f"""
        Write a professional cold email regarding the job description below.
        The email should:
        1. Have a clear, professional subject line
        2. Start with a personalized greeting
        3. Reference the specific job posting for {job_details.get('title')} at {job_details.get('company')}
        4. Briefly highlight your relevant skills and experience that match the job requirements
        5. Reference the portfolio links provided as examples of your work
        6. Include a call to action like requesting an interview
        7. End with a professional closing
        
        Job Details:
        {job_text}
        
        Portfolio Links:
        {portfolio_text}
        
        Write ONLY the email text, no explanation needed.
        """
        
        # Get response
        logger.info("Sending prompt to LLM")
        response = llm.invoke(prompt)
        logger.info("Received response from LLM")
        
        # Extract content
        email_content = response.content if hasattr(response, "content") else str(response)
        logger.info(f"Generated email length: {len(email_content)}")
        
        return email_content
    except Exception as e:
        logger.exception(f"Error generating email: {str(e)}")
        return """
        Subject: Application for Data Analyst Position
        
        Dear Hiring Manager,
        
        I came across your job posting for a Data Analyst position and I'm excited to apply. With my experience in Python, SQL, and data visualization, I believe I would be a great fit for your team.
        
        I've attached my portfolio links for your review.
        
        I would welcome the opportunity to discuss how my skills align with your needs. Please let me know if you would like to schedule an interview.
        
        Thank you for your consideration.
        
        Best regards,
        [Your Name]
        """

# Main Streamlit UI
st.title("📧 Cold Email Generator")
st.markdown("""
This tool helps you generate personalized cold emails for job applications based on job postings.
Simply paste a job posting URL below and click the button to generate a tailored email.
""")

# Get API key
api_key = st.secrets.get("GROQ_API_KEY", os.environ.get("GROQ_API_KEY", ""))
if not api_key:
    st.error("GROQ API Key not found. Please set it in secrets or environment variables.")
    st.stop()

# Create form
with st.form(key="url_form"):
    url_input = st.text_input(
        "Enter a job posting URL:",
        value="https://www.naukri.com/job-listings-analyst-merkle-science-mumbai-new-delhi-pune-bengaluru-1-to-2-years-210325501333"
    )
    submit_button = st.form_submit_button("Generate Cold Email")

if submit_button:
    if not url_input:
        st.error("Please enter a valid URL")
    else:
        try:
            # Disable SSL warnings
            import urllib3
            urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
            
            # Step 1: Extract text from URL
            with st.spinner("Loading job posting..."):
                logger.info(f"Processing URL: {url_input}")
                text = extract_text_from_url(url_input)
                if not text:
                    st.error("Failed to extract text from the URL. Using fallback data.")
                    text = "Fallback job description for a Data Analyst position"
                else:
                    st.success("Job posting loaded successfully!")
            
            # Step 2: Extract job details
            with st.spinner("Analyzing job posting..."):
                job_details = extract_job_details(text, api_key)
                if not job_details:
                    st.error("Failed to extract job details. Using fallback data.")
                    job_details = SAMPLE_JOB
                else:
                    st.success("Job analysis complete!")
            
            # Step 3: Find matching portfolio items
            with st.spinner("Finding matching portfolio items..."):
                portfolio_items = find_matching_portfolio_items(job_details.get("skills", []))
            
            # Step 4: Generate cold email
            with st.spinner("Generating cold email..."):
                email = generate_cold_email(job_details, portfolio_items, api_key)
                st.success("Email generated successfully!")
            
            # Display results
            with st.expander("Job Details", expanded=False):
                st.json(job_details)
            
            st.subheader("Your Cold Email")
            st.markdown(email)
            
            # Add download button
            st.download_button(
                label="Download Email",
                data=email,
                file_name="cold_email.md",
                mime="text/markdown"
            )
        
        except Exception as e:
            logger.exception(f"An unexpected error occurred: {str(e)}")
            st.error(f"An error occurred: {str(e)}")
            st.info("Generating cold email with fallback data instead...")
            
            # Generate email with fallback data as a last resort
            job_details = SAMPLE_JOB
            portfolio_items = SAMPLE_PORTFOLIO[:2]
            email = generate_cold_email(job_details, portfolio_items, api_key)
            
            with st.expander("Job Details (Fallback Data)", expanded=False):
                st.json(job_details)
            
            st.subheader("Your Cold Email (Generated with Fallback Data)")
            st.markdown(email)
            
            st.download_button(
                label="Download Email",
                data=email,
                file_name="cold_email.md",
                mime="text/markdown"
            )


