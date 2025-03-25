"""Test cases for utility functions."""

import pytest
from app.utils import format_experience, validate_input, process_portfolio_data


def test_format_experience():
    """Test experience formatting function."""
    test_experience = [
        {
            "role": "Developer",
            "company": "Tech Corp",
            "duration": "2 years"
        }
    ]
    expected = "- Developer at Tech Corp (2 years)"
    assert format_experience(test_experience) == expected


def test_validate_input():
    """Test input validation function."""
    assert validate_input("  test  ") == "test"
    assert validate_input("") == ""
    assert validate_input(None) == ""


def test_process_portfolio_data():
    """Test portfolio data processing function."""
    test_data = {
        "name": "John Doe",
        "position": "Software Engineer",
        "experience": [
            {
                "role": "Developer",
                "company": "Tech Corp",
                "duration": "2 years"
            }
        ]
    }
    result = process_portfolio_data(test_data)
    assert result["name"] == "John Doe"
    assert result["position"] == "Software Engineer"
    assert len(result["experience"]) == 1 