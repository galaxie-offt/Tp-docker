#!/bin/bash
set -e

IMAGE_NAME=localhost:5000/app:latest

echo "[*] Building image..."
docker build -t $IMAGE_NAME ./app

echo "[*] Pushing to registry..."
docker push $IMAGE_NAME

echo "[*] Stopping containers..."
docker compose down

echo "[*] Starting services..."
docker compose up -d

echo "[+] Pipeline completed successfully"
