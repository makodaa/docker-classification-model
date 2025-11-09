FROM python:3.9-slim

WORKDIR /app

RUN apt-get update && apt-get install -y curl libgomp1 libglib2.0-0 libsm6 libxext6 libxrender-dev && rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN groupadd -r -g 1000 appuser && \
    useradd -r -u 1000 -g appuser appuser

# Install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir torch torchvision --index-url https://download.pytorch.org/whl/cpu && \
    pip install --no-cache-dir -r requirements.txt

# Copy application files
COPY app.py .
COPY database.py .
COPY models/ ./models/
COPY test_data/ ./test_data/

# Create uploads directory and transfer ownership
RUN mkdir -p /app/uploads && \
    chown -R appuser:appuser /app

# Environment variables
ENV MODEL_PATH=/app/models/model.pth
ENV LABELS_PATH=/app/models/class_labels.json
ENV INPUT_SIZE=224,224
ENV PORT=8000

# Switch to non-root user
USER 1000:1000

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
    CMD curl -f http://localhost:8000/health || exit 1

CMD ["python", "app.py"]