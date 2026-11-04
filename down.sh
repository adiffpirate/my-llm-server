#!/usr/bin/env bash
# Stop and disable all LLM user services. Containers are removed; models and volumes are kept.

set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$REPO_ROOT/lib/common.sh"

setup_user_env

service_kind() {
    sed -n 's/^KIND=//p' "$1" 2>/dev/null | head -n1 | tr -d "'\""
}

shopt -s nullglob
state_files=("$SERVICE_STATE"/*.env)

# Run two passes, UI first and then model, rather than trusting an
# arbitrary sort order.
for wanted_kind in ui model; do
    for state in "${state_files[@]}"; do
        [[ "$(service_kind "$state")" == "$wanted_kind" ]] || continue
        stop_service_from_state "$state"
    done
done

# Catch units that exist without a state file (for example after a failed install).
if systemctl --user show-environment >/dev/null 2>&1; then
    mapfile -t known_units < <(
        systemctl --user list-unit-files --no-legend --plain 'llm-server-*.service' 2>/dev/null |
            awk '{ print $1 }'
    )
    for unit in "${known_units[@]}"; do
        systemctl --user stop "$unit" 2>/dev/null || true
        systemctl --user disable "$unit" 2>/dev/null || true
    done
fi

if ! docker_rootless_ready; then
    warn "Rootless Docker is not running; service units were stopped, but containers could not be removed."
fi

cat <<'EOF'

Stopped and disabled all LLM services.
Kept on disk: model files, Docker volumes, API key, service configuration.
The generic llm-server.service alias remains, pointing at the last model service.
EOF
