FROM python:3.11-slim

WORKDIR /app

COPY app.py /app/
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh && \
    apt-get update && apt-get install -y iptables && \
    pip install flask pymysql && \
    rm -rf /var/lib/apt/lists/*

ENTRYPOINT ["/entrypoint.sh"]
CMD ["python", "app.py"]
