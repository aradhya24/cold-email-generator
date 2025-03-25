"""Utility functions for text processing and validation."""
import re
from typing import List, Dict, Any
from bs4 import BeautifulSoup


def clean_text(text: str) -> str:
    """Clean and normalize text content."""
    try:
        # Remove HTML tags
        soup = BeautifulSoup(text, 'html.parser')
        text = soup.get_text()
        
        # Remove extra whitespace
        text = re.sub(r'\s+', ' ', text)
        
        # Remove special characters but keep basic punctuation
        text = re.sub(r'[^\w\s.,!?-]', '', text)
        
        # Normalize whitespace
        text = ' '.join(text.split())
        
        return text.strip()
    except Exception as e:
        print(f"Error cleaning text: {e}")
        return text  # Return original text if cleaning fails


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
    """Process portfolio data into a standardized format.

    Args:
        data: Raw portfolio data

    Returns:
        Processed portfolio data
    """
    return {
        'name': data.get('name', ''),
        'position': data.get('position', ''),
        'experience': data.get('experience', [])
    }