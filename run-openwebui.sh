#!/usr/bin/env bash

# OpenWebUI on Docker - Port 80, connecting to llama.cpp server container
# ======================================================================
# This script runs OpenWebUI and configures it to use your llama-server
# container as the LLM backend via the OpenAI‑compatible API.
#
# Prerequisites:
#   - Docker installed.
#   - Your 'llama-server' container is already running and exposed on port 8080.
#   - Both containers are on the same Docker network (see "Network Setup" below).
#   - Root/sudo access (port 80 is privileged).

set -e

IMAGE="ghcr.io/open-webui/open-webui:main"
CONTAINER_NAME="open-webui"
HOST_PORT=80
CONTAINER_PORT=8080
VOLUME_NAME="open-webui-data"

# --- Backend settings for llama.cpp server (OpenAI-compatible) ---
# Change this to match your llama-server container's name and port.
# If your server serves at /v1, include it; otherwise adjust.
LLAMA_SERVER_URL="${LLAMA_SERVER_URL:-http://llama-server:8080/v1}"
DUMMY_API_KEY="not-needed"   # llama.cpp server usually doesn't require a key

# --- Pull the latest image ---
echo "📦 Pulling $IMAGE ..."
docker pull "$IMAGE"

# --- Stop and remove any existing container with the same name ---
if docker ps -a --format '{{.Names}}' | grep -q "^$CONTAINER_NAME$"; then
    echo "🔄 Stopping and removing existing container '$CONTAINER_NAME' ..."
    docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
fi

# --- Run the container ---
echo "🚀 Starting OpenWebUI on port $HOST_PORT ..."
docker run -d --rm --name "$CONTAINER_NAME" \
    --network llm-net \
    -p "$HOST_PORT:$CONTAINER_PORT" \
    -v "$VOLUME_NAME:/app/backend/data" \
    -e OPENAI_API_BASE_URL="$LLAMA_SERVER_URL" \
    -e OPENAI_API_KEY="$DUMMY_API_KEY" \
    "$IMAGE"

# --- Check status ---
if docker ps --format '{{.Names}}' | grep -q "^$CONTAINER_NAME$"; then
    echo "✅ OpenWebUI is running!"
    echo "🌐 Access it at: http://localhost:$HOST_PORT"
    echo "📁 Persistent data stored in Docker volume: $VOLUME_NAME"
    echo "🔗 LLM backend set to: $LLAMA_SERVER_URL"
else
    echo "❌ Container failed to start. Check logs with: docker logs $CONTAINER_NAME"
    exit 1
fi
