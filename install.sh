#!/bin/bash
# install-dependencies.sh - Setup script for llama.cpp with GPU support
# Installs: Hugging Face CLI, NVIDIA Container Toolkit, and configures Docker

set -eo pipefail  # Exit on any error

# ============================================================================
# 1. Install Hugging Face CLI
# ============================================================================

echo ""
echo "=== Installing Hugging Face CLI ==="
echo ""

# Install pipx if not available
if ! command -v pipx &> /dev/null; then
    echo "Installing pipx..."
    python3 -m pip install --user pipx
    python3 -m pipx ensurepath
    export PATH="$HOME/.local/bin:$PATH"
fi

# Install or upgrade huggingface-hub
if command -v hf &> /dev/null; then
    echo "Upgrading huggingface-hub..."
    pipx upgrade huggingface-hub
else
    echo "Installing huggingface-hub via pipx..."
    pipx install huggingface-hub
fi

echo "✓ Hugging Face CLI installed"

# ============================================================================
# 2. Install NVIDIA Container Toolkit
# ============================================================================

echo ""
echo "=== Installing NVIDIA Container Toolkit ==="
echo ""

# Check for NVIDIA drivers
if ! command -v nvidia-smi &> /dev/null; then
    echo "⚠ Warning: NVIDIA drivers not found. Proceeding anyway..."
else
    echo "✓ NVIDIA drivers detected"
fi

# Add repository
echo "Adding NVIDIA Container Toolkit repository..."
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
    sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
    sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
    sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null

# Update and install
echo "Updating package list..."
sudo apt-get update -qq

echo "Installing NVIDIA Container Toolkit..."
sudo apt-get install -y nvidia-container-toolkit

# Configure Docker
echo "Configuring Docker for NVIDIA runtime..."
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker

echo "✓ NVIDIA Container Toolkit installed and configured"

# ============================================================================
# 3. Create Docker Network for LLM services
# ============================================================================

echo ""
echo "=== Creating Docker Network: llm-net ==="
echo ""

NETWORK_NAME="llm-net"
if docker network inspect "$NETWORK_NAME" &>/dev/null; then
    echo "✓ Docker network '$NETWORK_NAME' already exists"
else
    echo "Creating Docker network '$NETWORK_NAME'..."
    docker network create "$NETWORK_NAME"
    echo "✓ Docker network '$NETWORK_NAME' created"
fi

# ============================================================================
# 4. Verify Installation
# ============================================================================

echo ""
echo "=== Verifying Installation ==="
echo ""

# Check hf CLI
if command -v hf &> /dev/null; then
    echo "✓ Hugging Face CLI: $(hf --version 2>/dev/null | head -n1)"
else
    echo "✗ Hugging Face CLI not found in PATH"
fi

# Check NVIDIA drivers
if command -v nvidia-smi &> /dev/null; then
    echo "✓ NVIDIA drivers: $(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1)"
else
    echo "⚠ NVIDIA drivers not found"
fi

# Check Docker GPU access
if docker run --rm --gpus all ubuntu nvidia-smi | grep 'NVIDIA-SMI' 2>/dev/null; then
    echo "✓ Docker GPU support: working"
else
    echo "⚠ Docker GPU support: not tested"
fi

# Show network info
echo "✓ Docker network '$NETWORK_NAME' is ready"
echo "   (Use it for containers: --network $NETWORK_NAME)"

echo "✓ Setup complete!"
