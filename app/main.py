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

def create_streamlit_app(llm, portfolio, clean_text):
    st.title("📧 Cold Mail Generator")
    url_input = st.text_input("Enter a URL:", value="https://jobs.nike.com/job/R-33460")
    submit_button = st.button("Submit")

    if submit_button:
        try:
            loader = WebBaseLoader([url_input])
            data = clean_text(loader.load().pop().page_content)
            portfolio.load_portfolio()
            jobs = llm.extract_jobs(data)
            for job in jobs:
                skills = job.get('skills', [])
                links = portfolio.query_links(skills)
                email = llm.write_mail(job, links)
                st.code(email, language='markdown')
        except Exception as e:
            st.error(f"An Error Occurred: {e}")

# Streamlit UI
st.title("Cold Email Generator")

# Input fields
recipient_name = st.text_input("Recipient Name")
recipient_position = st.text_input("Recipient Position")
recipient_company = st.text_input("Recipient Company")
recipient_experience = st.text_area("Recipient Experience")

sender_name = st.text_input("Your Name")
sender_position = st.text_input("Your Position")
sender_company = st.text_input("Your Company")

purpose = st.text_area("Purpose of Email")

if st.button("Generate Email"):
    if all([recipient_name, recipient_position, sender_name, purpose]):
        recipient_info = f"""
        Name: {recipient_name}
        Position: {recipient_position}
        Company: {recipient_company}
        Experience: {recipient_experience}
        """

        sender_info = f"""
        Name: {sender_name}
        Position: {sender_position}
        Company: {sender_company}
        """

        with st.spinner("Generating email..."):
            email = st.session_state.email_chain.generate_email(
                recipient_info=recipient_info,
                sender_info=sender_info,
                purpose=purpose
            )
            st.text_area("Generated Email", email, height=300)
    else:
        st.error("Please fill in all required fields")

if __name__ == "__main__":
    chain = Chain()
    portfolio = Portfolio()
    create_streamlit_app(chain, portfolio, clean_text)


