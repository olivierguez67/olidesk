FROM python:3.11-slim

WORKDIR /app

# Create a non-root user
RUN adduser --disabled-password --no-create-home --gecos "" appuser

# Install dependencies first (layer cache)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application
COPY app.py .
COPY config.json .

# Data volume placeholder — actual data lives on the host mount
RUN mkdir -p /data && chown appuser:appuser /data

USER appuser

EXPOSE 8443

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8443/health')"

CMD ["gunicorn", \
     "--bind", "0.0.0.0:8443", \
     "--workers", "2", \
     "--timeout", "30", \
     "--access-logfile", "-", \
     "--error-logfile", "-", \
     "app:app"]
