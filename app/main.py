"""Main application module."""

import os
import streamlit as st
import time
import traceback
from langchain_community.document_loaders import WebBaseLoader

from chains import Chain, EmailChain
from portfolio import Portfolio, PortfolioProcessor
from utils import clean_text, format_experience, validate_input

# Set page config as the first Streamlit command
st.set_page_config(layout="wide", page_title="Cold Email Generator", page_icon="📧")

# Initialize email chain with API key from secrets or environment variables
if 'email_chain' not in st.session_state:
    # Try to get GROQ API key from different sources
    try:
        # First try to get from Streamlit secrets
        groq_api_key = st.secrets["GROQ_API_KEY"]
    except (FileNotFoundError, KeyError):
        # Fall back to environment variable
        groq_api_key = os.getenv("GROQ_API_KEY")
        if not groq_api_key:
            st.error("GROQ API Key not found in secrets or environment variables")
            st.stop()
    
    # Initialize the email chain
    st.session_state.email_chain = EmailChain(groq_api_key)

# Function to load URL content
def load_url_content(url):
    """Load content from a URL."""
    try:
        # Configure WebLoader with improved settings
        loader = WebBaseLoader(
            web_paths=[url],
            requests_kwargs={
                'headers': {
                    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
                    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8',
                    'Accept-Language': 'en-US,en;q=0.5',
                }
            }
        )
        
        # Load the documents
        documents = loader.load()
        if not documents:
            return None
        
        # Return the page content of the first document
        return documents[0].page_content
    except Exception as e:
        st.error(f"Error loading URL: {str(e)}")
        return None

# Function to generate cold emails from job postings
def generate_cold_email(url):
    """Generate a cold email from a job posting URL."""
    try:
        # Step 1: Load job posting content
        with st.spinner("Loading job posting..."):
            content = load_url_content(url)
            if not content:
                st.error("Failed to load content from the URL. Please check if the URL is accessible.")
                return None
            
            # Clean the text content
            data = clean_text(content)
        
        # Step 2: Extract job information
        with st.spinner("Extracting job details..."):
            chain = Chain()
            portfolio = Portfolio()
            portfolio.load_portfolio()
            
            jobs = chain.extract_jobs(data)
            if not jobs:
                st.error("Could not extract job details from this posting. Please try a different URL.")
                return None
        
        # Step 3: Generate the cold email
        with st.spinner("Generating cold email..."):
            job = jobs[0]  # Use the first job
            skills = job.get('skills', [])
            links = portfolio.query_links(skills)
            
            email = chain.write_mail(job, links)
        
        return {
            "job": job,
            "email": email
        }
    except Exception as e:
        st.error(f"An error occurred: {str(e)}")
        st.error(traceback.format_exc())
        return None

# Streamlit UI
st.title("📧 Cold Email Generator | AtliQ")
st.markdown("""
This tool helps you generate personalized cold emails for job applications. 
As a business development executive at AtliQ, you can create professional outreach emails 
to potential clients based on their job postings.

Simply paste a job posting URL below and click the button to generate a tailored email.
""")

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
        # Generate the email
        result = generate_cold_email(url_input)
        
        if result:
            # Display job details
            with st.expander("Job Details", expanded=False):
                st.json(result["job"])
            
            # Display the email
            st.subheader("Your Cold Email")
            st.markdown(result["email"])
            
            # Add download button
            st.download_button(
                label="Download Email",
                data=result["email"],
                file_name="cold_email.md",
                mime="text/markdown"
            )

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
    
if __name__ == "__main__":
    pass


