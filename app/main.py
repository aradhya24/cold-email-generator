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
st.markdown("""
This tool helps you generate personalized cold emails for job applications.
Simply paste a job posting URL below and click Submit to generate a tailored email.
""")

url_input = st.text_input(
    "Enter a URL:",
    value="https://www.naukri.com/job-listings-analyst-merkle-science-mumbai"
)
submit_button = st.button("Submit")

if submit_button:
    if not url_input:
        st.error("Please enter a valid URL")
    else:
        try:
            with st.spinner("Loading job posting..."):
                loader = WebBaseLoader([url_input])
                data = clean_text(loader.load().pop().page_content)
                st.success("Job posting loaded successfully!")
                
                with st.spinner("Extracting job details..."):
                    chain = Chain()
                    portfolio = Portfolio()
                    portfolio.load_portfolio()
                    
                    jobs = chain.extract_jobs(data)
                    if not jobs:
                        st.error("No job details could be extracted from the URL. Please check the URL and try again.")
                    else:
                        for job in jobs:
                            with st.spinner("Generating email..."):
                                skills = job.get('skills', [])
                                links = portfolio.query_links(skills)
                                email = chain.write_mail(job, links)
                                
                                # Display job details
                                st.markdown("### Job Details:")
                                st.json(job)
                                
                                # Display generated email
                                st.markdown("### Generated Email:")
                                st.code(email, language='markdown')
                                
                                # Add copy button
                                st.button("Copy Email", key=f"copy_{job.get('title', '')}", 
                                        on_click=lambda: st.write("Email copied to clipboard!"))
        except Exception as e:
            st.error(f"An error occurred: {str(e)}")
            st.error("Please check the URL and try again. If the problem persists, contact support.")

if __name__ == "__main__":
    pass


