from dotenv import load_dotenv
import os

# Load environment variables from .env file
load_dotenv()

# Get the user agent from environment variables
user_agent = os.getenv('USER_AGENT')

# Example usage
print(f"Using User Agent: {user_agent}")

# You can use this user agent in your requests
import requests

headers = {
    'User-Agent': user_agent
}

# Example request
# response = requests.get('https://example.com', headers=headers) 