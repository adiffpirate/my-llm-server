#!/usr/bin/env bash
# Shared helpers for the user-scoped, rootless LLM services.
# This file is sourced by up.sh, down.sh, and setup/*/*/run.sh.

set -Eeuo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
LLM_CONFIG="${LLM_CONFIG:-$CONFIG_HOME/llm-server}"
LLM_STATE="${LLM_STATE:-$STATE_HOME/llm-server}"
SERVICE_CONFIG="$LLM_CONFIG/services"
SERVICE_STATE="$LLM_STATE/services"
UNIT_DIR="$CONFIG_HOME/systemd/user"
API_KEY_FILE="$LLM_CONFIG/api-key"
WEBUI_SECRET_FILE="$LLM_CONFIG/webui-secret-key"
NETWORK_NAME="llm-net"
GENERIC_UNIT="llm-server.service"

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

if ((EUID == 0)); then
    die "Run this as your normal user, not as root; the services are user-scoped."
fi

setup_user_env() {
    local runtime="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    export XDG_RUNTIME_DIR="$runtime"
    export DOCKER_HOST="unix://$runtime/docker.sock"
    if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" && -S "$runtime/bus" ]]; then
        export DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime/bus"
    fi
}

select_index() {
    local title="$1" default="$2"
    shift 2
    local -a items=("$@")
    ((${#items[@]} > 0)) || die "internal error: empty menu"

    printf '\n%s\n' "$title" >&2
    local i
    for i in "${!items[@]}"; do
        printf '  %d) %s\n' "$((i + 1))" "${items[$i]}" >&2
    done

    if [[ ! -t 0 ]]; then
        printf '%s\n' "$((default - 1))"
        return
    fi

    local answer
    while true; do
        read -r -p "Selection [1-${#items[@]}] (default $default): " answer
        answer="${answer:-$default}"
        if [[ "$answer" =~ ^[0-9]+$ ]] && ((answer >= 1 && answer <= ${#items[@]})); then
            printf '%s\n' "$((answer - 1))"
            return
        fi
        printf 'Invalid selection.\n' >&2
    done
}

confirm() {
    local prompt="$1" default="${2:-yes}" reply hint
    if [[ "$default" == "yes" ]]; then hint="[Y/n]"; else hint="[y/N]"; fi
    if [[ ! -t 0 ]]; then
        [[ "$default" == "yes" ]]
        return
    fi
    read -r -p "$prompt $hint " reply
    reply="${reply:-$default}"
    [[ "$reply" =~ ^[Yy] ]]
}

ask() {
    local prompt="$1" default="${2:-}" reply
    if [[ ! -t 0 ]]; then
        printf '%s\n' "$default"
        return
    fi
    read -r -p "$prompt " reply
    printf '%s\n' "${reply:-$default}"
}

require_docker_cli() {
    have docker || die "Docker CLI not found. Install Docker first; this project does not install Docker itself."
    docker compose version >/dev/null 2>&1 || die "Docker Compose plugin not found."
}

docker_rootless_ready() {
    setup_user_env
    have docker || return 1
    docker info >/dev/null 2>&1
}

require_rootless_docker() {
    docker_rootless_ready || die "Rootless Docker is not available at $DOCKER_HOST. Run ./up.sh once to configure it."
}

wait_for_docker() {
    local timeout="${1:-60}"
    local deadline=$((SECONDS + timeout))
    while ((SECONDS < deadline)); do
        if docker info >/dev/null 2>&1; then return 0; fi
        sleep 1
    done
    return 1
}

ensure_user_systemd() {
    setup_user_env
    systemctl --user show-environment >/dev/null 2>&1 || \
        die "The systemd user manager is not available. Log in with a normal user session and retry."
}

ensure_linger() {
    local linger
    linger="$(loginctl show-user "$USER" -p Linger 2>/dev/null || true)"
    [[ "$linger" == *"yes" ]] && return 0
    log "Enabling user lingering so services survive logout/reboot."
    if ! loginctl enable-linger "$USER" 2>/dev/null; then
        sudo loginctl enable-linger "$USER"
    fi
}

apt_install() {
    local -a missing=()
    local pkg
    for pkg in "$@"; do
        if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
            missing+=("$pkg")
        fi
    done
    ((${#missing[@]} == 0)) && return 0
    log "Installing missing packages: ${missing[*]}"
    sudo apt-get update -qq
    sudo apt-get install -y --no-install-recommends "${missing[@]}"
}

ensure_core_packages() {
    apt_install curl ca-certificates openssl iproute2
}

verify_nvidia_gpu() {
    have nvidia-smi || die "NVIDIA driver not found (nvidia-smi is missing)."
    nvidia-smi -L 2>/dev/null | grep -q '^GPU ' || die "nvidia-smi cannot see an NVIDIA GPU."
}

gpu_smoke_test() {
    local image="$1" ids="${2:-all}"
    docker run --rm --runtime=nvidia \
        -e NVIDIA_VISIBLE_DEVICES="$ids" \
        -e NVIDIA_DRIVER_CAPABILITIES=compute,utility \
        --entrypoint nvidia-smi "$image" -L
}

ensure_nvidia_toolkit() {
    verify_nvidia_gpu
    if have nvidia-ctk && have nvidia-container-runtime && have nvidia-container-cli; then
        return 0
    fi

    log "Installing the NVIDIA Container Toolkit."
    ensure_core_packages
    apt_install gnupg
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
        sudo gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
    sudo apt-get update -qq
    sudo apt-get install -y --no-install-recommends nvidia-container-toolkit
}

ensure_nvidia_runtime() {
    ensure_nvidia_toolkit

    local daemon_json="$CONFIG_HOME/docker/daemon.json"
    mkdir -p "$(dirname "$daemon_json")"
    if ! grep -q '"nvidia"' "$daemon_json" 2>/dev/null; then
        log "Configuring the NVIDIA runtime for rootless Docker."
        nvidia-ctk runtime configure --runtime=docker --config="$daemon_json" >/dev/null
    fi

    local runtime_config=/etc/nvidia-container-runtime/config.toml
    if [[ -f "$runtime_config" ]] && \
       ! grep -Eq '^[[:space:]]*no-cgroups[[:space:]]*=[[:space:]]*true' "$runtime_config"; then
        log "Enabling no-cgroups mode for rootless GPU access."
        sudo nvidia-ctk config --set nvidia-container-cli.no-cgroups=true --in-place
    fi

    if docker_rootless_ready && \
       ! docker info --format '{{json .Runtimes}}' | grep -q '"nvidia"'; then
        log "Restarting rootless Docker to load the NVIDIA runtime."
        systemctl --user restart docker
        wait_for_docker 60 || die "Rootless Docker did not restart."
    fi
}

ensure_rootless_prereqs() {
    ensure_core_packages
    apt_install uidmap slirp4netns fuse-overlayfs dbus-user-session

    if ! awk -F: -v u="$USER" '$1 == u { found = 1 } END { exit !found }' /etc/subuid; then
        log "Adding subordinate UIDs for $USER."
        sudo usermod --add-subuids 100000-165535 "$USER"
    fi
    if ! awk -F: -v u="$USER" '$1 == u { found = 1 } END { exit !found }' /etc/subgid; then
        log "Adding subordinate GIDs for $USER."
        sudo usermod --add-subgids 100000-165535 "$USER"
    fi

    if [[ "$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0)" == "1" ]] && \
       [[ ! -e /etc/apparmor.d/rootlesskit ]]; then
        warn "AppArmor restricts unprivileged user namespaces and /etc/apparmor.d/rootlesskit is missing."
        warn "Install the rootless extras package that provides that profile before using GPU containers."
    fi
}

ensure_rootless_docker() {
    require_docker_cli
    setup_user_env
    ensure_user_systemd

    if docker_rootless_ready; then
        systemctl --user enable docker >/dev/null 2>&1 || true
        ensure_nvidia_runtime
        ensure_linger
        return 0
    fi

    ensure_rootless_prereqs
    have dockerd-rootless-setuptool.sh || \
        die "dockerd-rootless-setuptool.sh is missing. Install the Docker rootless extras package."

    if [[ ! -f "$UNIT_DIR/docker.service" ]]; then
        log "Creating the rootless Docker user service."
        dockerd-rootless-setuptool.sh -f install
    fi

    ensure_nvidia_runtime
    ensure_linger
    systemctl --user daemon-reload
    systemctl --user enable --now docker
    wait_for_docker 90 || die "Rootless Docker failed to start. Check: journalctl --user -u docker"
    log "Rootless Docker is ready at $DOCKER_HOST."
}

ensure_docker_network() {
    docker network inspect "$NETWORK_NAME" >/dev/null 2>&1 && return 0
    log "Creating Docker network $NETWORK_NAME."
    docker network create --label app=llm-server "$NETWORK_NAME" >/dev/null
}

ensure_secret_file() {
    local file="$1"
    mkdir -p "$LLM_CONFIG"
    chmod 700 "$LLM_CONFIG"
    if [[ ! -s "$file" ]]; then
        local old_umask
        old_umask="$(umask)"
        umask 077
        openssl rand -hex 32 > "$file"
        umask "$old_umask"
    fi
    chmod 600 "$file"
}

ensure_api_key() {
    ensure_secret_file "$API_KEY_FILE"
}

ensure_webui_secret() {
    ensure_secret_file "$WEBUI_SECRET_FILE"
}

port_available() {
    local port="$1" in_use
    have ss || { warn "ss not found; skipping port check for $port."; return 0; }
    in_use="$(ss -H -ltn 2>/dev/null | awk -v p=":$port" '$4 ~ p"$" { print; exit }')"
    [[ -z "$in_use" ]]
}

compose_cmd() {
    local dir="$1" project="$2"
    shift 2
    docker compose --project-name "$project" --env-file "$dir/.env" -f "$dir/compose.yml" "$@"
}

validate_compose() {
    local dir="$1" project="$2"
    compose_cmd "$dir" "$project" config -q
}

install_compose_unit() {
    local unit="$1" description="$2" dir="$3" project="$4"
    local start_timeout="${5:-1800}" stop_timeout="${6:-180}"
    local docker_bin unit_path
    docker_bin="$(command -v docker)"
    unit_path="$UNIT_DIR/$unit"

    mkdir -p "$UNIT_DIR"
    cat > "$unit_path" <<EOF
[Unit]
Description=$description
Wants=docker.service
After=docker.service
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=oneshot
RemainAfterExit=yes
Environment="DOCKER_HOST=$DOCKER_HOST" "HOME=$HOME" "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR"
WorkingDirectory=$dir
ExecStart="$docker_bin" compose --project-name "$project" --env-file "$dir/.env" -f "$dir/compose.yml" up -d --remove-orphans
ExecStop="$docker_bin" compose --project-name "$project" --env-file "$dir/.env" -f "$dir/compose.yml" down --remove-orphans
TimeoutStartSec=$start_timeout
TimeoutStopSec=$stop_timeout
TimeoutStartFailureMode=terminate
TimeoutStopFailureMode=kill
Restart=on-failure
RestartSec=5
SyslogIdentifier=$unit

[Install]
WantedBy=default.target
EOF
    chmod 644 "$unit_path"
    systemd-analyze --user verify "$unit_path" || die "Generated systemd unit failed verification: $unit_path"
}

start_unit() {
    systemctl --user daemon-reload
    systemctl --user start "$1"
}

enable_unit() {
    systemctl --user enable "$1"
}

activate_generic_unit() {
    ln -sfn "$1" "$UNIT_DIR/$GENERIC_UNIT"
    systemctl --user daemon-reload
}

write_service_state() {
    local unit="$1" kind="$2" dir="$3" project="$4" container="$5" port="$6"
    mkdir -p "$SERVICE_STATE"
    chmod 700 "$LLM_STATE" "$SERVICE_STATE"
    {
        printf 'UNIT=%q\n' "$unit"
        printf 'KIND=%q\n' "$kind"
        printf 'COMPOSE_DIR=%q\n' "$dir"
        printf 'PROJECT=%q\n' "$project"
        printf 'CONTAINER=%q\n' "$container"
        printf 'HOST_PORT=%q\n' "$port"
    } > "$SERVICE_STATE/$unit.env"
    chmod 600 "$SERVICE_STATE/$unit.env"
}

stop_service_from_state() {
    local file="$1"
    local UNIT="" KIND="" COMPOSE_DIR="" PROJECT="" CONTAINER="" HOST_PORT=""
    [[ -f "$file" ]] || return 0
    # shellcheck disable=SC1090
    source "$file"

    systemctl --user stop "$UNIT" 2>/dev/null || true
    systemctl --user disable "$UNIT" 2>/dev/null || true
    if docker_rootless_ready && [[ -n "$COMPOSE_DIR" && -f "$COMPOSE_DIR/compose.yml" ]]; then
        compose_cmd "$COMPOSE_DIR" "$PROJECT" down --remove-orphans >/dev/null 2>&1 || \
            warn "Could not remove containers for $UNIT."
    fi
}

stop_model_services_except() {
    local keep="$1" file
    local UNIT="" KIND="" COMPOSE_DIR="" PROJECT="" CONTAINER="" HOST_PORT=""
    shopt -s nullglob
    for file in "$SERVICE_STATE"/*.env; do
        UNIT="" KIND="" COMPOSE_DIR="" PROJECT="" CONTAINER="" HOST_PORT=""
        # shellcheck disable=SC1090
        source "$file"
        [[ "$KIND" == "model" && "$UNIT" != "$keep" ]] || continue
        log "Stopping previous model service: $UNIT"
        stop_service_from_state "$file"
    done
}

rollback_compose_service() {
    local unit="$1" dir="$2" project="$3" container="$4"
    warn "Rolling back $unit."
    if docker_rootless_ready && docker inspect "$container" >/dev/null 2>&1; then
        docker logs --tail 80 "$container" 2>&1 | sed 's/^/  /' || true
    fi
    systemctl --user stop "$unit" 2>/dev/null || true
    systemctl --user disable "$unit" 2>/dev/null || true
    if docker_rootless_ready && [[ -f "$dir/compose.yml" ]]; then
        compose_cmd "$dir" "$project" down --remove-orphans >/dev/null 2>&1 || true
    fi
}

# Wait for an HTTP endpoint, stopping early if the container exits (return 2).
wait_http_running() {
    local url="$1" timeout="$2" name="$3" label="${4:-service}"
    local deadline=$((SECONDS + timeout))
    log "Waiting for $label at $url (up to ${timeout}s)."
    while ((SECONDS < deadline)); do
        if ! container_running "$name"; then
            return 2
        fi
        if curl -fsS --max-time 3 "$url" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    return 1
}

container_running() {
    docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null | grep -qx 'true'
}

wait_container_running() {
    local name="$1"
    local timeout="$2"
    local deadline=$((SECONDS + timeout))
    while ((SECONDS < deadline)); do
        container_running "$name" && return 0
        sleep 1
    done
    return 1
}
