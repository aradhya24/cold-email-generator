"""Portfolio module for managing and retrieving portfolio information."""

import os
import csv
import pandas as pd
from typing import List, Dict, Any
from utils import process_portfolio_data

DEFAULT_PORTFOLIO_PATH = "my_portfolio.csv"

class PortfolioProcessor:
    """Process portfolio data into a usable format."""
    
    @staticmethod
    def from_csv(file_path: str) -> List[Dict[str, Any]]:
        """Load portfolio data from CSV file."""
        try:
            # Read the CSV file
            if os.path.exists(file_path):
                df = pd.read_csv(file_path)
                # Convert to list of dictionaries
                return df.to_dict('records')
            else:
                print(f"Portfolio file not found: {file_path}")
                return []
        except Exception as e:
            print(f"Error loading portfolio: {e}")
            return []


class Portfolio:
    """Portfolio for storing and retrieving portfolio information."""
    
    def __init__(self, file_path: str = DEFAULT_PORTFOLIO_PATH):
        """Initialize the portfolio."""
        self.file_path = file_path
        self.portfolio = []
        self.skills_index = {}
    
    def load_portfolio(self) -> None:
        """Load the portfolio from file."""
        try:
            if not os.path.exists(self.file_path):
                print(f"Portfolio file not found: {self.file_path}")
                # Create a default portfolio
                self.create_default_portfolio()
            else:
                # Load portfolio data
                self.portfolio = PortfolioProcessor.from_csv(self.file_path)
            
            # Create a skills index for faster querying
            self.build_skills_index()
        except Exception as e:
            print(f"Error loading portfolio: {e}")
            # Create a default portfolio as fallback
            self.create_default_portfolio()
    
    def create_default_portfolio(self) -> None:
        """Create a default portfolio with sample data."""
        self.portfolio = [
            {
                "project": "E-commerce Analytics Dashboard",
                "url": "https://github.com/atliq/ecommerce-analytics",
                "skills": "python,data analysis,visualization,dashboard"
            },
            {
                "project": "Customer Segmentation Engine",
                "url": "https://github.com/atliq/customer-segmentation",
                "skills": "machine learning,clustering,python,data science"
            },
            {
                "project": "Inventory Management System",
                "url": "https://github.com/atliq/inventory-management",
                "skills": "java,database,api development,backend"
            },
            {
                "project": "Sales Forecasting Tool",
                "url": "https://github.com/atliq/sales-forecast",
                "skills": "predictive analytics,time series,python,statistics"
            },
            {
                "project": "HR Analytics Dashboard",
                "url": "https://github.com/atliq/hr-analytics",
                "skills": "power bi,data visualization,analytics,reporting"
            }
        ]
        
        # Build skills index
        self.build_skills_index()
    
    def build_skills_index(self) -> None:
        """Build an index of skills to portfolio items."""
        self.skills_index = {}
        
        for item in self.portfolio:
            # Process the skills for this item
            if "skills" in item:
                skills = [s.strip().lower() for s in item["skills"].split(",")]
                
                # Add to skills index
                for skill in skills:
                    if skill not in self.skills_index:
                        self.skills_index[skill] = []
                    self.skills_index[skill].append(item)
    
    def query_links(self, skills: List[str]) -> List[str]:
        """Query portfolio links based on skills.
        
        Args:
            skills: List of skills to query
            
        Returns:
            List of relevant portfolio links
        """
        if not skills:
            # Return a few default links if no skills provided
            return [item["url"] for item in self.portfolio[:2]]
        
        # Normalize skills
        normalized_skills = [s.strip().lower() for s in skills]
        
        # Find matching portfolio items
        matching_items = []
        for skill in normalized_skills:
            # Look for exact matches
            if skill in self.skills_index:
                matching_items.extend(self.skills_index[skill])
            else:
                # Look for partial matches
                for index_skill in self.skills_index:
                    if skill in index_skill or index_skill in skill:
                        matching_items.extend(self.skills_index[index_skill])
        
        # Remove duplicates and get URLs
        seen = set()
        unique_links = []
        
        for item in matching_items:
            if item["url"] not in seen:
                seen.add(item["url"])
                unique_links.append(f"{item['project']}: {item['url']}")
        
        # Return up to 3 most relevant links
        return unique_links[:3] if unique_links else [item["url"] for item in self.portfolio[:2]]
