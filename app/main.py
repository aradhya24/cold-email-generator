"""Main application module."""

import os
import streamlit as st
import requests
from bs4 import BeautifulSoup
import json
from langchain_groq import ChatGroq

# Set page config as the first Streamlit command
st.set_page_config(layout="wide", page_title="Cold Email Generator", page_icon="📧")

# Directly define sample portfolio data
SAMPLE_PORTFOLIO = [
    {
        "project": "E-commerce Analytics Dashboard",
        "url": "https://github.com/atliq/ecommerce-analytics",
        "skills": "python,data analysis,visualization,dashboard"
    },
    {
        "project": "Customer Segmentation Engine",
        "url": "https://github.com/atliq/customer-segmentation",
        "skills": "machine learning,clustering,python,data science"
    },
    {
        "project": "Inventory Management System",
        "url": "https://github.com/atliq/inventory-management",
        "skills": "java,database,api development,backend"
    },
    {
        "project": "Sales Forecasting Tool",
        "url": "https://github.com/atliq/sales-forecast",
        "skills": "predictive analytics,time series,python,statistics"
    },
    {
        "project": "HR Analytics Dashboard",
        "url": "https://github.com/atliq/hr-analytics",
        "skills": "power bi,data visualization,analytics,reporting"
    }
]

# Function to extract text from URL
def extract_text_from_url(url):
    """Extract text content from a URL."""
    try:
        # Set headers to mimic a browser
        headers = {
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
        }
        
        # Make the request
        response = requests.get(url, headers=headers, timeout=30)
        response.raise_for_status()  # Raise an exception for HTTP errors
        
        # Parse HTML
        soup = BeautifulSoup(response.text, 'html.parser')
        
        # Remove script and style elements
        for script_or_style in soup(["script", "style"]):
            script_or_style.decompose()
            
        # Get text
        text = soup.get_text(separator=' ', strip=True)
        
        # Normalize whitespace
        text = ' '.join(text.split())
        
        return text[:8000]  # Limit to 8000 characters
    except Exception as e:
        st.error(f"Error extracting text from URL: {str(e)}")
        return None

# Function to generate job details using LLM
def extract_job_details(text, api_key):
    """Extract job details from text using LLM."""
    try:
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
        - skills: List of required skills
        - description: Brief job description (max 100 words)
        
        Format as valid JSON with no explanation.
        """
        
        # Get response
        response = llm.invoke(prompt)
        
        # Try to parse JSON
        try:
            # Extract JSON from response if wrapped in markdown or other text
            content = response.content if hasattr(response, "content") else str(response)
            
            # Look for JSON between triple backticks
            import re
            json_match = re.search(r"```(?:json)?\s*({.*?})\s*```", content, re.DOTALL)
            if json_match:
                json_str = json_match.group(1)
            else:
                # If not found between backticks, use the whole response
                json_str = content
                
            # Clean and parse
            job_details = json.loads(json_str)
            return job_details
        except json.JSONDecodeError:
            # Fallback to a simple structure if JSON parsing fails
            return {
                "title": "Job Position",
                "company": "Company Name",
                "location": "Location",
                "experience": "1-3 years",
                "skills": ["skill1", "skill2", "skill3"],
                "description": "Job description not available"
            }
    except Exception as e:
        st.error(f"Error extracting job details: {str(e)}")
        return None

# Function to find matching portfolio items
def find_matching_portfolio_items(skills):
    """Find portfolio items matching the job skills."""
    if not skills:
        return SAMPLE_PORTFOLIO[:2]
        
    matching_items = []
    normalized_skills = [s.strip().lower() for s in skills]
    
    for item in SAMPLE_PORTFOLIO:
        item_skills = [s.strip().lower() for s in item["skills"].split(",")]
        
        # Check for matches
        for skill in normalized_skills:
            if any(skill in item_skill or item_skill in skill for item_skill in item_skills):
                matching_items.append(item)
                break
    
    # Return matches or defaults
    return matching_items[:3] if matching_items else SAMPLE_PORTFOLIO[:2]

# Function to generate cold email
def generate_cold_email(job_details, portfolio_items, api_key):
    """Generate a cold email based on job details and portfolio items."""
    try:
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
        You are Mohan, a business development executive at AtliQ.
        AtliQ is an AI & Software Consulting company dedicated to facilitating
        the seamless integration of business processes through automated tools.
        
        Write a professional cold email to the hiring manager regarding the job description below.
        The email should:
        1. Introduce yourself as Mohan from AtliQ
        2. Reference the specific job posting for {job_details.get('title')} at {job_details.get('company')}
        3. Explain how AtliQ can provide excellent candidates or services for this position
        4. Highlight how AtliQ's expertise matches their requirements
        5. Reference the portfolio links provided
        6. Include a call to action like scheduling a meeting
        7. End with a professional closing
        
        Job Details:
        {job_text}
        
        AtliQ Portfolio Links:
        {portfolio_text}
        
        Write ONLY the email text, no explanation needed.
        """
        
        # Get response
        response = llm.invoke(prompt)
        
        # Extract content
        email_content = response.content if hasattr(response, "content") else str(response)
        
        return email_content
    except Exception as e:
        st.error(f"Error generating email: {str(e)}")
        return "Error generating email. Please try again."

# Main Streamlit UI
st.title("📧 Cold Email Generator | AtliQ")
st.markdown("""
This tool helps you generate personalized cold emails for job applications. 
As a business development executive at AtliQ, you can create professional outreach emails 
to potential clients based on their job postings.

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
            # Step 1: Extract text from URL
            with st.spinner("Loading job posting..."):
                text = extract_text_from_url(url_input)
                if not text:
                    st.error("Failed to extract text from the URL. Please try a different URL.")
                    st.stop()
            
            # Step 2: Extract job details
            with st.spinner("Analyzing job posting..."):
                job_details = extract_job_details(text, api_key)
                if not job_details:
                    st.error("Failed to extract job details. Please try a different URL.")
                    st.stop()
            
            # Step 3: Find matching portfolio items
            with st.spinner("Finding matching portfolio items..."):
                portfolio_items = find_matching_portfolio_items(job_details.get("skills", []))
            
            # Step 4: Generate cold email
            with st.spinner("Generating cold email..."):
                email = generate_cold_email(job_details, portfolio_items, api_key)
            
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
            st.error(f"An error occurred: {str(e)}")

# Sidebar with company info
with st.sidebar:
    st.image("https://i.imgur.com/UWAUeHC.png", width=200)
    st.title("AtliQ")
    st.markdown("""
    AtliQ is an AI & Software Consulting company dedicated to facilitating
    the seamless integration of business processes through automated tools.
    
    We empower enterprises with tailored solutions, fostering:
    - Scalability
    - Process optimization
    - Cost reduction
    - Heightened overall efficiency
    """)


