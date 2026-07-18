#!/bin/bash

set -eo pipefail

MODEL_DIR="./models"
MODEL_FILE="gemma-4-26B-A4B-it-qat-UD-Q4_K_XL.gguf"
HOST_PORT="8080"
IMAGE="ghcr.io/ggml-org/llama.cpp:server-cuda-b10015"
CONTAINER_NAME="llama-server"
LOG_FILE="/tmp/llama-server.log"

echo "=========================================="
echo "  llama.cpp with Gemma-4-26B (NO internet)"
echo "  Model alias: 'standard'"
echo "=========================================="

# Download model if missing
if [ ! -f "${MODEL_DIR}/${MODEL_FILE}" ]; then
    echo ""
    echo "📥 Downloading model from Hugging Face..."
    mkdir -p "${MODEL_DIR}"
    
    hf download \
        unsloth/gemma-4-26B-A4B-it-qat-GGUF \
        --local-dir "${MODEL_DIR}" \
        --include "*mmproj-BF16*" \
        --include "*UD-Q4_K_XL*"
    
    echo "✅ Model downloaded"
fi

# Remove existing container
if docker ps -a | grep -q "${CONTAINER_NAME}"; then
    docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true
fi

# Clear old log file
> "${LOG_FILE}"

echo ""
echo "🚀 Starting server with NO internet..."
echo "   API: http://localhost:${HOST_PORT}"
echo "   Logs: ${LOG_FILE}"
echo ""

# Run container with logging - redirect stdout to log file only
docker run --rm --name "${CONTAINER_NAME}" \
    --network llm-net \
    --gpus all \
    --ulimit memlock=-1:-1 \
    -p "${HOST_PORT}:8080" \
    -v "$(realpath ${MODEL_DIR}):/models" \
    "${IMAGE}" \
    --model "/models/${MODEL_FILE}" \
    --alias "standard" \
    --port 8080 \
    --host "0.0.0.0" \
    --no-webui \
    --parallel 1 \
    --no-kv-unified \
    --no-mmap \
    --mlock \
    --n-gpu-layers all \
    --n-cpu-moe 28 \
    --ctx-size 131072 \
    --threads 10 \
    --batch-size 4096 \
    --ubatch-size 1024 \
    --cache-type-k "q8_0" \
    --cache-type-v "q8_0" \
    --temp 1.0 \
    --top-p 0.95 \
    --top-k 64 \
    --reasoning off \
    -lv 4 \
> "${LOG_FILE}" 2>&1 &

# Wait a moment for the container to obtain an IP
sleep 2
CONTAINER_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)

if [[ -z "$CONTAINER_IP" ]]; then
    echo "❌ Could not retrieve container IP. Internet might NOT be blocked."
    echo "   You can block manually later."
else
    echo "🔒 Blocking internet for container IP $CONTAINER_IP"
    echo "   Allowing traffic to Docker internals (172.0.0.0/8) and local LAN (192.168.0.0/24)"
    # 1. Insert a DROP rule at the top (will become rule #1)
    sudo iptables -I FORWARD -s "$CONTAINER_IP" ! -d 172.0.0.0/8 -j DROP
    # 2. Insert an ACCEPT rule *before* the DROP rule (position 1)
    #    This allows traffic to the local LAN network.
    sudo iptables -I FORWARD 1 -s "$CONTAINER_IP" -d 192.168.0.0/24 -j ACCEPT
fi

# Wait for ready message
echo "⏳ Loading model (this may take several minutes)..."
echo ""

# Follow logs without duplication
while IFS= read -r line; do
    echo "$line"
    if echo "$line" | grep -q "listening on http://0.0.0.0:8080"; then
        echo ""
        echo "✅ Server ready!"
        break
    fi
done < <(tail -f "${LOG_FILE}" 2>/dev/null)

# Show summary
echo ""
echo "=============================="
echo "  📊 Server Information"
echo "=============================="

echo "API: http://localhost:${HOST_PORT}"
echo "Container IP: ${CONTAINER_IP}"
echo "Model: standard"
echo "Container: ${CONTAINER_NAME}"
echo ""

# Wait a moment for the server to fully initialize
sleep 3

# Test the connection with more details
echo "🔍 Testing API connection..."
echo ""

# Try curl with verbose output
if curl -v "http://localhost:${HOST_PORT}/v1/models" 2>&1 | head -20; then
    echo ""
    echo "✅ API is responding!"
    echo ""
    echo "Test with:"
    echo "  curl http://localhost:${HOST_PORT}/v1/models"
    echo ""
    echo "  curl -X POST http://localhost:${HOST_PORT}/v1/chat/completions \\"
    echo "    -H \"Content-Type: application/json\" \\"
    echo "    -d '{\"model\":\"standard\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello!\"}]}'"
    echo ""
else
    echo ""
    echo "⚠️  API not responding. Debugging info:"
    echo ""
    echo "1. Check if container is running:"
    echo "   docker ps | grep ${CONTAINER_NAME}"
    echo ""
    echo "2. Check port mapping:"
    echo "   docker port ${CONTAINER_NAME}"
    echo ""
    echo "3. Test from inside container:"
    echo "   docker exec ${CONTAINER_NAME} curl -s http://localhost:8080/v1/models"
    echo ""
    echo "4. Check full logs:"
    echo "   cat ${LOG_FILE}"
    echo ""
fi
