#!/usr/bin/env bash
# Detect the GPU, choose a hardware/engine setup, and install its user service.

set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$REPO_ROOT/lib/common.sh"

LIST_ONLY=0
DRY_RUN=0
WEBUI_MODE="${LLM_WITH_WEBUI:-auto}"

usage() {
    cat <<'EOF'
Usage: ./up.sh [--list] [--dry-run] [--with-webui|--no-webui]

  --list        Show GPUs and matching setup directories; do not install.
  --dry-run     Select hardware/engine/model and print the plan; do not install.
  --with-webui  Install or refresh OpenWebUI after the model service.
  --no-webui    Do not offer to install OpenWebUI.

Environment overrides: LLM_HARDWARE, LLM_ENGINE, LLM_GPU_IDS, LLM_MODEL,
LLM_PORT, LLM_BIND_ADDR, LLM_WITH_WEBUI, LLM_WEBUI_PORT.
EOF
}

while (($#)); do
    case "$1" in
        --list) LIST_ONLY=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --with-webui) WEBUI_MODE=yes ;;
        --no-webui) WEBUI_MODE=no ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
    shift
done

case "$WEBUI_MODE" in
    auto|yes|no) ;;
    *) die "LLM_WITH_WEBUI must be auto, yes or no." ;;
esac

require_docker_cli

if ! have nvidia-smi; then
    die "nvidia-smi not found. An NVIDIA driver is required by the available setups."
fi

mapfile -t gpu_lines < <(nvidia-smi --query-gpu=index,name,memory.total,driver_version \
    --format=csv,noheader,nounits 2>/dev/null)
((${#gpu_lines[@]} > 0)) || die "No NVIDIA GPUs detected."

trim() {
    sed 's/^[[:space:]]*//; s/[[:space:]]*$//' <<<"$1"
}

shopt -s nullglob
hardware_confs=("$REPO_ROOT"/setup/*/hardware.conf)
((${#hardware_confs[@]} > 0)) || die "No setup/*/hardware.conf files found."

declare -a cand_label=() cand_hw=() cand_gpu=() cand_name=() cand_vram=() cand_driver=()
for conf in "${hardware_confs[@]}"; do
    HARDWARE_NAME=""
    GPU_PATTERN=""
    MIN_VRAM_MB=0
    # shellcheck disable=SC1090
    source "$conf"
    [[ -n "$GPU_PATTERN" ]] || continue

    hw_dir="$(dirname "$conf")"
    hw_name="$(basename "$hw_dir")"
    if [[ -n "${LLM_HARDWARE:-}" && "$LLM_HARDWARE" != "$hw_name" ]]; then
        continue
    fi

    for line in "${gpu_lines[@]}"; do
        IFS=',' read -r gpu_idx gpu_name gpu_mem gpu_driver <<<"$line"
        gpu_idx="$(trim "$gpu_idx")"
        gpu_name="$(trim "$gpu_name")"
        gpu_mem="$(trim "$gpu_mem")"
        gpu_driver="$(trim "$gpu_driver")"

        if [[ -n "${LLM_GPU_IDS:-}" ]]; then
            gpu_ids_compact="${LLM_GPU_IDS// /}"
            [[ ",$gpu_ids_compact," == *",$gpu_idx,"* ]] || continue
        fi
        grep -Eiq -- "$GPU_PATTERN" <<<"$gpu_name" || continue
        ((gpu_mem >= MIN_VRAM_MB)) || continue

        cand_label+=("$hw_name: $HARDWARE_NAME (GPU $gpu_idx, $gpu_name, ${gpu_mem} MiB)")
        cand_hw+=("$hw_name")
        cand_gpu+=("$gpu_idx")
        cand_name+=("$gpu_name")
        cand_vram+=("$gpu_mem")
        cand_driver+=("$gpu_driver")
    done
done

if ((${#cand_label[@]} == 0)); then
    printf 'Detected GPUs:\n' >&2
    printf '  %s\n' "${gpu_lines[@]}" >&2
    die "No setup matched. Add setup/<hardware>/hardware.conf with a matching GPU_PATTERN."
fi

if ((LIST_ONLY)); then
    printf 'Detected GPUs:\n'
    printf '  %s\n' "${gpu_lines[@]}"
    printf '\nMatching setups:\n'
    for i in "${!cand_label[@]}"; do
        printf '  %d) %s\n' "$((i + 1))" "${cand_label[$i]}"
    done
    exit 0
fi

if ((${#cand_label[@]} == 1)); then
    chosen=0
    log "Detected ${cand_label[0]}"
else
    chosen="$(select_index "Multiple hardware combinations match this machine:" 1 "${cand_label[@]}")"
fi

LLM_HARDWARE="${cand_hw[$chosen]}"
LLM_GPU_IDS="${cand_gpu[$chosen]}"
LLM_GPU_NAME="${cand_name[$chosen]}"
hw_dir="$REPO_ROOT/setup/$LLM_HARDWARE"

mapfile -t engines < <(find "$hw_dir" -mindepth 1 -maxdepth 1 -type d \
    -exec test -x '{}/run.sh' ';' -printf '%f\n' 2>/dev/null | sort)
((${#engines[@]} > 0)) || die "No runnable engines in $hw_dir."

if [[ -n "${LLM_ENGINE:-}" ]]; then
    [[ " ${engines[*]} " == *" $LLM_ENGINE "* ]] || \
        die "LLM_ENGINE=$LLM_ENGINE is not available for $LLM_HARDWARE (choices: ${engines[*]})."
else
    if ((${#engines[@]} == 1)); then
        LLM_ENGINE="${engines[0]}"
    else
        engine_idx="$(select_index "Choose an inference engine for $LLM_HARDWARE:" 1 "${engines[@]}")"
        LLM_ENGINE="${engines[$engine_idx]}"
    fi
fi

export LLM_HARDWARE LLM_ENGINE LLM_GPU_IDS LLM_GPU_NAME
run_script="$hw_dir/$LLM_ENGINE/run.sh"

if ((DRY_RUN)); then
    log "Dry run: $LLM_HARDWARE / $LLM_ENGINE / GPU $LLM_GPU_IDS"
    "$run_script" --dry-run
    exit 0
fi

# Pick the model before installing so the OpenWebUI question can come right
# after the model selection, before the long Strata load.
selection="$("$run_script" --select-only)" || die "Model selection failed."
eval "$selection"
[[ -n "${LLM_MODEL:-}" ]] || die "Model selection did not choose a model."
export LLM_MODEL
if [[ -n "${LLM_MODEL_PATH:-}" ]]; then
    export LLM_MODEL_PATH
fi

ui_state="$SERVICE_STATE/llm-server-openwebui.service.env"
ui_action=none
case "$WEBUI_MODE" in
    yes) ui_action=install ;;
    no) ;;
    auto)
        if [[ -t 0 ]]; then
            if [[ -f "$ui_state" ]]; then
                if systemctl --user is-active --quiet llm-server-openwebui.service; then
                    if confirm "OpenWebUI is running and uses about 1 GB of RAM. Keep it running?" no; then
                        ui_action=keep
                    else
                        ui_action=stop
                    fi
                elif confirm "Start OpenWebUI (separate service, about 1 GB of RAM)?" no; then
                    ui_action=start
                fi
            elif confirm "Install OpenWebUI (separate service, about 1 GB of RAM)?" no; then
                ui_action=install
            fi
        fi
        ;;
esac

# Free the memory before the model loads when the answer is no.
if [[ "$ui_action" == "stop" ]]; then
    if systemctl --user stop llm-server-openwebui.service; then
        log "OpenWebUI stopped to free memory."
    else
        warn "Could not stop OpenWebUI."
    fi
fi

ensure_rootless_docker
ensure_docker_network
ensure_user_systemd
ensure_linger

new_unit="llm-server-${LLM_HARDWARE}-${LLM_ENGINE}.service"

log "Setting up $LLM_HARDWARE / $LLM_ENGINE."
"$run_script"

state_file="$SERVICE_STATE/$new_unit.env"
[[ -f "$state_file" ]] || die "Installer did not record service state: $state_file"
# shellcheck disable=SC1090
source "$state_file"
systemctl --user is-active --quiet "$UNIT" || die "Installed service is not active: $UNIT"
[[ -L "$UNIT_DIR/$GENERIC_UNIT" ]] || die "Generic service alias was not created."

case "$ui_action" in
    install)
        "$REPO_ROOT/setup/common/openwebui/run.sh"
        ;;
    start)
        systemctl --user enable llm-server-openwebui.service >/dev/null 2>&1 || true
        if ! systemctl --user start llm-server-openwebui.service; then
            warn "OpenWebUI did not start; rerun setup/common/openwebui/run.sh."
        fi
        ;;
    keep)
        systemctl --user enable llm-server-openwebui.service >/dev/null 2>&1 || true
        ;;
esac

ui_installed=0
if systemctl --user is-active --quiet llm-server-openwebui.service; then
    ui_installed=1
fi

lan_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
lan_ip="${lan_ip:-localhost}"
bind_addr="${LLM_BIND_ADDR:-0.0.0.0}"
if [[ "$bind_addr" == "0.0.0.0" ]]; then
    display_host="$lan_ip"
else
    display_host="$bind_addr"
fi
api_port="${HOST_PORT:-8080}"
container="${CONTAINER:-unknown}"

cat <<EOF

Model service: $UNIT
Generic alias: systemctl --user status llm-server
API:           http://$display_host:$api_port/v1
API key:       $API_KEY_FILE
Logs:          journalctl --user -u llm-server -f
Container log: docker logs -f $container
Stop:          ./down.sh
EOF
if ((ui_installed)); then
    ui_port="$(sed -n 's/^HOST_PORT=//p' "$ui_state" 2>/dev/null | head -1)"
    printf 'OpenWebUI:     http://%s:%s\n' "$display_host" "${ui_port:-3000}"
fi
