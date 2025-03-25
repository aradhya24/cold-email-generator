"""Utility functions for the application."""

import re

def clean_text(text):
    # Remove HTML tags
    text = re.sub(r'<[^>]*?>', '', text)
    # Remove URLs
    text = re.sub(r'http[s]?://(?:[a-zA-Z]|[0-9]|[$-_@.&+]|[!*\\(\\),]|(?:%[0-9a-fA-F][0-9a-fA-F]))+', '', text)
    # Remove special characters
    text = re.sub(r'[^a-zA-Z0-9 ]', '', text)
    # Replace multiple spaces with a single space
    text = re.sub(r'\s{2,}', ' ', text)
    # Trim leading and trailing whitespace
    text = text.strip()
    # Remove extra whitespace
    text = ' '.join(text.split())
    return text

def format_experience(experience_list):
    """Format the experience list into a readable string."""
    return '\n'.join(
        f"- {exp.get('role')} at {exp.get('company')} ({exp.get('duration')})"
        for exp in experience_list
    )

def validate_input(text):
    """Validate user input for safety and formatting."""
    return text.strip() if text else ""