"""Main application module."""

import os
import streamlit as st
import time
import traceback
import threading
import signal
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

# Timeout handler class
class TimeoutError(Exception):
    pass

def timeout_handler(signum, frame):
    raise TimeoutError("Operation timed out")

# Function to load URL with timeout
def load_url_content(url):
    """Load content from URL without strict timeout."""
    result = {"success": False, "data": None, "error": None}
    
    try:
        # Configure WebLoader with improved settings
        loader = WebBaseLoader(
            web_paths=[url],
            requests_kwargs={
                'headers': {
                    'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
                                 'AppleWebKit/537.36 (KHTML, like Gecko) '
                                 'Chrome/122.0.0.0 Safari/537.36',
                    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8',
                    'Accept-Language': 'en-US,en;q=0.5',
                }
            }
        )
        
        # Load content directly
        documents = loader.load()
        if documents and len(documents) > 0:
            result["data"] = documents[0].page_content
            result["success"] = True
        else:
            result["error"] = "No content loaded"
    except Exception as e:
        result["error"] = str(e)
    
    return result

# Streamlit UI
st.title("📧 Cold Mail Generator")
st.markdown("""
This tool helps you generate personalized cold emails for job applications.
Simply paste a job posting URL below and click Submit to generate a tailored email.
""")

with st.form(key="url_form"):
    url_input = st.text_input(
        "Enter a job posting URL:",
        value="https://jobs.lever.co/merkle-science/a0fc5b0b-90ff-40b1-9d5e-8ab828383c34"
    )
    submit_button = st.form_submit_button("Generate Email")

if submit_button:
    if not url_input:
        st.error("Please enter a valid URL")
    else:
        try:
            # Step 1: Load job posting
            with st.spinner("Loading job posting..."):
                st.write(f"Fetching content from: {url_input}")
                
                # Load URL content
                start_time = time.time()
                result = load_url_content(url_input)
                
                if not result["success"]:
                    st.error(f"Failed to load content: {result['error']}")
                    st.error("Please check if the URL is accessible and try again.")
                    st.stop()
                
                data = clean_text(result["data"])
                st.write(f"Content received and processed in {time.time() - start_time:.2f} seconds")
                st.success("Job posting loaded successfully!")
            
            # Step 2: Extract job details
            with st.spinner("Analyzing job posting..."):
                chain = Chain()
                portfolio = Portfolio()
                portfolio.load_portfolio()
                
                jobs = chain.extract_jobs(data)
                
                if not jobs:
                    st.error("Could not extract job details from this posting. Please try a different URL.")
                    st.stop()
            
            # Step 3: Generate email
            with st.spinner("Creating personalized email..."):
                job = jobs[0]  # Use the first job
                skills = job.get('skills', [])
                links = portfolio.query_links(skills)
                
                email = chain.write_mail(job, links)
            
            # Step 4: Display results
            st.subheader("Job Analysis")
            st.json(job)
            
            st.subheader("Your Personalized Cold Email")
            st.code(email, language='markdown')
            
            st.download_button(
                label="Download Email",
                data=email,
                file_name="cold_email.md",
                mime="text/markdown"
            )
            
        except Exception as e:
            st.error(f"An error occurred: {str(e)}")
            st.error("Please try a different job posting URL or contact support if the problem persists.")

if __name__ == "__main__":
    pass


