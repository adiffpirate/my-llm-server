#!/usr/bin/env bash
# llama.cpp installer for an RTX 4050 (6 GB).

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

HARDWARE="${LLM_HARDWARE:-$(basename "$(dirname "$SCRIPT_DIR")")}"
ENGINE="$(basename "$SCRIPT_DIR")"
GPU_IDS="${LLM_GPU_IDS:-all}"
HOST_PORT="${LLM_PORT:-8080}"
BIND_ADDR="${LLM_BIND_ADDR:-0.0.0.0}"
CONTEXT="${LLM_CONTEXT:-32768}"
THREADS="${LLM_THREADS:-$(nproc)}"
MODEL_ALIAS="${LLM_ALIAS:-llm}"
UNIT="llm-server-${HARDWARE}-${ENGINE}.service"
PROJECT="$(printf '%s' "llm-server-${HARDWARE}-${ENGINE}" | tr '[:upper:]_' '[:lower:]-')"
CONTAINER="${PROJECT}-model"
IMAGE="ghcr.io/ggml-org/llama.cpp:server-cuda-b5343"
SERVICE_DIR="$SERVICE_CONFIG/$UNIT"
MODEL_ROOT="$REPO_ROOT/models"

names=(gemma qwen35_q4 qwen35_q2 custom)
labels=(
    "Gemma 4 26B A4B QAT UD-Q4_K_XL (13.3 GiB, existing default)"
    "Qwen 3.6 35B A3B UD-Q4_K_XL (20 GiB, best quality)"
    "Qwen 3.6 35B A3B UD-Q2_K_XL (11.4 GiB, smaller/faster)"
    "Custom local GGUF file"
)
repos=(
    "unsloth/gemma-4-26B-A4B-it-qat-GGUF"
    "unsloth/Qwen3.6-35B-A3B-GGUF"
    "unsloth/Qwen3.6-35B-A3B-GGUF"
    ""
)
files=(
    "gemma-4-26B-A4B-it-qat-UD-Q4_K_XL.gguf"
    "Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf"
    "Qwen3.6-35B-A3B-UD-Q2_K_XL.gguf"
    ""
)
sizes=(14 21 12 0)
ncpu_moe=(28 28 26 "")

selected=-1
if [[ -n "${LLM_MODEL:-}" ]]; then
    wanted="$(tr '[:upper:]' '[:lower:]' <<<"$LLM_MODEL")"
    for i in "${!names[@]}"; do
        if [[ "${names[$i]}" == "$wanted" ]]; then selected=$i; break; fi
    done
    ((selected >= 0)) || die "Unknown llama.cpp model '$LLM_MODEL'. Choices: ${names[*]}."
else
    selected="$(select_index "Choose a llama.cpp model:" 1 "${labels[@]}")"
fi

MODEL_KIND="${names[$selected]}"
MODEL_SIZE="${sizes[$selected]}"
N_CPU_MOE="${ncpu_moe[$selected]}"
MMPROJ_MOUNT=""
MMPROJ_FLAG=""

if [[ "$MODEL_KIND" == "custom" ]]; then
    custom_path="${LLM_MODEL_PATH:-}"
    [[ -n "$custom_path" ]] || custom_path="$(ask "Path to the .gguf file:" "")"
    [[ -n "$custom_path" ]] || die "No GGUF path supplied."
    [[ -f "$custom_path" ]] || die "Not a file: $custom_path"
    custom_path="$(realpath "$custom_path")"
    [[ "$custom_path" != *:* ]] || die "Model paths containing ':' are not supported."
    [[ "$(head -c 4 "$custom_path")" == "GGUF" ]] || die "Not a GGUF file: $custom_path"
    MODEL_SIZE=$(( ($(stat -c %s "$custom_path") + 1073741823) / 1073741824 ))
    MODEL_MOUNT="$custom_path:/models/model.gguf:ro"
    CONTAINER_MODEL="/models/model.gguf"
    MODEL_NAME="custom"
    N_CPU_MOE="${LLM_N_CPU_MOE:-}"
    if [[ -n "${LLM_MMPROJ:-}" ]]; then
        [[ -f "$LLM_MMPROJ" ]] || die "mmproj file not found: $LLM_MMPROJ"
        MMPROJ_MOUNT="$(realpath "$LLM_MMPROJ"):/models/mmproj.gguf:ro"
        MMPROJ_FLAG="/models/mmproj.gguf"
    fi
else
    REPO="${repos[$selected]}"
    MODEL_FILE="${files[$selected]}"
    MODEL_NAME="${MODEL_KIND}"
    MODEL_MOUNT="$MODEL_ROOT:/models:ro"
    CONTAINER_MODEL="/models/$MODEL_FILE"
fi

if ((DRY_RUN)); then
    cat <<EOF
Hardware:  $HARDWARE
Engine:    $ENGINE
Model:     $MODEL_NAME
Image:     $IMAGE
Service:   $UNIT
Container: $CONTAINER
API:       http://$BIND_ADDR:$HOST_PORT/v1
Model dir: $MODEL_ROOT
Config:    $SERVICE_DIR
EOF
    exit 0
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
mkdir -p "$MODEL_ROOT"
docker pull "$IMAGE"
log "Testing GPU access through rootless Docker."
gpu_smoke_test "$IMAGE" "$GPU_IDS" || die "GPU smoke test failed. Run ./up.sh to repair rootless NVIDIA configuration."

download_hf() {
    local repo="$1" file="$2" dest="$3"
    local url="https://huggingface.co/$repo/resolve/main/$file"
    local remote_size local_size
    local -a args
    mkdir -p "$(dirname "$dest")"
    remote_size="$(curl -fsIL --retry 3 --retry-all-errors "$url" 2>/dev/null |
        tr -d '\r' | awk 'tolower($1) == "content-length:" { size = $2 } END { print size }')"
    if [[ -s "$dest" ]]; then
        [[ "$(head -c 4 "$dest")" == "GGUF" ]] || die "Existing file is not a valid GGUF: $dest"
        if [[ -n "$remote_size" ]]; then
            local_size="$(stat -c %s "$dest")"
            [[ "$local_size" == "$remote_size" ]] || \
                die "Existing file is incomplete ($local_size of $remote_size bytes). Remove it and retry: $dest"
        fi
        return 0
    fi
    log "Downloading $file"
    args=(-fL --retry 5 --retry-delay 3 --retry-all-errors -o "$dest.part")
    [[ -s "$dest.part" ]] && args+=(-C -)
    curl "${args[@]}" "$url"
    [[ "$(head -c 4 "$dest.part")" == "GGUF" ]] || die "Downloaded file is not a valid GGUF: $dest.part"
    if [[ -n "$remote_size" ]]; then
        local_size="$(stat -c %s "$dest.part")"
        [[ "$local_size" == "$remote_size" ]] || die "Download is incomplete ($local_size of $remote_size bytes): $dest.part"
    fi
    mv "$dest.part" "$dest"
}

if [[ "$MODEL_KIND" != "custom" ]]; then
    model_path="$MODEL_ROOT/$MODEL_FILE"
    if [[ ! -s "$model_path" ]]; then
        free_gb="$(df -Pk "$MODEL_ROOT" 2>/dev/null | awk 'NR == 2 { printf "%d", $4 / 1048576 }')"
        free_gb="${free_gb:-0}"
        ((free_gb >= MODEL_SIZE + 2)) || \
            die "Not enough free disk: ${free_gb} GB free, $((MODEL_SIZE + 2)) GB required."
    fi
    download_hf "$REPO" "$MODEL_FILE" "$model_path"
    [[ "$(head -c 4 "$model_path")" == "GGUF" ]] || die "Not a GGUF file: $model_path"

    if [[ "${LLM_VISION:-0}" == "1" ]]; then
        download_hf "$REPO" "mmproj-BF16.gguf" "$MODEL_ROOT/mmproj-BF16.gguf"
        MMPROJ_FLAG="/models/mmproj-BF16.gguf"
    fi
fi

# For custom files MMPROJ_FLAG is a source path; translate it to the mounted path.
if [[ -n "$MMPROJ_FLAG" && "$MMPROJ_FLAG" != "/models/"* ]]; then
    MMPROJ_FLAG="/models/mmproj.gguf"
fi

ensure_api_key
API_KEY="$(cat "$API_KEY_FILE")"
mkdir -p "$SERVICE_DIR"
chmod 700 "$LLM_CONFIG" "$SERVICE_CONFIG" "$SERVICE_DIR"

cat > "$SERVICE_DIR/.env" <<EOF
IMAGE=$IMAGE
HOST_PORT=$HOST_PORT
BIND_ADDR=$BIND_ADDR
GPU_IDS=$GPU_IDS
PROJECT=$PROJECT
CONTAINER=$CONTAINER
MODEL_MOUNT=$MODEL_MOUNT
API_KEY=$API_KEY
EOF
if [[ -n "$MMPROJ_MOUNT" ]]; then
    printf 'MMPROJ_MOUNT=%s\n' "$MMPROJ_MOUNT" >> "$SERVICE_DIR/.env"
fi
chmod 600 "$SERVICE_DIR/.env"

{
cat <<'EOF'
services:
  model:
    image: ${IMAGE}
    container_name: ${CONTAINER}
    restart: unless-stopped
    runtime: nvidia
    init: true
    environment:
      NVIDIA_VISIBLE_DEVICES: ${GPU_IDS}
      NVIDIA_DRIVER_CAPABILITIES: compute,utility
      HOME: /tmp
    ports:
      - "${BIND_ADDR}:${HOST_PORT}:8080"
    volumes:
      - ${MODEL_MOUNT}
EOF
if [[ -n "$MMPROJ_MOUNT" ]]; then
    printf '      - ${MMPROJ_MOUNT}\n'
fi
cat <<EOF
    networks:
      llm-net:
        aliases:
          - llm-model
    command:
      - --model
      - ${CONTAINER_MODEL}
      - --alias
      - ${MODEL_ALIAS}
      - --host
      - 0.0.0.0
      - --port
      - "8080"
      - --no-webui
      - --api-key
      - \${API_KEY}
      - --parallel
      - "1"
      - --ctx-size
      - "${CONTEXT}"
      - --threads
      - "${THREADS}"
      - --n-gpu-layers
      - "999"
EOF
if [[ -n "$N_CPU_MOE" ]]; then
    printf '      - --n-cpu-moe\n      - "%s"\n' "$N_CPU_MOE"
fi
if [[ -n "$MMPROJ_FLAG" ]]; then
    printf '      - --mmproj\n      - %s\n' "$MMPROJ_FLAG"
fi
cat <<'EOF'
      - --batch-size
      - "4096"
      - --ubatch-size
      - "1024"
      - --cache-type-k
      - q8_0
      - --cache-type-v
      - q8_0
      - --jinja
      - --no-mmap
      - --temp
      - "1.0"
      - --top-p
      - "0.95"
      - --top-k
      - "64"
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    read_only: true
    tmpfs:
      - /tmp:rw,noexec,nosuid,nodev,size=512m
      - /run:rw,noexec,nosuid,nodev,size=32m
    ipc: private
    shm_size: 512mb
    pids_limit: 2048
    stop_grace_period: 30s
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

networks:
  llm-net:
    external: true
EOF
} > "$SERVICE_DIR/compose.yml"

chmod 644 "$SERVICE_DIR/compose.yml"

validate_compose "$SERVICE_DIR" "$PROJECT" || die "Generated Compose file is invalid."
install_compose_unit \
    "$UNIT" \
    "llama.cpp $MODEL_NAME for $HARDWARE (rootless)" \
    "$SERVICE_DIR" "$PROJECT" 1800 60

if ! start_unit "$UNIT"; then
    rollback_compose_service "$UNIT" "$SERVICE_DIR" "$PROJECT" "$CONTAINER"
    die "Failed to start $UNIT."
fi

if wait_http_running "http://127.0.0.1:${HOST_PORT}/health" "${LLM_HEALTH_TIMEOUT:-1800}" "$CONTAINER" "llama.cpp"; then
    :
else
    rc=$?
    rollback_compose_service "$UNIT" "$SERVICE_DIR" "$PROJECT" "$CONTAINER"
    if ((rc == 2)); then
        die "llama.cpp container exited before becoming healthy."
    fi
    die "llama.cpp did not become healthy."
fi

enable_unit "$UNIT"
activate_generic_unit "$UNIT"
write_service_state "$UNIT" model "$SERVICE_DIR" "$PROJECT" "$CONTAINER" "$HOST_PORT"

cat <<EOF

llama.cpp service installed: $UNIT
Model:     $MODEL_NAME
API:       http://$BIND_ADDR:$HOST_PORT/v1
Logs:      journalctl --user -u $UNIT -f
Container: docker logs -f $CONTAINER
EOF
