#!/bin/bash

set -eo pipefail

CONTAINER_NAME="llama-server"
CONTAINER_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$CONTAINER_NAME" 2>/dev/null)

echo -e "\n🛑 Shutting down..."

# Remove iptables rule if it was set
if [[ -n "$CONTAINER_IP" ]]; then
    sudo iptables -D FORWARD -s "$CONTAINER_IP" ! -d 172.0.0.0/8 -j DROP 2>/dev/null \
        && echo "🧹 iptables rule removed."
fi

# Stop and remove container
docker rm -f "$CONTAINER_NAME" &>/dev/null
