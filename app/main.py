"""Main application module."""

import os
import streamlit as st
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

# Streamlit UI
st.title("📧 Cold Mail Generator")
url_input = st.text_input(
    "Enter a URL:",
    value="https://www.naukri.com/job-listings-analyst-merkle-science-mumbai"
)
submit_button = st.button("Submit")

if submit_button:
    try:
        loader = WebBaseLoader([url_input])
        data = clean_text(loader.load().pop().page_content)
        
        chain = Chain()
        portfolio = Portfolio()
        portfolio.load_portfolio()
        
        jobs = chain.extract_jobs(data)
        for job in jobs:
            skills = job.get('skills', [])
            links = portfolio.query_links(skills)
            email = chain.write_mail(job, links)
            st.code(email, language='markdown')
    except Exception as e:
        st.error(f"An Error Occurred: {e}")

if __name__ == "__main__":
    pass


