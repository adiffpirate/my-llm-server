# my-llm-server

User-scoped, rootless, hardened LLM services selected by GPU.

## Layout

```text
up.sh                         detect GPU, select hardware/engine, install
down.sh                       stop and disable all LLM services
lib/common.sh                 shared rootless/systemd/Compose helpers
setup/
  rtx_5060_ti/
    hardware.conf             GPU match rule
    strata/run.sh             Strata + Qwen3.8-Flash-Next
  rtx_4050/
    hardware.conf
    llama_cpp/run.sh          llama.cpp GGUF models
  common/
    openwebui/run.sh          optional, separate OpenWebUI service
models/                       llama.cpp GGUF files (gitignored)
```

## Requirements

- Linux with systemd, a normal (non-root) login session, and `sudo`.
- Docker Engine, the Docker Compose plugin, and the Docker rootless extras (`dockerd-rootless-setuptool.sh`). `up.sh` verifies them; it does not install Docker itself.
- An NVIDIA GPU and driver. The scripts install the NVIDIA Container Toolkit if it is missing, but never the GPU driver.
- For this machine: RTX 5060 Ti 16 GB, driver 595, 200 GB disk (about 187 GB free).

The first `up.sh` run installs rootless prerequisites (`uidmap`, `slirp4netns`, `fuse-overlayfs`), creates the rootless Docker user service, configures the NVIDIA runtime for rootless mode, and enables user lingering. These steps may prompt for `sudo`.

## Usage

```bash
./up.sh --list       # show detected GPUs and matching hardware
./up.sh --dry-run    # show the selected model/service without installing
./up.sh              # interactive install
./down.sh            # stop/disable everything, keep models and data
```

Useful options and overrides:

```bash
./up.sh --with-webui
./up.sh --no-webui
LLM_HARDWARE=rtx_5060_ti LLM_ENGINE=strata LLM_MODEL=IQ3_S ./up.sh
LLM_PORT=9090 ./up.sh
```

If more than one GPU/hardware combination matches, `up.sh` asks which one to use. Each engine's `run.sh` then asks for the model unless `LLM_MODEL` is set.

## Services

Each hardware/engine gets a specific unit, plus one stable alias:

```text
llm-server-rtx_5060_ti-strata.service
llm-server.service -> llm-server-rtx_5060_ti-strata.service
llm-server-openwebui.service          (optional, separate)
```

Manage them as the current user:

```bash
systemctl --user status llm-server
systemctl --user restart llm-server
journalctl --user -u llm-server -f
systemctl --user status llm-server-openwebui
```

Because lingering is enabled, the services start at boot without a login session. `down.sh` stops/disables the units and removes containers, but never removes model files or Docker volumes.

## Endpoints

- API: `http://<host>:8080/v1` (OpenAI-compatible)
- OpenWebUI: `http://<host>:3000` (when installed)
- API key: `~/.config/llm-server/api-key`
- Backend alias used by OpenWebUI: `http://llm-model:8080/v1`

Both listeners bind to `0.0.0.0` by default. To restrict the API to localhost:

```bash
LLM_BIND_ADDR=127.0.0.1 ./up.sh
```

The model API requires the generated key. OpenWebUI is LAN-wide; create its admin account immediately, and do not expose it directly to the internet without TLS and a reverse proxy.

## Storage and configuration

```text
~/.config/llm-server/api-key
~/.config/llm-server/webui-secret-key
~/.config/llm-server/services/<unit>/{compose.yml,.env}
~/.local/state/llm-server/services/<unit>.env
~/.config/systemd/user/<unit>
~/.config/docker/daemon.json                 rootless Docker + NVIDIA runtime
```

Model data:

- Strata: Docker volume `llm-server-<hardware>-<engine>-strata-data`
- llama.cpp: `<repo>/models`
- OpenWebUI: Docker volumes `llm-server-openwebui-data` and `llm-server-openwebui-static`

## Security model

- Both the Docker daemon and the containers run rootless under the current user.
- Containers have `cap_drop: ALL`, `no-new-privileges`, a read-only root filesystem, sized tmpfs mounts, a PID limit, private IPC, and no Docker socket.
- The model container gets only its data/model volume and the GPU device access injected by the NVIDIA runtime. Strata writes to its named volume; llama.cpp mounts `<repo>/models` read-only. OpenWebUI writes to its own named volume. No container can write to the repository or the host home directory.
- The service units are user units, not system/root units. Model files are mounted read-only.
- Containers have outbound internet access, as required for model downloads and OpenWebUI features.
- Rootless mode limits the blast radius of a container escape: container root maps to the unprivileged host user.

Docker manual commands need the rootless endpoint:

```bash
export DOCKER_HOST="unix://${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/docker.sock"
docker ps
```

## Model notes

Strata defaults to `qwen / IQ3_S` as requested. The installer needs about 140 GB free for `IQ3_S`: the ~89 GB download, the prepared pack, and the draft layer. Strata's documentation estimates about 54.8 GB of model memory plus about 10 GB for the system; this host has 52 GB RAM, so Strata may fall back to its low-RAM/SSD mode, which is much slower. The first start downloads/prepares tens of GB and can take a long time. Watch it with:

```bash
docker logs -f llm-server-rtx-5060-ti-strata-model
```

The llama.cpp profile targets an RTX 4050 with CPU-MoE offload. It uses pinned image `ghcr.io/ggml-org/llama.cpp:server-cuda-b5343` and the Gemma/Qwen GGUF choices in its menu. For a custom file, set `LLM_MODEL=custom LLM_MODEL_PATH=/path/model.gguf` or enter the path interactively.
