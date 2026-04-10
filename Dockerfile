FROM python:3.9-slim

ENV DEBIAN_FRONTEND=noninteractive

# Install system dependencies for psycopg2
RUN apt-get update && apt-get install -y \
    build-essential \
    libpq-dev \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Install Python packages
RUN pip install --no-cache-dir \
    mlflow \
    boto3 \
    psycopg2-binary

WORKDIR /app

# Create a startup script
RUN echo '#!/bin/bash\n\
set -e\n\
mlflow server \
  --backend-store-uri "${BACKEND_STORE_URI}" \
  --default-artifact-root "${DEFAULT_ARTIFACT_ROOT}" \
  --host 0.0.0.0 \
  --port 5000 \
  ${EXTRA_MLFLOW_ARGS}' > /app/start.sh && chmod +x /app/start.sh

EXPOSE 5000

ENTRYPOINT ["/app/start.sh"]