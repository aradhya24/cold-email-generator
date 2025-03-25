"""Example usage of the email generator."""

import os
from dotenv import load_dotenv
from chains import EmailChain


def main():
    """Run example email generation."""
    load_dotenv()
    groq_api_key = os.getenv("GROQ_API_KEY")
    
    if not groq_api_key:
        raise ValueError("GROQ_API_KEY not found in environment variables")
    
    chain = EmailChain(groq_api_key)
    
    recipient_info = """
    Name: John Doe
    Position: Software Engineer at Tech Corp
    Experience: 5 years in Python development
    """
    
    sender_info = """
    Name: Jane Smith
    Position: Technical Recruiter
    Company: AI Solutions Inc
    """
    
    purpose = "Recruiting for a Senior Python Developer position"
    
    email = chain.generate_email(
        recipient_info=recipient_info,
        sender_info=sender_info,
        purpose=purpose
    )
    
    print(email)


if __name__ == "__main__":
    main() 