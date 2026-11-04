# my-llm-server

User-scoped, rootless, hardened LLM services selected by GPU.

## Layout

```text
up.sh                         detect GPU, select hardware/engine, install
down.sh                       stop and disable all LLM services
lib/common.sh                 shared rootless/systemd/Compose helpers
setup/
  rtx_5060_ti/
    README.md                 profile defaults and reference measurements
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
- Disk space for the selected model. The installer checks it before downloading.

Hardware support lives in `setup/<hardware>/hardware.conf`. Run `./up.sh --list` to see which setups match the GPUs in the current machine.

The first `up.sh` run installs rootless prerequisites (`uidmap`, `slirp4netns`, `fuse-overlayfs`), creates the rootless Docker user service, configures the NVIDIA runtime for rootless mode, and enables user lingering. These steps may prompt for `sudo`.

## Usage

```bash
./up.sh --list         # show detected GPUs and matching hardware
./up.sh --dry-run      # show the selected model/service without installing
./up.sh                # interactive install
./down.sh              # interactive: model only, OpenWebUI only, or both
./down.sh --model      # stop only the model service
./down.sh --webui      # stop only OpenWebUI
./down.sh --all        # stop both (default without a terminal)
```

Interactive `up.sh` asks about OpenWebUI right after the model selection. The answer defaults to **no**, because OpenWebUI uses about 1 GB of RAM, which matters on memory-tight profiles. If it is already running and you answer no, it is stopped before the model loads.

Useful options and overrides:

```bash
./up.sh --with-webui
./up.sh --no-webui
LLM_HARDWARE=rtx_5060_ti LLM_ENGINE=strata LLM_MODEL=IQ3_S ./up.sh
LLM_PORT=9090 ./up.sh
LLM_CONTEXT=128k LLM_KV=int8 ./up.sh    # more RAM headroom, better KV quality
LLM_CONTEXT=256k LLM_KV=k8v4 ./up.sh    # larger context, smaller KV
```

Defaults such as model, context, KV mode and resident budget are set per engine in `setup/<hardware>/<engine>/run.sh`; the environment variables above override them.

If more than one GPU/hardware combination matches, `up.sh` asks which one to use. Each engine's `run.sh` then asks for the model unless `LLM_MODEL` is set.

`up.sh` is safe to rerun. Each service stores a configuration signature; when the selected model, context, KV mode, ports, GPU and secrets are unchanged and the unit is already active, `up.sh` returns in seconds without touching the running service. Anything that differs triggers a reinstall. Use `LLM_FORCE_REINSTALL=1 ./up.sh` to force one.

### Startup time

The download is not the slow part. Strata page-locks the experts it keeps in RAM on every start. On a host where that leaves little free memory, the kernel reclaims continuously during startup: it can take many minutes and hit Strata's own load timeout.

The Strata profile caps the resident experts with `LLM_RESIDENT_BUDGET_GIB` and reads the coldest ones from the SSD on demand. Answers are unchanged; only those reads are slower. The trade-off is per profile — see `setup/rtx_5060_ti/README.md` for the measured values on the reference hardware.

Consequences:

- Re-running `up.sh` with no changes returns in under a second (configuration signature match).
- `systemctl --user restart llm-server` reloads the model.
- `down.sh --webui` stops only OpenWebUI and leaves the loaded model alone.
- Switching context, KV mode, budget, or model forces a reload.

## Services

Each hardware/engine gets a specific unit, plus one stable alias:

```text
llm-server-<hardware>-<engine>.service
llm-server.service -> llm-server-<hardware>-<engine>.service
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

Pinned images:

```text
ghcr.io/niko1221/strata:0.2.9-cuda13          Strata (CUDA 13, driver 580+)
ghcr.io/ggml-org/llama.cpp:server-cuda-b5343   llama.cpp
ghcr.io/open-webui/open-webui:v0.13.0         OpenWebUI
```

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

The Strata profile defaults to `qwen / IQ3_S`, text only, with a 256K context, `k8v4` KV cache, and a capped resident expert cache. Those defaults suit the hardware profile they ship with; other machines can override them:

```bash
LLM_CONTEXT=128k LLM_KV=int8 ./up.sh --with-webui   # more RAM headroom
LLM_RESIDENT_BUDGET_GIB=38 ./up.sh                  # fewer experts in RAM
```

`k8v4` keeps keys at 8 bits and values at 4 bits: 23% less KV memory than int8, prompts 2–5% slower, and more accurate than `q4_0` on long documents.

The resident budget (`LLM_RESIDENT_BUDGET_GIB`) trades RAM headroom against SSD reads. Removing it makes Strata page-lock all experts on every start, which is much slower on memory-tight hosts and can hit Strata's load timeout. Answers are the same either way.

The first Strata install needs about 140 GB free: the download, the prepared pack, and the draft layer. Afterwards the prepared model occupies about 140 GB, and reinstalling does not need that space again. The installer checks for an existing model in the volume before enforcing the disk requirement.

Strata's documentation estimates about 54.8 GB of model memory plus about 10 GB for the system. If the host has less, Strata uses its low-RAM mode and reads some experts from the SSD. The first start downloads/prepares tens of GB and can take an hour or more. Watch it with:

```bash
docker logs -f <container>
```

See `setup/rtx_5060_ti/README.md` for measured throughput and startup times on the reference hardware.

## Troubleshooting

- Service does not start: `systemctl --user status llm-server`, `journalctl --user -u llm-server -n 100`, then `docker logs --tail 100 <container>`.
- Docker commands report "permission denied" or the rootful daemon: export the rootless socket first (`export DOCKER_HOST="unix://${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/docker.sock"`).
- First start stops with a disk error: free space or pick a smaller model (`LLM_MODEL=IQ2_XS ./up.sh`).
- OpenWebUI is up but lists no model: the model service must be healthy first; check `curl -H "Authorization: Bearer $(cat ~/.config/llm-server/api-key)" http://127.0.0.1:8080/v1/models`.

The llama.cpp profile targets an RTX 4050 with CPU-MoE offload. It uses pinned image `ghcr.io/ggml-org/llama.cpp:server-cuda-b5343` and the Gemma/Qwen GGUF choices in its menu. For a custom file, set `LLM_MODEL=custom LLM_MODEL_PATH=/path/model.gguf` or enter the path interactively.
