"""Test cases for utility functions."""
from app.utils import validate_input, format_experience


def test_validate_input():
    """Test input validation function."""
    assert validate_input("  test  ") == "test"
    assert validate_input("") == ""
    assert validate_input(None) == ""


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