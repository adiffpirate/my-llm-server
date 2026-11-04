#!/usr/bin/env bash
# Stop and disable LLM user services. Containers are removed; models and volumes are kept.

set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$REPO_ROOT/lib/common.sh"

setup_user_env

usage() {
    cat <<'EOF'
Usage: ./down.sh [--model|--webui|--all]

  --model   Stop only the LLM model service(s).
  --webui   Stop only OpenWebUI.
  --all     Stop both (default when there is no terminal to ask).

Without a flag on a terminal, asks which of the two to stop.
Environment override: LLM_DOWN_TARGET=model|webui|all.
EOF
}

TARGET="${LLM_DOWN_TARGET:-}"
while (($#)); do
    case "$1" in
        --model) TARGET=model ;;
        --webui) TARGET=webui ;;
        --all) TARGET=all ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
    shift
done

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

case "$TARGET" in
    model)
        cat <<'EOF'

Stopped and disabled the LLM model service(s).
OpenWebUI, model files, Docker volumes, API key and service configuration were kept.
EOF
        ;;
    webui)
        cat <<'EOF'

Stopped and disabled OpenWebUI.
The LLM model service, its data and configuration were kept.
EOF
        ;;
    all)
        cat <<'EOF'

Stopped and disabled all LLM services.
Kept on disk: model files, Docker volumes, API key, service configuration.
The generic llm-server.service alias remains, pointing at the last model service.
EOF
        ;;
esac
