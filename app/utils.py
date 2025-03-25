"""Utility functions for text processing and validation."""
import re
import traceback
import time
from typing import List, Dict, Any
from bs4 import BeautifulSoup


def clean_text(text: str) -> str:
    """Clean and normalize text content."""
    try:
        start_time = time.time()
        print(f"Starting text cleaning. Original text length: {len(text)}")
        
        # Handle empty text
        if not text or len(text.strip()) == 0:
            print("Warning: Empty text received")
            return ""
        
        # Process a reasonable amount of text
        if len(text) > 100000:
            print(f"Text too large ({len(text)} chars), truncating...")
            text = text[:100000]
            
        # Remove HTML tags - use a more efficient approach
        try:
            # Use lxml parser for better performance
            soup = BeautifulSoup(text, 'lxml')
            
            # Remove script and style elements
            for script_or_style in soup(["script", "style"]):
                script_or_style.decompose()
                
            # Get the text
            text = soup.get_text(separator=' ', strip=True)
            print(f"Text after HTML parsing: {len(text)} characters")
        except Exception as e:
            print(f"Error in BeautifulSoup parsing: {e}")
            # Fallback to basic regex if BeautifulSoup fails
            text = re.sub(r'<script.*?</script>', ' ', text, flags=re.DOTALL)
            text = re.sub(r'<style.*?</style>', ' ', text, flags=re.DOTALL)
            text = re.sub(r'<[^>]*?>', ' ', text)
            
        # Basic cleaning - combine into one step
        text = ' '.join(text.split())
        
        # Only remove problematic characters, keep most punctuation
        text = re.sub(r'[^\w\s.,!?:\-\'"]', ' ', text)
        
        print(f"Text cleaning completed in {time.time() - start_time:.2f} seconds. Final length: {len(text)}")
        return text.strip()
    except Exception as e:
        print(f"Error cleaning text: {e}")
        print(traceback.format_exc())
        # If all cleaning fails, just normalize whitespace
        try:
            return ' '.join(text.split())
        except:
            return text if text else ""


def format_experience(experience: str) -> str:
    """Format experience string to a standard format."""
    try:
        # Simple formatting to avoid processing delays
        return experience.strip() if experience else "Not specified"
    except Exception as e:
        print(f"Error formatting experience: {e}")
        return "Not specified"


def validate_input(data: Dict[str, Any]) -> List[str]:
    """Validate input data and return list of errors."""
    errors = []
    
    # Simple validation to avoid processing delays
    if not data:
        errors.append("No data provided")
        return errors
    
    required_fields = ['title', 'company']
    for field in required_fields:
        if not data.get(field):
            errors.append(f"{field.capitalize()} is required")
    
    return errors


def process_portfolio_data(data):
    """Process the portfolio data into a more usable format."""
    skills = set()
    
    # Add skills directly from the skills field
    if 'skills' in data:
        for skill in data['skills'].split(','):
            skills.add(skill.strip().lower())
    
    # Extract skills from projects if available
    if 'projects' in data:
        for project in data['projects'].split(','):
            project_skills = project.split(':')
            if len(project_skills) > 1:
                for skill in project_skills[1].split('&'):
                    skills.add(skill.strip().lower())
    
    return list(skills)