"""Chain definitions for the application."""

import os
from langchain_groq import ChatGroq
from langchain_core.prompts import PromptTemplate
from langchain_core.output_parsers import JsonOutputParser
from langchain_core.exceptions import OutputParserException
from dotenv import load_dotenv
from langchain_community.document_loaders import WebBaseLoader
from langchain.chains import LLMChain

load_dotenv()

# Configure WebBaseLoader with user agent
WebBaseLoader.requests_kwargs = {
    'headers': {
        'User-Agent': (
            os.getenv('USER_AGENT', 
                     'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
                     'AppleWebKit/537.36 (KHTML, like Gecko) '
                     'Chrome/122.0.0.0 Safari/537.36')
        )
    }
}


class EmailChain:
    """Chain for generating cold emails."""

    def __init__(self, groq_api_key: str):
        """Initialize the email chain.

        Args:
            groq_api_key: The GROQ API key for authentication
        """
        self.llm = ChatGroq(
            groq_api_key=groq_api_key,
            model_name="mixtral-8x7b-32768",
            temperature=0.7,
            max_tokens=32768
        )

        self.prompt = PromptTemplate(
            input_variables=["recipient_info", "sender_info", "purpose"],
            template="""
            Generate a professional cold email based on the following information:

            Recipient Information:
            {recipient_info}

            Sender Information:
            {sender_info}

            Purpose:
            {purpose}

            Please write a compelling cold email that:
            1. Is personalized and relevant to the recipient
            2. Clearly states the purpose
            3. Includes a clear call to action
            4. Is concise and professional
            5. Has a friendly but professional tone

            Email:
            """
        )

        self.chain = LLMChain(llm=self.llm, prompt=self.prompt)

    def generate_email(
        self,
        recipient_info: str,
        sender_info: str,
        purpose: str
    ) -> str:
        """Generate a cold email.

        Args:
            recipient_info: Information about the recipient
            sender_info: Information about the sender
            purpose: The purpose of the email

        Returns:
            The generated email text
        """
        return self.chain.run(
            recipient_info=recipient_info,
            sender_info=sender_info,
            purpose=purpose
        )


class Chain:
    """Chain for job extraction and email generation."""

    def __init__(self):
        """Initialize the chain with GROQ LLM."""
        self.llm = ChatGroq(
            temperature=0,
            groq_api_key=os.getenv("GROQ_API_KEY"),
            model_name="llama-3.3-70b-versatile"
        )

    def extract_jobs(self, cleaned_text):
        """Extract job information from cleaned text.

        Args:
            cleaned_text: Cleaned text from website

        Returns:
            List of extracted jobs
        """
        prompt_extract = PromptTemplate.from_template(
            """
            ### SCRAPED TEXT FROM WEBSITE:
            {page_data}
            ### INSTRUCTION:
            The scraped text is from the career's page of a website.
            Your job is to extract the job postings and return them in JSON format 
            containing the following keys: `role`, `experience`, `skills` and `description`.
            Only return the valid JSON.
            ### VALID JSON (NO PREAMBLE):
            """
        )
        chain_extract = prompt_extract | self.llm
        res = chain_extract.invoke(input={"page_data": cleaned_text})
        try:
            json_parser = JsonOutputParser()
            res = json_parser.parse(res.content)
        except OutputParserException:
            raise OutputParserException("Context too big. Unable to parse jobs.")
        return res if isinstance(res, list) else [res]

    def write_mail(self, job, links):
        """Generate email based on job and portfolio links.

        Args:
            job: Job description
            links: Portfolio links

        Returns:
            Generated email text
        """
        prompt_email = PromptTemplate.from_template(
            """
            ### JOB DESCRIPTION:
            {job_description}

            ### INSTRUCTION:
            You are Mohan, a business development executive at AtliQ. 
            AtliQ is an AI & Software Consulting company dedicated to facilitating
            the seamless integration of business processes through automated tools. 
            Over our experience, we have empowered numerous enterprises with 
            tailored solutions, fostering scalability, process optimization, 
            cost reduction, and heightened overall efficiency. 
            Your job is to write a cold email to the client regarding the job 
            mentioned above describing the capability of AtliQ in fulfilling 
            their needs.
            Also add the most relevant ones from the following links to showcase 
            Atliq's portfolio: {link_list}
            Remember you are Mohan, BDE at AtliQ. 
            Do not provide a preamble.
            ### EMAIL (NO PREAMBLE):
            """
        )
        chain_email = prompt_email | self.llm
        res = chain_email.invoke({
            "job_description": str(job),
            "link_list": links
        })
        return res.content


if __name__ == "__main__":
    print(os.getenv("GROQ_API_KEY"))