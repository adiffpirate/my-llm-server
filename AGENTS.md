# AGENTS.md

Bash-only service code that installs **user-scoped, rootless Docker** LLM services on NVIDIA hosts.
No application code, build system, CI, or test suite — the scripts are the product. `bench.py` is the one Python utility, for measurements only.

- `up.sh` / `down.sh` — the only top-level entrypoints.
- `lib/common.sh` — all shared helpers; sourced by every script.
- `setup/<hardware>/<engine>/run.sh` — per-hardware engine installers.
- `setup/common/openwebui/run.sh` — optional, separate OpenWebUI service.
- `bench.py` — PP/TG and CPU/GPU measurement client for the OpenAI-compatible server.
- `README.md` — user-facing docs; keep it truthful when changing behavior.

## Non-negotiables

- **Never run as root.** Sourcing `lib/common.sh` exits when `EUID==0`; everything is `systemctl --user` and rootless Docker.
- **Rootless Docker only:** `export DOCKER_HOST="unix://${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/docker.sock"`. The rootful `/var/run/docker.sock` is intentionally ignored. Call `setup_user_env` before any `docker` command.
- **Secrets are generated, never committed:** `~/.config/llm-server/{api-key,webui-secret-key}`. Compose files reference `${API_KEY}` from `.env`; never inline keys.
- **Keep containers hardened:** `cap_drop: ALL`, `no-new-privileges`, `read_only` with explicit writable volumes/tmpfs, `pids_limit`, private IPC, no Docker socket. If an app needs to write, add a volume instead of removing `read_only`.
- Do not resurrect the deleted legacy scripts (`install.sh`, `run-openwebui.sh`, `run-standard-nvidia-rtx-4050.sh`, `stop.sh`).

## Installer contract (`setup/*/*/run.sh`)

Every engine installer must keep this interface; `up.sh` depends on it.

- Flags: `--dry-run`, `--select-only`. Unknown flags `die`.
- `--select-only` prints **only** shell-quoted assignments to stdout (`LLM_MODEL=...`, plus `LLM_MODEL_PATH=...` for a custom GGUF). `up.sh` evals this to ask about OpenWebUI *after* model selection. Menus/prompts/logs must go to stderr. It runs before Docker/GPU setup, so it must not require either.
- The real install runs with `LLM_MODEL` exported; installers must honor it and skip the menu instead of asking twice.
- Install order: checks → stop previous model services → network → `docker pull` → GPU smoke test → write `.env` + `compose.yml` → `install_compose_unit` → start → wait health → `enable_unit` → `activate_generic_unit` → `write_service_state` → `print_summary`.
- Write `CONFIG_SIG=$(config_signature ...)` into `.env`. `up.sh` skips the install when the signature still matches and the unit is active. **Bump `TEMPLATE_VERSION` whenever the generated Compose file, unit, or health behavior changes**, otherwise changes silently don't apply.
- `wait_http_running` returns `0` ready, `1` timeout, `2` container exited, `3` restarted. Roll back on `2`/`3`; do not ignore them.

## up.sh / down.sh behavior

- `--list` and `--dry-run` still require the Docker CLI and `nvidia-smi` (checked before hardware matching).
- Hardware matching: `setup/<dir>/hardware.conf` is sourced and must define `HARDWARE_NAME`, `GPU_PATTERN` (ERE vs the `nvidia-smi` name), `MIN_VRAM_MB`. Engines are executable `run.sh` subdirectories.
- Unit names: `llm-server-<hardware>-<engine>.service`; WebUI: `llm-server-openwebui.service`; alias: `llm-server.service` → active model unit. Network `llm-net`; stable model hostname `llm-model:8080`.
- `down.sh` targets: `--model`, `--webui`, `--all`, or an interactive menu (default both without a TTY). `--delete-data` also removes the selected Docker data volumes; it asks first, `--yes` skips the question, and a non-TTY run without `--yes` refuses. The llama.cpp `models/` bind mount is never deleted.
- Interactive `up.sh` asks about OpenWebUI after model selection; default **no** (~1 GB RAM). Declining stops a running OpenWebUI before the model loads.

## Profile constraints

Per-hardware specifics live with the profile; do not assume one machine's numbers apply to another.

- `setup/rtx_5060_ti` targets a 16 GB RTX 5060 Ti and defaults to Strata `IQ3_S`, text only, **256K context**, `k8v4` KV, `LLM_RESIDENT_BUDGET_GIB=41`, `PARALLEL=1`. Measurements are in `setup/rtx_5060_ti/README.md`.
- The same Strata menu also offers DeepSeek-V4.1-Flash 1017 (IST-DAS 1.75/2.00/2.25 bpw). It downloads 239/257/274 GB, runs its own engine package, and sizes its own RAM cache; `LLM_RESIDENT_BUDGET_GIB` does not apply. `LLM_SPEED=auto|faster|full` selects the engine default, 5, or 6 experts per word.
- **Do not remove the resident budget from that profile.** Without it Strata page-locks all experts every start: many minutes on memory-tight hosts, sometimes exceeding Strata's computed load timeout.
- Use `LLM_CONTEXT=128k LLM_KV=int8` for more headroom. Avoid `--mlock`/unlimited memlock: the locked-memory limit on the reference host is only 8 MB.
- `LLM_POOL_WORKERS=N` caps the Qwen CPU expert pool (engine default: every logical CPU, 15 workers here). Measure with `bench.py`; fewer workers trade PP/TG for CPU power. It does not apply to DeepSeek.
- First Strata install needs ~140 GB free. Reinstalls skip that check when a GGUF already exists in the volume.
- Pinned images (change deliberately, verify the tag exists): `ghcr.io/niko1221/strata:0.2.9-cuda13`, `ghcr.io/ggml-org/llama.cpp:server-cuda-b5343`, `ghcr.io/open-webui/open-webui:v0.13.0`.

## Verifying changes

No automated tests. Use these gates, in order:

```bash
bash -n up.sh down.sh lib/common.sh setup/*/*/run.sh setup/common/openwebui/run.sh
python3 -m py_compile bench.py
./up.sh --list
./up.sh --dry-run
# generated files, after a real/partial install:
docker compose --project-name <project> --env-file <dir>/.env -f <dir>/compose.yml config -q
systemd-analyze --user verify ~/.config/systemd/user/llm-server-*.service
```

- Real installs mutate the host, take over the GPU, and can take minutes to load a model: use them only when asked. `./up.sh --no-webui` then `./down.sh --all` exercises install and teardown.
- Shell gotcha: `if ! cmd; then rc=$?` always yields `0`. The scripts use `if cmd; then :; else rc=$?`. Keep that pattern.
- After changing a Compose template, force a reinstall (`LLM_FORCE_REINSTALL=1 ./up.sh`) or bump `TEMPLATE_VERSION`.

## State: edit generators, not generated copies

Runtime files are written from the scripts and overwritten on each install:

```text
~/.config/llm-server/api-key, webui-secret-key
~/.config/llm-server/services/<unit>/{compose.yml,.env}
~/.local/state/llm-server/services/<unit>.env
~/.config/systemd/user/<unit>
```

Rootless Docker data lives under `~/.local/share/docker` (Strata volume is ~140 GB).

## OpenWebUI gotchas

- v0.13.0 serves `/health`, mounts the OpenAI router at `/openai` (v0.1.x used `/openai/api`), and writes branding assets to `/app/backend/open_webui/static` — that path needs the writable static volume under `read_only`.
- Sign-up/admin settings are persisted in the data volume and override env vars; a 403 on signup usually means an admin disabled it. Never reset or delete the user's account/volume while testing.
