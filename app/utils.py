"""Utility functions for text processing and validation."""
import re
import traceback
from typing import List, Dict, Any
from bs4 import BeautifulSoup


def clean_text(text: str) -> str:
    """Clean and normalize text content."""
    try:
        print(f"Original text length: {len(text)}")
        
        # Handle empty text
        if not text or len(text.strip()) == 0:
            print("Warning: Empty text received")
            return ""
            
        # Remove HTML tags
        try:
            soup = BeautifulSoup(text, 'html.parser')
            text = soup.get_text(separator=' ')
            print(f"Text after HTML parsing: {len(text)} characters")
        except Exception as e:
            print(f"Error in BeautifulSoup parsing: {e}")
            # Fallback to regex if BeautifulSoup fails
            text = re.sub(r'<[^>]*?>', ' ', text)
            
        # Remove extra whitespace
        text = re.sub(r'\s+', ' ', text)
        
        # Remove special characters but keep basic punctuation
        text = re.sub(r'[^\w\s.,!?-]', '', text)
        
        # Normalize whitespace
        text = ' '.join(text.split())
        
        print(f"Cleaned text length: {len(text)}")
        return text.strip()
    except Exception as e:
        print(f"Error cleaning text: {e}")
        print(traceback.format_exc())
        # Return a truncated version of the original text if cleaning fails
        return text[:10000] if text else ""


def format_experience(experience: str) -> str:
    """Format experience string to a standard format."""
    try:
        # Remove any non-numeric characters except dots
        years = re.sub(r'[^\d.]', '', experience)
        
        # Convert to float if possible
        try:
            years = float(years)
            return f"{years:.1f} years"
        except ValueError:
            return experience
    except Exception as e:
        print(f"Error formatting experience: {e}")
        return experience


def validate_input(data: Dict[str, Any]) -> List[str]:
    """Validate input data and return list of errors."""
    errors = []
    
    required_fields = ['title', 'company', 'location']
    for field in required_fields:
        if not data.get(field):
            errors.append(f"{field.capitalize()} is required")
    
    return errors


def process_portfolio_data(data):
    """Process the portfolio data into a more usable format."""
    skills = set()
    for skill in data['skills'].split(','):
        skills.add(skill.strip().lower())
    
    for project in data['projects'].split(','):
        project_skills = project.split(':')
        if len(project_skills) > 1:
            for skill in project_skills[1].split('&'):
                skills.add(skill.strip().lower())
    
    return list(skills)