"""Configuration for pytest."""
import os
import sys

# Add the parent directory to path so the app modules can be imported
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

def pytest_sessionstart(session):
    """
    Called after the Session object has been created and before running tests.
    """
    print("Starting test session")
    print(f"Python path: {sys.path}")
    
    # Ensure the app directory is in the Python path
    app_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), '../app'))
    if app_dir not in sys.path:
        sys.path.insert(0, app_dir)
        print(f"Added app directory to path: {app_dir}") 