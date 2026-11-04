#!/usr/bin/env bash
# OpenWebUI as a separate user service on the shared llm-net network.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=lib/common.sh
source "$REPO_ROOT/lib/common.sh"

setup_user_env

DRY_RUN=0
while (($#)); do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        -h|--help) echo "Usage: $0 [--dry-run]"; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
    shift
done

HOST_PORT="${LLM_WEBUI_PORT:-3000}"
BIND_ADDR="${LLM_BIND_ADDR:-0.0.0.0}"
UNIT="llm-server-openwebui.service"
PROJECT="llm-server-openwebui"
CONTAINER="llm-server-openwebui"
IMAGE="ghcr.io/open-webui/open-webui:v0.1.121"
SERVICE_DIR="$SERVICE_CONFIG/$UNIT"
VOLUME="llm-server-openwebui-data"

if ((DRY_RUN)); then
    cat <<EOF
Service:     $UNIT
Image:       $IMAGE
Container:   $CONTAINER
Web UI:      http://$BIND_ADDR:$HOST_PORT
Backend:     http://llm-model:8080/v1
Data volume: $VOLUME
Config:      $SERVICE_DIR
EOF
    exit 0
fi

ensure_core_packages
if [[ -f "$SERVICE_STATE/$UNIT.env" ]]; then
    stop_service_from_state "$SERVICE_STATE/$UNIT.env"
else
    systemctl --user stop "$UNIT" 2>/dev/null || true
    systemctl --user disable "$UNIT" 2>/dev/null || true
fi
port_available "$HOST_PORT" || die "Port $HOST_PORT is already in use. Stop the conflicting service first."

ensure_docker_network
ensure_api_key
ensure_webui_secret
API_KEY="$(cat "$API_KEY_FILE")"
WEBUI_SECRET_KEY="$(cat "$WEBUI_SECRET_FILE")"
docker pull "$IMAGE"

mkdir -p "$SERVICE_DIR"
chmod 700 "$LLM_CONFIG" "$SERVICE_CONFIG" "$SERVICE_DIR"

cat > "$SERVICE_DIR/.env" <<EOF
IMAGE=$IMAGE
HOST_PORT=$HOST_PORT
BIND_ADDR=$BIND_ADDR
PROJECT=$PROJECT
CONTAINER=$CONTAINER
API_KEY=$API_KEY
WEBUI_SECRET_KEY=$WEBUI_SECRET_KEY
EOF
chmod 600 "$SERVICE_DIR/.env"

cat > "$SERVICE_DIR/compose.yml" <<'EOF'
services:
  webui:
    image: ${IMAGE}
    container_name: ${CONTAINER}
    restart: unless-stopped
    init: true
    environment:
      OPENAI_API_BASE_URL: "http://llm-model:8080/v1"
      OPENAI_API_KEY: ${API_KEY}
      WEBUI_SECRET_KEY: ${WEBUI_SECRET_KEY}
      ENABLE_OPENAI_API: "true"
      ENABLE_OLLAMA_API: "false"
      WEBUI_NAME: "Local LLM"
      HOME: "/tmp"
      PYTHONDONTWRITEBYTECODE: "1"
    ports:
      - "${BIND_ADDR}:${HOST_PORT}:8080"
    volumes:
      - openwebui-data:/app/backend/data
    networks:
      llm-net:
        aliases:
          - openwebui
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    read_only: true
    tmpfs:
      - /tmp:rw,noexec,nosuid,nodev,size=1g
      - /run:rw,noexec,nosuid,nodev,size=32m
    ipc: private
    shm_size: 256mb
    pids_limit: 1024
    stop_grace_period: 30s
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

volumes:
  openwebui-data:
    name: llm-server-openwebui-data

networks:
  llm-net:
    external: true
EOF

chmod 644 "$SERVICE_DIR/compose.yml"

validate_compose "$SERVICE_DIR" "$PROJECT" || die "Generated Compose file is invalid."
install_compose_unit \
    "$UNIT" \
    "OpenWebUI (rootless, user service)" \
    "$SERVICE_DIR" "$PROJECT" 900 60

if ! start_unit "$UNIT"; then
    rollback_compose_service "$UNIT" "$SERVICE_DIR" "$PROJECT" "$CONTAINER"
    die "Failed to start $UNIT."
fi

if wait_http_running "http://127.0.0.1:${HOST_PORT}/api/config" "${LLM_HEALTH_TIMEOUT:-900}" "$CONTAINER" "OpenWebUI"; then
    :
else
    rc=$?
    rollback_compose_service "$UNIT" "$SERVICE_DIR" "$PROJECT" "$CONTAINER"
    if ((rc == 2)); then
        die "OpenWebUI container exited before becoming healthy."
    fi
    die "OpenWebUI did not become healthy."
fi

enable_unit "$UNIT"
write_service_state "$UNIT" ui "$SERVICE_DIR" "$PROJECT" "$CONTAINER" "$HOST_PORT"

cat <<EOF

OpenWebUI service installed: $UNIT
Web UI:  http://$BIND_ADDR:$HOST_PORT
Backend: http://llm-model:8080/v1
Logs:    journalctl --user -u $UNIT -f
EOF
