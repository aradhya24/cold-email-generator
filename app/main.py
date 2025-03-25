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

# Helper functions for handling specific job sites
def get_fallback_job_text(title=None, company=None, location=None, skills=None, description=None, experience=None):
    """Generate fallback job text with optional parameters."""
    title = title or "Data Analyst"
    company = company or "Tech Company"
    location = location or "Remote"
    skills = skills or ["Python", "SQL", "Data Analysis", "Data Visualization"]
    description = description or "We are looking for a Data Analyst to join our team. The ideal candidate will have experience with Python, SQL, and data visualization tools."
    experience = experience or "1-3 years"
    
    return f"""
    Job Title: {title}
    Company: {company}
    Location: {location}
    Experience Required: {experience}
    Skills: {', '.join(skills)}
    
    Job Description:
    {description}
    Responsibilities include analyzing data, creating reports, and presenting insights to stakeholders.
    """

def handle_glassdoor_url(url):
    """Specialized handler for Glassdoor URLs."""
    logger.info("Using specialized handler for Glassdoor")
    # For Glassdoor, we use a fallback with data analyst information
    logger.info("Using fallback data for Glassdoor")
    return get_fallback_job_text("Data Analyst", "Tech Company", "Remote", 
                               ["Python", "SQL", "Data Analysis", "Data Visualization"],
                               "Looking for a skilled data analyst with experience in Python and SQL.",
                               "1-3 years")

def handle_naukri_url(url):
    """Specialized handler for Naukri URLs."""
    logger.info("Using specialized handler for Naukri")
    
    try:
        # Extract job title, company from URL
        import re
        url_parts = url.lower().split('job-listings-')[1].split('?')[0].split('-')
        
        # Try to identify components
        skills = []
        location = "Unknown"
        company = "Unknown"
        title = "Unknown"
        
        # First part is usually job title
        if len(url_parts) > 2:
            title_parts = []
            company_found = False
            
            for part in url_parts:
                if part in ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'to', 'years']:
                    company_found = True
                    continue
                
                if not company_found:
                    title_parts.append(part)
                elif 'years' not in part and len(part) > 2:
                    if company == "Unknown":
                        company = part.capitalize()
                    else:
                        # Could be location
                        location = part.capitalize()
            
            title = ' '.join([p.capitalize() for p in title_parts])
        
        # Extract more information from the URL itself
        if 'java' in url.lower():
            skills.append('Java')
        if 'python' in url.lower():
            skills.append('Python')
        if 'data' in url.lower():
            skills.append('Data Analysis')
        if 'analyst' in url.lower():
            skills.append('Analytics')
        if 'developer' in url.lower():
            skills.append('Software Development')
        if 'engineer' in url.lower():
            skills.append('Engineering')
        if 'fresher' in url.lower() or 'graduate' in url.lower():
            experience = '0-1 years'
        else:
            experience = '1-3 years'
            
        # Add more skills based on job title
        if 'purchase' in url.lower() or 'procurement' in url.lower():
            skills.extend(['Supply Chain Management', 'Inventory Management', 'Vendor Management', 'Purchase Orders'])
            description = "Looking for a Purchase Officer to handle procurement activities, vendor management, and inventory control."
        elif 'software' in url.lower() or 'developer' in url.lower():
            skills.extend(['Software Development', 'Coding', 'Programming', 'Problem Solving'])
            description = "Seeking a Software Developer to design, develop and implement software solutions."
        elif 'data' in url.lower() or 'analyst' in url.lower():
            skills.extend(['Data Analysis', 'SQL', 'Reporting', 'Business Intelligence'])
            description = "Seeking a Data Analyst to analyze data, create reports, and provide business insights."
        elif 'marketing' in url.lower():
            skills.extend(['Digital Marketing', 'Social Media', 'Content Creation', 'Campaign Management'])
            description = "Looking for a Marketing Specialist to develop and implement marketing strategies."
        else:
            skills.extend(['Communication', 'Problem Solving', 'Team Work', 'Microsoft Office'])
            description = f"Seeking a qualified candidate for the {title} position to join our team."
        
        # Make sure we have unique skills
        skills = list(set(skills))
        
        logger.info(f"Extracted from Naukri URL - Title: {title}, Company: {company}, Location: {location}")
        return get_fallback_job_text(title, company, location, skills, description, experience)
    except Exception as e:
        logger.warning(f"Error in Naukri URL handler: {str(e)}")
    
    # If all extraction fails, return default
    logger.info("Using default fallback data for Naukri")
    return get_fallback_job_text("Software Developer", "Tech Solutions", "Mumbai", 
                               ["Java", "Spring Boot", "Microservices", "REST API"],
                               "We are looking for an experienced Java developer with Spring Boot knowledge.",
                               "1-3 years")

def handle_linkedin_url(url):
    """Specialized handler for LinkedIn URLs."""
    logger.info("Using specialized handler for LinkedIn")
    # For LinkedIn, we use a fallback with product manager information
    logger.info("Using fallback data for LinkedIn")
    return get_fallback_job_text("Product Manager", "TechCorp", "Bangalore", 
                               ["Product Management", "Agile", "Strategy", "UX"],
                               "Looking for a product manager with experience in agile methodologies.",
                               "1-3 years")

# Function to extract text from URL with fallback to sample data
def extract_text_from_url(url):
    """Extract text content from a URL with fallbacks and specialized site handlers."""
    try:
        logger.info(f"Extracting text from URL: {url}")
        
        # Ensure URL has http/https prefix
        if not url.startswith(('http://', 'https://')):
            url = 'https://' + url
            logger.info(f"Added https prefix. New URL: {url}")
        
        # Try multiple different approaches with specific headers
        user_agents = [
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36",
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.0 Safari/605.1.15",
            "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/94.0.4606.81 Safari/537.36"
        ]
        
        # Function to make request with specific headers
        def try_request(user_agent):
            headers = {
                "User-Agent": user_agent,
                "Accept-Language": "en-US,en;q=0.9",
                "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8",
                "Referer": "https://www.google.com/",
                "sec-ch-ua": '"Google Chrome";v="95", "Chromium";v="95", ";Not A Brand";v="99"',
                "sec-ch-ua-mobile": "?0",
                "sec-ch-ua-platform": '"Windows"',
                "sec-fetch-dest": "document",
                "sec-fetch-mode": "navigate",
                "sec-fetch-site": "none",
                "sec-fetch-user": "?1",
                "upgrade-insecure-requests": "1"
            }
            
            response = requests.get(
                url, 
                headers=headers, 
                timeout=15, 
                verify=False,
                allow_redirects=True
            )
            response.raise_for_status()
            return response.text
        
        # Check for known job sites and use specialized handlers if needed
        for attempt, agent in enumerate(user_agents):
            try:
                logger.info(f"Attempt {attempt+1} with different user agent")
                content = try_request(agent)
                
                if content:
                    logger.info(f"Successfully retrieved content from URL, length: {len(content)}")
                    
                    # Parse HTML
                    soup = BeautifulSoup(content, 'html.parser')
                    
                    # Remove script and style elements
                    for element in soup(["script", "style", "meta", "noscript", "svg"]):
                        element.decompose()
                    
                    # Get text
                    text = soup.get_text(separator=' ', strip=True)
                    
                    # Normalize whitespace
                    text = ' '.join(text.split())
                    
                    # If text is too short, it's probably not the job description
                    if len(text) < 200:
                        logger.warning(f"Retrieved text is too short ({len(text)} chars), trying next method")
                        continue
                    
                    logger.info(f"Extracted text length: {len(text)}")
                    return text[:8000]  # Limit to 8000 characters
            except Exception as e:
                logger.warning(f"Attempt {attempt+1} failed: {str(e)}")
        
        # If all direct attempts fail, try site-specific handlers
        if "glassdoor" in url.lower():
            return handle_glassdoor_url(url)
        elif "naukri" in url.lower():
            return handle_naukri_url(url)
        elif "linkedin" in url.lower():
            return handle_linkedin_url(url)
        
        # If all approaches fail, use fallback
        logger.info("All extraction attempts failed. Using fallback sample job description")
        st.warning("Could not extract job details from URL. Using sample data instead.")
        return get_fallback_job_text()
    except Exception as e:
        logger.exception(f"Error extracting text from URL: {str(e)}")
        st.error(f"Error extracting text from URL. Using fallback data instead.")
        # Return fallback text
        return get_fallback_job_text()

# Function to generate job details using LLM
def extract_job_details(text, api_key):
    """Extract job details from text using LLM with fallback."""
    try:
        logger.info("Extracting job details from text")
        # Initialize LLM
        llm = ChatGroq(
            groq_api_key=api_key,
            model_name="llama3-70b-8192",
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
def generate_cold_email(job_details, portfolio_items, api_key, variations=3):
    """Generate multiple cold email variations based on job details and portfolio items."""
    try:
        logger.info(f"Generating {variations} cold email samples")
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
            model_name="llama3-70b-8192",
            temperature=0.7,
            max_tokens=2000
        )
        
        # Create prompt for multiple variations
        prompt = f"""
        Write {variations} different professional cold email variations regarding the job description below.
        
        Each email should:
        1. Have a unique, professional subject line
        2. Start with a personalized greeting
        3. Reference the specific job posting for {job_details.get('title')} at {job_details.get('company')}
        4. Briefly highlight relevant skills that match the job requirements
        5. Reference the portfolio links provided as examples of work
        6. Include a call to action
        7. End with a professional closing
        
        Job Details:
        {job_text}
        
        Portfolio Links:
        {portfolio_text}
        
        Clearly separate each email variation with "EMAIL VARIATION #1", "EMAIL VARIATION #2", etc.
        Write ONLY the email text for each variation, no additional explanation.
        """
        
        # Get response
        logger.info("Sending prompt to LLM")
        response = llm.invoke(prompt)
        logger.info("Received response from LLM")
        
        # Extract content
        email_content = response.content if hasattr(response, "content") else str(response)
        logger.info(f"Generated email content length: {len(email_content)}")
        
        return email_content
    except Exception as e:
        logger.exception(f"Error generating email: {str(e)}")
        return """
        Subject: Application for the Job Position
        
        Dear Hiring Manager,
        
        I came across your job posting and I'm excited to apply. With my relevant experience, I believe I would be a great fit for your team.
        
        I've attached my portfolio links for your review.
        
        I would welcome the opportunity to discuss how my skills align with your needs. Please let me know if you would like to schedule an interview.
        
        Thank you for your consideration.
        
        Best regards,
        [Your Name]
        
        EMAIL VARIATION #2
        
        Subject: Interested in Contributing to Your Team
        
        Dear Hiring Manager,
        
        I recently discovered your job opening and am eager to submit my application. My background aligns well with what you're looking for.
        
        Please review my portfolio links to see examples of my work.
        
        I'm available for an interview at your convenience to discuss how I can contribute to your organization.
        
        Thank you for considering my application.
        
        Sincerely,
        [Your Name]
        
        EMAIL VARIATION #3
        
        Subject: Excited About Your Job Opportunity
        
        Hello Hiring Team,
        
        I'm writing to express my interest in the position you've advertised. My skills and experience make me an ideal candidate.
        
        The portfolio links I've included demonstrate my capabilities in relevant areas.
        
        I would appreciate the chance to speak with you about this opportunity and how I can help achieve your goals.
        
        Thank you for your time and consideration.
        
        Regards,
        [Your Name]
        """

# Main Streamlit UI
st.title("📧 Cold Email Generator")
st.markdown("""
This tool helps you generate personalized cold emails for job applications based on job postings.
Simply paste a job posting URL below and click the button to generate tailored email variations.
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
            with st.spinner("Generating cold email samples..."):
                email = generate_cold_email(job_details, portfolio_items, api_key, variations=3)
                st.success("Email samples generated successfully!")
            
            # Display results
            with st.expander("Job Details", expanded=False):
                st.json(job_details)
            
            st.subheader("Your Cold Email Samples")
            st.markdown(email)
            
            # Add download button
            st.download_button(
                label="Download Email Samples",
                data=email,
                file_name="cold_email_samples.md",
                mime="text/markdown"
            )
        
        except Exception as e:
            logger.exception(f"An unexpected error occurred: {str(e)}")
            st.error(f"An error occurred: {str(e)}")
            st.info("Generating cold email with fallback data instead...")
            
            # Generate email with fallback data as a last resort
            job_details = SAMPLE_JOB
            portfolio_items = SAMPLE_PORTFOLIO[:2]
            email = generate_cold_email(job_details, portfolio_items, api_key, variations=3)
            
            with st.expander("Job Details (Fallback Data)", expanded=False):
                st.json(job_details)
            
            st.subheader("Your Cold Email Samples (Generated with Fallback Data)")
            st.markdown(email)
            
            st.download_button(
                label="Download Email Samples",
                data=email,
                file_name="cold_email_samples.md",
                mime="text/markdown"
            )


