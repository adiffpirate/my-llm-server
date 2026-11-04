# AGENTS.md

Bash-only repo that installs **user-scoped, rootless Docker** LLM services on NVIDIA hosts.
No application code, build system, CI, or test suite — the scripts are the product.

- `up.sh` / `down.sh` — the only top-level entrypoints.
- `lib/common.sh` — all shared helpers; sourced by every script.
- `setup/<hardware>/<engine>/run.sh` — per-hardware engine installers.
- `setup/common/openwebui/run.sh` — optional, separate OpenWebUI service.
- `README.md` — user-facing docs; keep it truthful when changing behavior.

## Non-negotiables

- **Never run as root.** Sourcing `lib/common.sh` exits when `EUID==0`; everything is `systemctl --user` and rootless Docker.
- **Rootless Docker only:** `export DOCKER_HOST="unix://${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/docker.sock"`. The rootful `/var/run/docker.sock` is intentionally ignored. Call `setup_user_env` before any `docker` command.
- **Never delete persistent data:** `llm-server-*-strata-data` (~140 GB), `llm-server-openwebui-data` (accounts/chats), `models/`. No `docker volume rm/prune`, no `docker compose down -v`, no `git clean -xfd`. `down.sh` only stops/disables units and removes containers.
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
- `down.sh` targets: `--model`, `--webui`, `--all`, or an interactive menu (default both without a TTY).
- Interactive `up.sh` asks about OpenWebUI after model selection; default **no** (~1 GB RAM). Declining stops a running OpenWebUI before the model loads.

## Host and model constraints

- This host: RTX 5060 Ti 16 GB, driver 595, 52 GB RAM, 200 GB disk (~42 GB free with the model installed). Strata `IQ3_S`, text only, **256K context**, `k8v4` KV, **`LLM_RESIDENT_BUDGET_GIB=41`**, `PARALLEL=1`.
- **Do not remove the resident budget.** Without it Strata page-locks ~43 GiB every start: 10–15 minutes, sometimes exceeding its ~945 s load timeout. With the cap, startup is ~1 minute and long-context throughput stays ~41 tok/s.
- Use `LLM_CONTEXT=128k LLM_KV=int8` for more headroom. Avoid `--mlock`/unlimited memlock: the host locked-memory limit is 8 MB.
- First Strata install needs ~140 GB free. Reinstalls skip that check when a GGUF already exists in the volume.
- Pinned images (change deliberately, verify the tag exists): `ghcr.io/niko1221/strata:0.2.9-cuda13`, `ghcr.io/ggml-org/llama.cpp:server-cuda-b5343`, `ghcr.io/open-webui/open-webui:v0.13.0`.

## Verifying changes

No automated tests. Use these gates, in order:

```bash
bash -n up.sh down.sh lib/common.sh setup/*/*/run.sh setup/common/openwebui/run.sh
./up.sh --list
./up.sh --dry-run
# generated files, after a real/partial install:
docker compose --project-name <project> --env-file <dir>/.env -f <dir>/compose.yml config -q
systemd-analyze --user verify ~/.config/systemd/user/llm-server-*.service
```

- Real installs mutate the host and take over the GPU: use them only when asked. `./up.sh --no-webui` (~90 s) then `./down.sh --all` exercises install and teardown.
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
