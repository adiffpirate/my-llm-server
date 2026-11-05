#!/usr/bin/env bash
# Stop and disable LLM user services. Containers are removed.
# Data is kept unless --delete-data is given.

set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$REPO_ROOT/lib/common.sh"

setup_user_env

usage() {
    cat <<'EOF'
Usage: ./down.sh [--model|--webui|--all] [--delete-data] [--yes]

  --model         Stop only the LLM model service(s).
  --webui         Stop only OpenWebUI.
  --all           Stop both (default when there is no terminal to ask).
  --delete-data   Also delete the Docker volumes that hold the selected
                  service's data (model files or OpenWebUI accounts/chats).
  --yes           Do not ask before deleting data. Required without a terminal.

Without a target on a terminal, asks which of the two to stop.
The llama.cpp `models/` directory is a host bind mount and is never deleted.
Environment overrides: LLM_DOWN_TARGET=model|webui|all, LLM_DELETE_DATA=1.
EOF
}

TARGET="${LLM_DOWN_TARGET:-}"
DELETE_DATA="${LLM_DELETE_DATA:-0}"
ASSUME_YES=0
while (($#)); do
    case "$1" in
        --model) TARGET=model ;;
        --webui) TARGET=webui ;;
        --all) TARGET=all ;;
        --delete-data) DELETE_DATA=1 ;;
        -y|--yes) ASSUME_YES=1 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
    shift
done

case "$DELETE_DATA" in
    0|1) ;;
    *) die "LLM_DELETE_DATA must be 0 or 1." ;;
esac

case "$TARGET" in
    model|webui|all) ;;
    "")
        if [[ -t 0 ]]; then
            choice="$(select_index "What do you want to stop?" 3 \
                "LLM model service(s) only" \
                "OpenWebUI only" \
                "Both")"
            case "$choice" in
                0) TARGET=model ;;
                1) TARGET=webui ;;
                2) TARGET=all ;;
            esac
        else
            TARGET=all
        fi
        ;;
    *) die "LLM_DOWN_TARGET must be model, webui or all." ;;
esac

service_kind() {
    sed -n 's/^KIND=//p' "$1" 2>/dev/null | head -n1 | tr -d "'\""
}

stop_kind() {
    local kind="$1" state
    shopt -s nullglob
    for state in "$SERVICE_STATE"/*.env; do
        [[ "$(service_kind "$state")" == "$kind" ]] || continue
        stop_service_from_state "$state"
    done
}

# UI-first order keeps the browser from calling a model that is going away.
case "$TARGET" in
    webui) stop_kind ui ;;
    model) stop_kind model ;;
    all) stop_kind ui; stop_kind model ;;
esac

# Catch units that exist without a state file (for example after a failed install).
if systemctl --user show-environment >/dev/null 2>&1; then
    mapfile -t known_units < <(
        systemctl --user list-unit-files --no-legend --plain 'llm-server-*.service' 2>/dev/null |
            awk '{ print $1 }'
    )
    for unit in "${known_units[@]}"; do
        [[ "$unit" == "$GENERIC_UNIT" ]] && continue
        if [[ "$unit" == "llm-server-openwebui.service" ]]; then
            [[ "$TARGET" == "webui" || "$TARGET" == "all" ]] || continue
        else
            [[ "$TARGET" == "model" || "$TARGET" == "all" ]] || continue
        fi
        systemctl --user stop "$unit" 2>/dev/null || true
        systemctl --user disable "$unit" 2>/dev/null || true
    done
fi

if ! docker_rootless_ready; then
    warn "Rootless Docker is not running; service units were stopped, but containers could not be removed."
fi

delete_volume_list() {
    local label="$1"
    shift
    local volume removed=0
    for volume in "$@"; do
        docker volume inspect "$volume" >/dev/null 2>&1 || continue
        log "Deleting $label data volume: $volume"
        if docker volume rm "$volume" >/dev/null 2>&1; then
            removed=$((removed + 1))
        else
            warn "Could not remove volume $volume (still in use?)."
        fi
    done
    if ((removed == 0)); then
        log "No $label data volumes found."
    fi
}

delete_data() {
    local what model_volumes=()
    case "$TARGET" in
        model) what="the LLM model data (llm-server-*-strata-data)" ;;
        webui) what="OpenWebUI data (accounts and chats)" ;;
        all) what="the LLM model data and OpenWebUI data (accounts and chats)" ;;
    esac
    if ((!ASSUME_YES)); then
        confirm "Delete $what? This cannot be undone." no || die "Nothing was deleted."
    fi

    if [[ "$TARGET" == "model" || "$TARGET" == "all" ]]; then
        mapfile -t model_volumes < <(
            docker volume ls -q 2>/dev/null | grep -E '^llm-server-.*-strata-data$' || true
        )
        delete_volume_list "LLM model" "${model_volumes[@]}"
    fi
    if [[ "$TARGET" == "webui" || "$TARGET" == "all" ]]; then
        delete_volume_list "OpenWebUI" llm-server-openwebui-data llm-server-openwebui-static
    fi
}

if ((DELETE_DATA)); then
    if docker_rootless_ready; then
        delete_data
    else
        die "Rootless Docker is not running; cannot delete data volumes."
    fi
fi

case "$TARGET" in
    model)
        cat <<'EOF'

Stopped and disabled the LLM model service(s).
OpenWebUI, API key and service configuration were kept.
EOF
        if ((DELETE_DATA)); then
            printf 'Deleted the LLM model data volume(s).\n'
        else
            printf 'Model Docker volumes were kept. Use --delete-data to remove them.\n'
        fi
        ;;
    webui)
        cat <<'EOF'

Stopped and disabled OpenWebUI.
The LLM model service, its data and configuration were kept.
EOF
        if ((DELETE_DATA)); then
            printf 'Deleted the OpenWebUI data volume(s).\n'
        else
            printf 'OpenWebUI data volumes were kept. Use --delete-data to remove them.\n'
        fi
        ;;
    all)
        cat <<'EOF'

Stopped and disabled all LLM services.
API key and service configuration were kept.
The generic llm-server.service alias remains, pointing at the last model service.
EOF
        if ((DELETE_DATA)); then
            printf 'Deleted the LLM model data and OpenWebUI data volume(s).\n'
        else
            printf 'Kept on disk: model Docker volumes. Use --delete-data to remove them.\n'
        fi
        ;;
esac
