#!/usr/bin/env bash
# Strata / Qwen3.8-Flash-Next installer for a 16 GB RTX 5060 Ti.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=lib/common.sh
source "$REPO_ROOT/lib/common.sh"

setup_user_env

DRY_RUN=0
SELECT_ONLY=0
while (($#)); do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --select-only) SELECT_ONLY=1 ;;
        -h|--help)
            echo "Usage: $0 [--dry-run|--select-only]"
            exit 0
            ;;
        *) die "Unknown option: $1" ;;
    esac
    shift
done

HARDWARE="${LLM_HARDWARE:-$(basename "$(dirname "$SCRIPT_DIR")")}"
ENGINE="$(basename "$SCRIPT_DIR")"
GPU_IDS="${LLM_GPU_IDS:-all}"
HOST_PORT="${LLM_PORT:-8080}"
BIND_ADDR="${LLM_BIND_ADDR:-0.0.0.0}"
# 256K with 4-bit values is the largest text-only context that fits this
# 16 GB GPU / 52 GB RAM host and still decodes well above 25 tokens/s.
# Use LLM_CONTEXT=128k LLM_KV=int8 for more RAM headroom and better KV quality.
CONTEXT="${LLM_CONTEXT:-256k}"
KV="${LLM_KV:-k8v4}"
case "$KV" in
    int8|q4_0|k8v4|fp16) ;;
    *) die "LLM_KV must be int8, q4_0, k8v4 or fp16." ;;
esac
UNIT="llm-server-${HARDWARE}-${ENGINE}.service"
PROJECT="$(printf '%s' "llm-server-${HARDWARE}-${ENGINE}" | tr '[:upper:]_' '[:lower:]-')"
CONTAINER="${PROJECT}-model"
VOLUME="${PROJECT}-strata-data"
SERVICE_DIR="$SERVICE_CONFIG/$UNIT"

models=(IQ3_S IQ3_XXS IQ2_XS Q2_0 IQ1_M)
families=(qwen qwen qwen qwen coder)
# Strata downloads the GGUF shards, writes a prepared pack, and fetches the
# draft layer. These are observed/estimated free-space needs, with headroom.
disk_gb=(140 130 120 118 105)
labels=(
    "IQ3_S - Qwen3.8-Flash-Next, best quality (~55 GB model memory, ~140 GB disk)"
    "IQ3_XXS - Qwen3.8-Flash-Next, great quality (~47 GB model memory, ~130 GB disk)"
    "IQ2_XS - Qwen3.8-Flash-Next, better than Q2_0 (~39 GB model memory, ~120 GB disk)"
    "Q2_0 - Qwen3.8-Flash-Next, fastest (~38 GB model memory, ~118 GB disk)"
    "Coder - Qwen3.8-Flash-Next Coder IQ1_M (~32 GB model memory, ~105 GB disk)"
)

selected=-1
if [[ -n "${LLM_MODEL:-}" ]]; then
    wanted="$(tr '[:lower:]' '[:upper:]' <<<"$LLM_MODEL")"
    [[ "$wanted" == "CODER" ]] && wanted=IQ1_M
    for i in "${!models[@]}"; do
        if [[ "${models[$i]}" == "$wanted" ]]; then selected=$i; break; fi
    done
    ((selected >= 0)) || die "Unknown Strata model '$LLM_MODEL'. Choices: ${models[*]}."
else
    selected="$(select_index "Choose a Strata model:" 1 "${labels[@]}")"
fi
MODEL_SIZE="${models[$selected]}"
MODEL_FAMILY="${families[$selected]}"
NEED_GB="${disk_gb[$selected]}"

# up.sh asks about OpenWebUI after this, so it needs the choice without an install.
if ((SELECT_ONLY)); then
    printf 'LLM_MODEL=%q\n' "$MODEL_SIZE"
    exit 0
fi

driver="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 | tr -d '[:space:]')"
[[ -n "$driver" ]] || die "Could not read the NVIDIA driver version."
driver_major="${driver%%.*}"
[[ "$driver_major" =~ ^[0-9]+$ ]] || die "Unrecognized NVIDIA driver version: $driver"
if ((driver_major >= 580)); then
    IMAGE="ghcr.io/niko1221/strata:0.2.9-cuda13"
elif ((driver_major >= 575)); then
    IMAGE="ghcr.io/niko1221/strata:0.2.9-cuda12"
else
    die "NVIDIA driver $driver is too old for Strata. Driver 575 or newer is required."
fi

ram_gb="$(awk '/MemTotal/ { printf "%d", $2 / 1048576 }' /proc/meminfo)"
free_gb="$(df -Pk "$HOME" | awk 'NR == 2 { printf "%d", $4 / 1048576 }')"

# The large download only happens once. A volume that already holds a GGUF in
# Strata's layout must not need the free space for another download.
MODEL_INSTALLED=0
volume_path="$(docker volume inspect -f '{{.Mountpoint}}' "$VOLUME" 2>/dev/null || true)"
if [[ -n "$volume_path" ]] && \
   find "$volume_path/Strata-data/models" -maxdepth 4 -name '*.gguf' -print -quit 2>/dev/null | grep -q .; then
    MODEL_INSTALLED=1
fi

if ((DRY_RUN)); then
    cat <<EOF
Hardware:    $HARDWARE
Engine:      $ENGINE
Model:       $MODEL_FAMILY / $MODEL_SIZE
Context:     $CONTEXT ($KV KV, text only)
Image:       $IMAGE
Service:     $UNIT
Container:   $CONTAINER
API:         http://$BIND_ADDR:$HOST_PORT/v1
Data volume: $VOLUME
Config:      $SERVICE_DIR
RAM:         ${ram_gb} GB
Free disk:   ${free_gb} GB$(
    if ((MODEL_INSTALLED)); then
        printf ' (model already downloaded)'
    else
        printf ' (want at least %s GB for the download)' "$NEED_GB"
    fi
)
EOF
    exit 0
fi

ensure_api_key
API_KEY="$(cat "$API_KEY_FILE")"

TEMPLATE_VERSION=3
CONFIG_SIG="$(config_signature "$TEMPLATE_VERSION" "$IMAGE" "$MODEL_FAMILY" "$MODEL_SIZE" \
    "$CONTEXT" "$KV" "$BIND_ADDR" "$HOST_PORT" "$GPU_IDS" "$API_KEY")"
HEALTH_URL="http://127.0.0.1:${HOST_PORT}/health"

print_summary() {
    cat <<EOF

Strata service: $UNIT
Model:       $MODEL_FAMILY / $MODEL_SIZE
Context:     $CONTEXT ($KV KV, text only)
API:         http://$BIND_ADDR:$HOST_PORT/v1
Logs:        journalctl --user -u $UNIT -f
Container:   docker logs -f $CONTAINER
EOF
    if ((FIRST_INSTALL)); then
        printf 'First start: the model download/preparation can take hours; watch the container log.\n'
    fi
}

# Reloading Strata page-locks tens of GB of experts, which takes minutes at
# 256K. If nothing changed, leave the running service alone.
if [[ "${LLM_FORCE_REINSTALL:-0}" != "1" ]] && \
   [[ "$(stored_config_signature "$SERVICE_DIR/.env")" == "$CONFIG_SIG" ]] && \
   systemctl --user is-active --quiet "$UNIT"; then
    FIRST_INSTALL=0
    if http_matches "$HEALTH_URL" '"loaded":[[:space:]]*true'; then
        log "Already running with the requested configuration; nothing to do."
    else
        log "Already running with the requested configuration; the model is still starting."
    fi
    enable_unit "$UNIT" 2>/dev/null || true
    activate_generic_unit "$UNIT"
    write_service_state "$UNIT" model "$SERVICE_DIR" "$PROJECT" "$CONTAINER" "$HOST_PORT"
    print_summary
    exit 0
fi

if ((selected == 0 && ram_gb < 60)); then
    warn "Strata estimates about 54.8 GB for IQ3_S plus about 10 GB for the system."
    warn "This host has ${ram_gb} GB RAM. IQ3_S may use low-RAM/SSD mode, which is much slower."
fi
if ((MODEL_INSTALLED == 0 && free_gb < NEED_GB)); then
    die "Not enough free disk for the $MODEL_SIZE download: ${free_gb} GB free, ${NEED_GB} GB required."
fi

ensure_core_packages
verify_nvidia_gpu
ensure_nvidia_toolkit
ensure_nvidia_runtime

# Release the port from any previous model service, including this one.
stop_model_services_except "$UNIT"
if [[ -f "$SERVICE_STATE/$UNIT.env" ]]; then
    stop_service_from_state "$SERVICE_STATE/$UNIT.env"
else
    systemctl --user stop "$UNIT" 2>/dev/null || true
    systemctl --user disable "$UNIT" 2>/dev/null || true
fi
port_available "$HOST_PORT" || die "Port $HOST_PORT is already in use. Stop the conflicting service first."

ensure_docker_network
docker pull "$IMAGE"
log "Testing GPU access through rootless Docker."
gpu_smoke_test "$IMAGE" "$GPU_IDS" || die "GPU smoke test failed. Run ./up.sh to repair rootless NVIDIA configuration."

FIRST_INSTALL=$((1 - MODEL_INSTALLED))

log "Checking the model plan with Strata (nothing is downloaded by --plan)."
if ! docker run --rm --runtime=nvidia \
    -e NVIDIA_VISIBLE_DEVICES="$GPU_IDS" \
    -e NVIDIA_DRIVER_CAPABILITIES=compute,utility \
    -v "$VOLUME:/data" \
    "$IMAGE" strata launch --plan --family "$MODEL_FAMILY" --model "$MODEL_SIZE" \
    --context "$CONTEXT" --vision off --tune skip --kv "$KV"; then
    warn "Strata's plan reports that $MODEL_SIZE does not fit this host comfortably."
    warn "Continuing as requested; Strata may use its low-RAM/SSD mode, which is much slower."
fi

mkdir -p "$SERVICE_DIR"
chmod 700 "$LLM_CONFIG" "$SERVICE_CONFIG" "$SERVICE_DIR"

cat > "$SERVICE_DIR/.env" <<EOF
CONFIG_SIG=$CONFIG_SIG
IMAGE=$IMAGE
MODEL_FAMILY=$MODEL_FAMILY
MODEL_SIZE=$MODEL_SIZE
CONTEXT=$CONTEXT
KV=$KV
HOST_PORT=$HOST_PORT
BIND_ADDR=$BIND_ADDR
GPU_IDS=$GPU_IDS
PROJECT=$PROJECT
CONTAINER=$CONTAINER
API_KEY=$API_KEY
EOF
chmod 600 "$SERVICE_DIR/.env"

cat > "$SERVICE_DIR/compose.yml" <<'EOF'
services:
  model:
    image: ${IMAGE}
    container_name: ${CONTAINER}
    restart: unless-stopped
    runtime: nvidia
    environment:
      NVIDIA_VISIBLE_DEVICES: ${GPU_IDS}
      NVIDIA_DRIVER_CAPABILITIES: compute,utility
      FAMILY: ${MODEL_FAMILY}
      MODEL: ${MODEL_SIZE}
      CONTEXT: ${CONTEXT}
      KV: ${KV}
      PARALLEL: "1"
      VISION: "off"
      TUNE: "skip"
      API_KEY: ${API_KEY}
      GPU: ${GPU_IDS}
    ports:
      - "${BIND_ADDR}:${HOST_PORT}:8080"
    volumes:
      - strata-data:/data
    networks:
      llm-net:
        aliases:
          - llm-model
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    read_only: true
    tmpfs:
      - /tmp:rw,noexec,nosuid,nodev,size=2g
      - /run:rw,noexec,nosuid,nodev,size=64m
    ipc: private
    shm_size: 2gb
    pids_limit: 4096
    stop_grace_period: 2m
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

volumes:
  strata-data:
    name: ${PROJECT}-strata-data

networks:
  llm-net:
    external: true
EOF

chmod 644 "$SERVICE_DIR/compose.yml"

validate_compose "$SERVICE_DIR" "$PROJECT" || die "Generated Compose file is invalid."
install_compose_unit \
    "$UNIT" \
    "Strata $MODEL_SIZE for $HARDWARE (rootless)" \
    "$SERVICE_DIR" "$PROJECT" 1800 180

if ! start_unit "$UNIT"; then
    rollback_compose_service "$UNIT" "$SERVICE_DIR" "$PROJECT" "$CONTAINER"
    die "Failed to start $UNIT."
fi

if ! wait_container_running "$CONTAINER" 120; then
    rollback_compose_service "$UNIT" "$SERVICE_DIR" "$PROJECT" "$CONTAINER"
    die "Strata container did not stay running."
fi

health_url="http://127.0.0.1:${HOST_PORT}/health"
if ((FIRST_INSTALL)); then
    if wait_http_running "$health_url" 120 "$CONTAINER" "Strata first start" '"loaded":[[:space:]]*true'; then
        :
    else
        rc=$?
        if ((rc == 2 || rc == 3)); then
            rollback_compose_service "$UNIT" "$SERVICE_DIR" "$PROJECT" "$CONTAINER"
            if ((rc == 2)); then
                die "Strata exited during its first start."
            fi
            die "Strata restarted during its first start. Check the container log for the reason."
        fi
        warn "Strata is still downloading/preparing the model; the API will appear when that finishes."
    fi
else
    if wait_http_running "$health_url" "${LLM_HEALTH_TIMEOUT:-1800}" "$CONTAINER" "Strata" '"loaded":[[:space:]]*true'; then
        :
    else
        rc=$?
        rollback_compose_service "$UNIT" "$SERVICE_DIR" "$PROJECT" "$CONTAINER"
        if ((rc == 2)); then
            die "Strata container exited before becoming healthy."
        fi
        if ((rc == 3)); then
            die "Strata restarted before becoming healthy. Check the container log for the reason."
        fi
        die "Strata did not become healthy."
    fi
fi

enable_unit "$UNIT"
activate_generic_unit "$UNIT"
write_service_state "$UNIT" model "$SERVICE_DIR" "$PROJECT" "$CONTAINER" "$HOST_PORT"

print_summary
