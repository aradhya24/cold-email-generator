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

# Streamlit UI
st.title("📧 Cold Mail Generator")
st.markdown("""
This tool helps you generate personalized cold emails for job applications.
Simply paste a job posting URL below and click Submit to generate a tailored email.
""")

url_input = st.text_input(
    "Enter a URL:",
    value="https://jobs.lever.co/merkle-science/a0fc5b0b-90ff-40b1-9d5e-8ab828383c34"
)
submit_button = st.button("Submit")

if submit_button:
    if not url_input:
        st.error("Please enter a valid URL")
    else:
        try:
            with st.spinner("Loading job posting..."):
                # Set a timeout for the loader to prevent hanging
                st.write(f"Fetching content from: {url_input}")
                
                # Configure WebLoader with improved settings
                loader = WebBaseLoader(
                    web_paths=[url_input],
                    requests_kwargs={
                        'timeout': 30,  # 30 second timeout
                        'headers': {
                            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
                            'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8',
                            'Accept-Language': 'en-US,en;q=0.5',
                        }
                    }
                )
                
                # Load the content with progress updates
                start_time = time.time()
                st.write("Sending request...")
                documents = loader.load()
                st.write(f"Content received in {time.time() - start_time:.2f} seconds")
                
                # Process the content
                st.write("Processing content...")
                if not documents or len(documents) == 0:
                    st.error("No content could be loaded from the URL. Please try a different URL.")
                    st.stop()
                
                # Clean the text
                data = clean_text(documents[0].page_content)
                st.success("Job posting loaded successfully!")
                
                # Display a sample of the loaded content for debugging
                st.expander("Preview of loaded content").write(data[:500] + "...")
                
                with st.spinner("Extracting job details..."):
                    st.write("Initializing AI model...")
                    chain = Chain()
                    portfolio = Portfolio()
                    portfolio.load_portfolio()
                    
                    st.write("Extracting job information...")
                    jobs = chain.extract_jobs(data)
                    if not jobs:
                        st.error("No job details could be extracted from the URL. Please check the URL and try again.")
                    else:
                        for job in jobs:
                            with st.spinner("Generating email..."):
                                st.write("Finding relevant portfolio links...")
                                skills = job.get('skills', [])
                                links = portfolio.query_links(skills)
                                
                                st.write("Generating personalized email...")
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
            st.error(traceback.format_exc())
            st.error("Please check the URL and try again. If the problem persists, contact support.")

if __name__ == "__main__":
    pass


