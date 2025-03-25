# Build stage
FROM python:3.12-slim AS builder

# Set working directory
WORKDIR /app

# Install build dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Copy requirements
COPY requirements.txt .

# Install dependencies into a virtual environment
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
# Install without using hashes to avoid hash verification errors
RUN pip install --upgrade pip && \
    pip install --no-cache-dir blinker>=1.6.2 && \
    pip install --no-cache-dir -r requirements.txt || \
    pip install --no-cache-dir --no-deps -r requirements.txt && \
    pip install --no-cache-dir streamlit>=1.35.0 blinker>=1.6.2

# Runtime stage
FROM python:3.12-slim AS runtime

# Set working directory
WORKDIR /app

# Install curl for healthcheck
RUN apt-get update && apt-get install -y \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Copy virtual environment from builder stage
COPY --from=builder /opt/venv /opt/venv

# Set environment variables
ENV PATH="/opt/venv/bin:$PATH"
ENV PYTHONUNBUFFERED=1

# Copy application code
COPY . .

# Create .streamlit directory
RUN mkdir -p /app/.streamlit

# Expose the port Streamlit runs on
EXPOSE 8501

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:8501/_stcore/health || exit 1

# Command to run the application
CMD ["streamlit", "run", "app/main.py", "--server.address=0.0.0.0"] 