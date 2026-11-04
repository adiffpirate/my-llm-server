# rtx_5060_ti profile

Setup for a 16 GB RTX 5060 Ti. `hardware.conf` matches GPUs named `RTX 5060 Ti` with at least 15000 MiB of VRAM.

## Defaults

- Strata `qwen / IQ3_S`, text only (vision off)
- 256K context (`LLM_CONTEXT=256k`)
- `k8v4` KV cache, single parallel slot
- `LLM_RESIDENT_BUDGET_GIB=41`

These are the settings the installer uses; override them with the `LLM_*` environment variables.

## Reference measurements

Measured on a test host with an RTX 5060 Ti 16 GB, driver 595, 52 GB RAM and 200 GB disk, with the model loaded and OpenWebUI running. Prompt processing and generation use 256 generated tokens for the long-context rows.

| Prompt | Prompt processing | Generation |
| ---: | ---: | ---: |
| ~1K tokens | 275–375 tok/s | 30–60 tok/s |
| ~8K tokens | 1230 tok/s | 53 tok/s |
| ~28K tokens | 1220 tok/s | 41 tok/s |
| ~212K tokens | 1231 tok/s | 41.5 tok/s |

The server reports `max_context: 262144` with these defaults. The first request after a start can sit near the low end while the coldest experts are read from the SSD; later requests warm up to the higher figure.

Startup on the reference host:

- Model start at 256K: **58 seconds**
- Full `./up.sh --with-webui` from stopped: **86 seconds**
- `./up.sh` with no changes: **under a second** (configuration signature match)

## Memory and disk

- About **4 GB** of RAM remains available at 256K with OpenWebUI running; avoid other large programs on a 52 GB host.
- For more headroom use `LLM_CONTEXT=128k LLM_KV=int8`.
- The prepared Strata model occupies about **140 GB**. The first install needs roughly that much free space; reinstalls detect the existing model and skip the check.
- Without the 41 GiB resident cap, Strata page-locks all experts on every start, which took 10–15 minutes here and could exceed its load timeout.
