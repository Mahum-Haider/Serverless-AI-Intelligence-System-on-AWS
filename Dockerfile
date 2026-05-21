# Use a modern Python version to fix the deprecation warning
FROM python:3.11-slim

# Set the directory inside the container
WORKDIR /app

# Install the AWS library
RUN pip install --no-cache-dir boto3

# Copy your working script into the container
COPY admin_tool.py .

# Run the script automatically
CMD ["python", "admin_tool.py"]