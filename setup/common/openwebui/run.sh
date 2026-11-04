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
IMAGE="ghcr.io/open-webui/open-webui:v0.13.0"
SERVICE_DIR="$SERVICE_CONFIG/$UNIT"
VOLUME="llm-server-openwebui-data"
STATIC_VOLUME="llm-server-openwebui-static"

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
ensure_api_key
ensure_webui_secret
API_KEY="$(cat "$API_KEY_FILE")"
WEBUI_SECRET_KEY="$(cat "$WEBUI_SECRET_FILE")"

TEMPLATE_VERSION=2
CONFIG_SIG="$(config_signature "$TEMPLATE_VERSION" "$IMAGE" "$BIND_ADDR" "$HOST_PORT" \
    "$API_KEY" "$WEBUI_SECRET_KEY")"
HEALTH_URL="http://127.0.0.1:${HOST_PORT}/health"

print_summary() {
    cat <<EOF

OpenWebUI service: $UNIT
Web UI:  http://$BIND_ADDR:$HOST_PORT
Backend: http://llm-model:8080/v1
Logs:    journalctl --user -u $UNIT -f
EOF
}

if [[ "${LLM_FORCE_REINSTALL:-0}" != "1" ]] && \
   [[ "$(stored_config_signature "$SERVICE_DIR/.env")" == "$CONFIG_SIG" ]] && \
   systemctl --user is-active --quiet "$UNIT"; then
    if http_matches "$HEALTH_URL" '"status":[[:space:]]*true'; then
        log "OpenWebUI is already running; nothing to do."
    else
        log "OpenWebUI is already running; it is still starting."
    fi
    enable_unit "$UNIT" 2>/dev/null || true
    write_service_state "$UNIT" ui "$SERVICE_DIR" "$PROJECT" "$CONTAINER" "$HOST_PORT"
    print_summary
    exit 0
fi

if [[ -f "$SERVICE_STATE/$UNIT.env" ]]; then
    stop_service_from_state "$SERVICE_STATE/$UNIT.env"
else
    systemctl --user stop "$UNIT" 2>/dev/null || true
    systemctl --user disable "$UNIT" 2>/dev/null || true
fi
port_available "$HOST_PORT" || die "Port $HOST_PORT is already in use. Stop the conflicting service first."

ensure_docker_network
docker pull "$IMAGE"

mkdir -p "$SERVICE_DIR"
chmod 700 "$LLM_CONFIG" "$SERVICE_CONFIG" "$SERVICE_DIR"

cat > "$SERVICE_DIR/.env" <<EOF
CONFIG_SIG=$CONFIG_SIG
IMAGE=$IMAGE
HOST_PORT=$HOST_PORT
BIND_ADDR=$BIND_ADDR
PROJECT=$PROJECT
CONTAINER=$CONTAINER
STATIC_VOLUME=$STATIC_VOLUME
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
      # OpenWebUI writes branding assets (favicon, splash, loader, custom.css)
      # into its static directory at startup. This volume is populated from
      # the image on first use, so the root filesystem can stay read-only.
      - openwebui-static:/app/backend/open_webui/static
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
    healthcheck:
      test:
        - CMD
        - python3
        - -c
        - import urllib.request; urllib.request.urlopen("http://127.0.0.1:8080/health", timeout=3)
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 180s
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

volumes:
  openwebui-data:
    name: llm-server-openwebui-data
  openwebui-static:
    name: ${STATIC_VOLUME}

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

if wait_http_running "http://127.0.0.1:${HOST_PORT}/health" "${LLM_HEALTH_TIMEOUT:-900}" "$CONTAINER" "OpenWebUI"; then
    :
else
    rc=$?
    rollback_compose_service "$UNIT" "$SERVICE_DIR" "$PROJECT" "$CONTAINER"
    if ((rc == 2)); then
        die "OpenWebUI container exited before becoming healthy."
    fi
    if ((rc == 3)); then
        die "OpenWebUI restarted before becoming healthy."
    fi
    die "OpenWebUI did not become healthy."
fi

enable_unit "$UNIT"
write_service_state "$UNIT" ui "$SERVICE_DIR" "$PROJECT" "$CONTAINER" "$HOST_PORT"

print_summary
