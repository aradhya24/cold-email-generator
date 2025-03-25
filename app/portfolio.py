import pandas as pd
import chromadb
import uuid


class Portfolio:
    def __init__(self, file_path="app/resource/my_portfolio.csv"):
        self.file_path = file_path
        self.data = pd.read_csv(file_path)
        self.chroma_client = chromadb.PersistentClient('vectorstore')
        self.collection = self.chroma_client.get_or_create_collection(name="portfolio")

    def load_portfolio(self):
        if not self.collection.count():
            for _, row in self.data.iterrows():
                self.collection.add(documents=row["Techstack"],
                                    metadatas={"links": row["Links"]},
                                    ids=[str(uuid.uuid4())])

    def query_links(self, skills):
        return self.collection.query(query_texts=skills, n_results=2).get('metadatas', [])

def process_portfolio_data(data):
    # Split the long line into multiple lines
    return {
        'name': data.get('name', ''),
        'position': data.get('position', ''),
        'experience': data.get('experience', [])
    }

"""Portfolio data processing module."""


class PortfolioProcessor:
    """Process and manage portfolio data."""

    def __init__(self, collection):
        """Initialize the portfolio processor.

        Args:
            collection: ChromaDB collection for storing portfolio data
        """
        self.collection = collection

    def query_links(self, skills):
        """Query portfolio links based on skills.

        Args:
            skills: List of skills to search for

        Returns:
            List of matching portfolio links
        """
        return self.collection.query(
            query_texts=skills,
            n_results=2
        ).get('metadatas', [])
